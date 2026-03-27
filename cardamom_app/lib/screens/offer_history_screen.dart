import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../widgets/grade_grouped_dropdown.dart';
import 'offer_price_screen.dart';

class OfferHistoryScreen extends StatefulWidget {
  final List<String> clients;
  final List<String> grades;

  const OfferHistoryScreen({
    super.key,
    required this.clients,
    required this.grades,
  });

  @override
  State<OfferHistoryScreen> createState() => _OfferHistoryScreenState();
}

class _OfferHistoryScreenState extends State<OfferHistoryScreen> {
  final ApiService _apiService = ApiService();

  // Analytics
  Map<String, dynamic> _analytics = {};
  bool _analyticsLoading = true;

  // Offers
  List<dynamic> _offers = [];
  bool _offersLoading = true;

  // Filters
  String? _filterClient;
  String? _filterGrade;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  final TextEditingController _clientFilterController = TextEditingController();

  // Delete & role
  String _userRole = 'user';
  bool get _isAdmin => _userRole == 'superadmin' || _userRole == 'admin' || _userRole == 'ops';
  bool _isSelectMode = false;
  final Set<String> _selectedOfferIds = {};

  @override
  void initState() {
    super.initState();
    _loadRole();
    _loadData();
  }

  Future<void> _loadRole() async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('userRole') ?? 'user';
    if (mounted) setState(() => _userRole = role);
  }

  @override
  void dispose() {
    _clientFilterController.dispose();
    super.dispose();
  }

  Future<void> _deleteOffer(String offerId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Offer'),
        content: const Text('Are you sure you want to delete this offer?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _apiService.deleteOffer(offerId);
      setState(() => _offers.removeWhere((o) => o['id'] == offerId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Offer deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _bulkDeleteOffers() async {
    if (_selectedOfferIds.isEmpty) return;
    final count = _selectedOfferIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Selected Offers'),
        content: Text('Are you sure you want to delete $count offer${count > 1 ? 's' : ''}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _apiService.bulkDeleteOffers(_selectedOfferIds.toList());
      setState(() {
        _offers.removeWhere((o) => _selectedOfferIds.contains(o['id']));
        _selectedOfferIds.clear();
        _isSelectMode = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$count offer${count > 1 ? 's' : ''} deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk delete failed: $e')));
      }
    }
  }

  Future<void> _loadData() async {
    await Future.wait([
      _loadAnalytics(),
      _loadOffers(),
    ]);
  }

  Future<void> _loadAnalytics() async {
    setState(() => _analyticsLoading = true);
    try {
      final response = await _apiService.getOfferAnalytics(
        dateFrom: _dateFrom?.toIso8601String(),
        dateTo: _dateTo?.toIso8601String(),
      );
      if (response.data['success'] == true) {
        setState(() {
          _analytics = Map<String, dynamic>.from(response.data['analytics'] ?? {});
          _analyticsLoading = false;
        });
      } else {
        setState(() => _analyticsLoading = false);
      }
    } catch (e) {
      debugPrint('Error loading analytics: $e');
      setState(() => _analyticsLoading = false);
    }
  }

  Future<void> _loadOffers() async {
    setState(() => _offersLoading = true);
    try {
      final response = await _apiService.getOfferHistory(
        client: _filterClient,
        grade: _filterGrade,
        dateFrom: _dateFrom?.toIso8601String(),
        dateTo: _dateTo?.toIso8601String(),
        limit: 50,
      );
      setState(() {
        _offers = response.data is List ? response.data : [];
        // Sort by date: latest first
        _offers.sort((a, b) {
          final dateA = _parseOfferDate(a['date']?.toString() ?? '');
          final dateB = _parseOfferDate(b['date']?.toString() ?? '');
          return dateB.compareTo(dateA);
        });
        _offersLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading offers: $e');
      setState(() => _offersLoading = false);
    }
  }

  DateTime _parseOfferDate(String dateStr) {
    try {
      final parts = dateStr.split('/');
      if (parts.length == 3) {
        final day = int.parse(parts[0]);
        final month = int.parse(parts[1]);
        var year = int.parse(parts[2]);
        if (year < 100) year += 2000;
        return DateTime(year, month, day);
      }
    } catch (_) {}
    return DateTime(2000);
  }

  void _applyFilters() {
    _loadOffers();
    _loadAnalytics();
  }

  void _clearFilters() {
    setState(() {
      _filterClient = null;
      _filterGrade = null;
      _dateFrom = null;
      _dateTo = null;
      _clientFilterController.clear();
    });
    _applyFilters();
  }

  bool get _hasActiveFilters =>
      _filterClient != null || _filterGrade != null || _dateFrom != null || _dateTo != null;

  Future<void> _pickDate(bool isFrom) async {
    final initial = isFrom ? (_dateFrom ?? DateTime.now()) : (_dateTo ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _dateFrom = picked;
        } else {
          _dateTo = picked;
        }
      });
      _applyFilters();
    }
  }

  /// Share offer as image to WhatsApp / other apps
  Future<void> _shareOffer(dynamic offer) async {
    final client = offer['client']?.toString() ?? '';
    final date = offer['date']?.toString() ?? '';
    final billing = offer['billingFrom']?.toString() ?? 'SYGT';
    final mode = offer['mode']?.toString() ?? 'india';
    final currency = offer['currency']?.toString() ?? 'INR';
    final items = (offer['items'] as List<dynamic>?) ?? [];
    final isWorldwide = mode == 'worldwide';
    final paymentTerm = offer['paymentTerm']?.toString() ?? 'FOB';
    final companyName = billing.toUpperCase() == 'ESPL'
        ? 'Emperor Spices Pvt Ltd'
        : 'Sri Yogaganapathi Traders';
    final logoAsset = billing.toUpperCase() == 'ESPL' ? 'assets/emperor_logo.jpg' : 'assets/yoga_logo.png';

    // Build the offer card widget for image capture
    final cardWidget = Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 400,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFF8FAFC), Color(0xFFF0FDF4)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: const Border(
              left: BorderSide(color: Color(0xFF2D6A4F), width: 5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF2D6A4F), Color(0xFF059669)],
                  ),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Small Green Cardamom Offer',
                        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                      ),
                    ),
                    if (isWorldwide) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          paymentTerm,
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(logoAsset, width: 44, height: 44, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            companyName,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Icon(Icons.person, color: Color(0xFF64748B), size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            client,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.calendar_today, color: Color(0xFF64748B), size: 16),
                            const SizedBox(width: 4),
                            Text(date, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF64748B))),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ...items.map((item) {
                      final grade = item['grade']?.toString() ?? '';
                      final price = item['price']?.toString() ?? '';
                      final qty = item['qty']?.toString() ?? '';
                      final hasQty = qty.isNotEmpty && qty != '0';
                      final qtyText = hasQty ? ' — $qty kgs' : '';
                      String priceText;
                      if (isWorldwide) {
                        priceText = '\$$price';
                      } else {
                        final priceNum = double.tryParse(price);
                        final base = priceNum != null && priceNum > 0 ? (priceNum / 1.05) : null;
                        final baseStr = base != null
                            ? (base == base.roundToDouble() ? base.round().toString() : base.toStringAsFixed(2))
                            : price;
                        priceText = '₹$baseStr plus GST';
                      }
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: const Border(left: BorderSide(color: Color(0xFF22C55E), width: 3)),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                '$grade$qtyText — $priceText',
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF334155)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: const Color(0xFF22C55E), borderRadius: BorderRadius.circular(8)),
                              child: Text(billing, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Render offscreen and capture as image
    final overlayState = Overlay.of(context);
    final captureKey = GlobalKey();
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: -1000,
        top: -1000,
        child: RepaintBoundary(key: captureKey, child: cardWidget),
      ),
    );

    overlayState.insert(overlayEntry);
    await Future.delayed(const Duration(milliseconds: 300));

    final RenderRepaintBoundary boundary =
        captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final Uint8List pngBytes = byteData!.buffer.asUint8List();
    overlayEntry.remove();

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/offer_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(pngBytes);

    if (!mounted) return;

    final box = context.findRenderObject() as RenderBox?;
    final shareOrigin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 100, 100);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'image/png')],
      sharePositionOrigin: shareOrigin,
    );
  }

  /// Convert offer to a new order — navigates to NewOrderScreen with prefill data
  void _convertToOrder(dynamic offer) {
    final client = offer['client']?.toString() ?? '';
    final billing = offer['billingFrom']?.toString() ?? 'SYGT';
    final items = (offer['items'] as List<dynamic>?) ?? [];

    // Map offer items to new order suborder format
    // _addSuborder expects numeric kgs/price for comparisons, not strings
    final orderItems = items.map((item) {
      final qty = num.tryParse(item['qty']?.toString() ?? '') ?? 0;
      final price = num.tryParse(item['price']?.toString() ?? '') ?? 0;
      return {
        'grade': item['grade']?.toString() ?? '',
        'kgs': qty,
        'price': price,
        'bagbox': 'Bag',
        'brand': '',
        'notes': '',
      };
    }).toList();

    Navigator.pushNamed(
      context,
      '/new_order',
      arguments: {
        'client': client,
        'billingFrom': billing,
        'items': orderItems,
      },
    );
  }

  /// Push offer data back to OfferPriceScreen for re-editing
  void _reuseOffer(dynamic offer) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => OfferPriceScreen(
          prefillData: Map<String, dynamic>.from(offer),
        ),
      ),
    );
  }

  /// Show expanded detail popup for an offer card
  void _showOfferDetail(dynamic offer) {
    final client = offer['client']?.toString() ?? 'Unknown';
    final date = offer['date']?.toString() ?? '';
    final billing = offer['billingFrom']?.toString() ?? 'SYGT';
    final mode = offer['mode']?.toString() ?? 'india';
    final currency = offer['currency']?.toString() ?? 'INR';
    final paymentTerm = offer['paymentTerm']?.toString();
    final items = (offer['items'] as List<dynamic>?) ?? [];
    final isWorldwide = mode == 'worldwide';
    final currencySymbol = currency == 'USD' ? '\$' : '₹';

    bool showIncludingGst = false;

    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [Color(0xFF2D6A4F), Color(0xFF059669)]),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(client,
                                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text(date,
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(billing,
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                      if (isWorldwide && paymentTerm != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(paymentTerm,
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx),
                        child: const Icon(Icons.close, color: Colors.white, size: 22),
                      ),
                    ],
                  ),
                ),
                // GST toggle (only for India mode)
                if (!isWorldwide)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setDialogState(() => showIncludingGst = false),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: !showIncludingGst ? Colors.white : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: !showIncludingGst
                                      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 4)]
                                      : null,
                                ),
                                child: Text(
                                  'Excl. GST',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: !showIncludingGst ? FontWeight.w700 : FontWeight.w500,
                                    color: !showIncludingGst ? const Color(0xFF2D6A4F) : const Color(0xFF94A3B8),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setDialogState(() => showIncludingGst = true),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: showIncludingGst ? Colors.white : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: showIncludingGst
                                      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 4)]
                                      : null,
                                ),
                                child: Text(
                                  'Incl. GST',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: showIncludingGst ? FontWeight.w700 : FontWeight.w500,
                                    color: showIncludingGst ? const Color(0xFF2D6A4F) : const Color(0xFF94A3B8),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Items
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: items.map((item) {
                        final grade = item['grade']?.toString() ?? '';
                        final price = item['price']?.toString() ?? '';
                        final qty = item['qty']?.toString() ?? '';
                        final hasQty = qty.isNotEmpty && qty != '0';

                        String priceDisplay;
                        if (isWorldwide) {
                          priceDisplay = '$currencySymbol$price';
                        } else {
                          final priceNum = double.tryParse(price);
                          if (showIncludingGst) {
                            // Show including GST — the stored price IS the inclusive price
                            final inclStr = priceNum != null
                                ? (priceNum == priceNum.roundToDouble() ? priceNum.round().toString() : priceNum.toStringAsFixed(2))
                                : price;
                            priceDisplay = '₹$inclStr';
                          } else {
                            // Show excluding GST (base price + GST label)
                            final base = priceNum != null && priceNum > 0 ? (priceNum / 1.05) : null;
                            final baseStr = base != null
                                ? (base == base.roundToDouble() ? base.round().toString() : base.toStringAsFixed(2))
                                : price;
                            priceDisplay = '₹$baseStr + GST';
                          }
                        }

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                            border: const Border(left: BorderSide(color: Color(0xFF22C55E), width: 3)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(grade,
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
                              ),
                              if (hasQty)
                                Text('${qty}kg  ',
                                    style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500)),
                              Text(priceDisplay,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF2D6A4F))),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                // Action buttons
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _shareOffer(offer);
                          },
                          icon: const Icon(Icons.share, size: 16),
                          label: const Text('Share', style: TextStyle(fontWeight: FontWeight.w600)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF25D366),
                            side: const BorderSide(color: Color(0xFF25D366)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _reuseOffer(offer);
                          },
                          icon: const Icon(Icons.edit_note, size: 18),
                          label: const Text('Re-edit', style: TextStyle(fontWeight: FontWeight.w600)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF3B82F6),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Convert to Order button
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _convertToOrder(offer);
                      },
                      icon: const Icon(Icons.shopping_cart_checkout, size: 18),
                      label: const Text('Convert to Order', style: TextStyle(fontWeight: FontWeight.w700)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: _isSelectMode
            ? Text('${_selectedOfferIds.length} selected', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))
            : const Text('Offer History', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: _isSelectMode ? const Color(0xFFFEF2F2) : Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: _isSelectMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() { _isSelectMode = false; _selectedOfferIds.clear(); }),
              )
            : null,
        actions: [
          if (_isSelectMode && _selectedOfferIds.isNotEmpty)
            IconButton(
              onPressed: _bulkDeleteOffers,
              icon: const Icon(Icons.delete, color: Color(0xFFEF4444)),
              tooltip: 'Delete selected',
            ),
          if (!_isSelectMode) ...[
            if (_isAdmin)
              IconButton(
                onPressed: () => setState(() => _isSelectMode = true),
                icon: const Icon(Icons.checklist, size: 22),
                color: const Color(0xFF64748B),
                tooltip: 'Select to delete',
              ),
            if (_hasActiveFilters)
              TextButton.icon(
                onPressed: _clearFilters,
                icon: const Icon(Icons.clear_all, size: 18),
                label: const Text('Clear'),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFFEF4444)),
              ),
            IconButton(
              onPressed: _applyFilters,
              icon: const Icon(Icons.refresh, size: 22),
              color: const Color(0xFF64748B),
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(isMobile ? 12 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Analytics cards
              _buildAnalyticsSection(isMobile),
              const SizedBox(height: 16),

              // Filters
              _buildFiltersSection(isMobile),
              const SizedBox(height: 16),

              // Offers list
              _buildOffersList(isMobile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAnalyticsSection(bool isMobile) {
    if (_analyticsLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final totalOffers = _analytics['totalOffers'] ?? 0;
    final uniqueClients = _analytics['uniqueClients'] ?? 0;
    final mostOfferedGrade = _analytics['mostOfferedGrade'] ?? '-';
    final mostOfferedCount = _analytics['mostOfferedGradeCount'] ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 10),
          child: Text('📊 Analytics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
        ),
        GridView.count(
          crossAxisCount: isMobile ? 2 : 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: isMobile ? 1.6 : 2.0,
          children: [
            _buildStatCard('Total Offers', '$totalOffers', Icons.description_outlined, const Color(0xFF3B82F6)),
            _buildStatCard('Clients', '$uniqueClients', Icons.people_outline, const Color(0xFF8B5CF6)),
            _buildStatCard('Top Grade', '$mostOfferedGrade', Icons.star_outline, const Color(0xFFF59E0B)),
            _buildStatCard('Top Count', '$mostOfferedCount', Icons.bar_chart, const Color(0xFF22C55E)),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersSection(bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 14 : 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.filter_list, size: 18, color: Color(0xFF64748B)),
              SizedBox(width: 8),
              Text('Filters', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF0F172A))),
            ],
          ),
          const SizedBox(height: 12),

          // Date range row
          if (isMobile) ...[
            _buildDateChip('From', _dateFrom, () => _pickDate(true), () {
              setState(() => _dateFrom = null);
              _applyFilters();
            }),
            const SizedBox(height: 8),
            _buildDateChip('To', _dateTo, () => _pickDate(false), () {
              setState(() => _dateTo = null);
              _applyFilters();
            }),
          ] else
            Row(
              children: [
                Expanded(child: _buildDateChip('From', _dateFrom, () => _pickDate(true), () {
                  setState(() => _dateFrom = null);
                  _applyFilters();
                })),
                const SizedBox(width: 12),
                Expanded(child: _buildDateChip('To', _dateTo, () => _pickDate(false), () {
                  setState(() => _dateTo = null);
                  _applyFilters();
                })),
              ],
            ),
          const SizedBox(height: 12),

          // Client filter
          SearchableClientDropdown(
            clients: widget.clients,
            value: _filterClient,
            showAllOption: true,
            hintText: 'Search client...',
            onChanged: (val) {
              setState(() {
                _filterClient = val;
                _clientFilterController.text = val ?? '';
              });
              _applyFilters();
            },
          ),
          const SizedBox(height: 12),

          // Grade filter
          SearchableGradeDropdown(
            grades: widget.grades,
            value: _filterGrade,
            showAllOption: true,
            hintText: 'Search grade...',
            onChanged: (val) {
              setState(() => _filterGrade = val);
              _applyFilters();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDateChip(String label, DateTime? date, VoidCallback onTap, VoidCallback onClear) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: date != null ? const Color(0xFF3B82F6) : const Color(0xFFE2E8F0)),
          borderRadius: BorderRadius.circular(10),
          color: date != null ? const Color(0xFFEFF6FF) : null,
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today, size: 14, color: date != null ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                date != null ? '$label: ${DateFormat('dd MMM yyyy').format(date)}' : label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: date != null ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8),
                ),
              ),
            ),
            if (date != null)
              GestureDetector(
                onTap: onClear,
                child: const Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)),
              ),
          ],
        ),
      ),
    );
  }


  Widget _buildOffersList(bool isMobile) {
    if (_offersLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_offers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            children: [
              Icon(Icons.inbox_outlined, size: 48, color: Colors.grey[300]),
              const SizedBox(height: 12),
              Text(
                _hasActiveFilters ? 'No offers match your filters' : 'No offers yet',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
        ),
      );
    }

    // Group offers by date for section headers
    final Map<String, List<dynamic>> grouped = {};
    for (var offer in _offers) {
      final date = offer['date']?.toString() ?? 'Unknown';
      grouped.putIfAbsent(date, () => []);
      grouped[date]!.add(offer);
    }

    // Sort date keys: latest first
    final sortedDates = grouped.keys.toList()
      ..sort((a, b) => _parseOfferDate(b).compareTo(_parseOfferDate(a)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            '📋 Offers (${_offers.length})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
          ),
        ),
        ...sortedDates.map((date) {
          final offersForDate = grouped[date]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Date header
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 14, color: Color(0xFF94A3B8)),
                    const SizedBox(width: 6),
                    Text(date,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF64748B))),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('${offersForDate.length}',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                    ),
                  ],
                ),
              ),
              ...offersForDate.map((offer) => _buildOfferCard(offer, isMobile)),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildOfferCard(dynamic offer, bool isMobile) {
    final client = offer['client']?.toString() ?? 'Unknown';
    final billing = offer['billingFrom']?.toString() ?? 'SYGT';
    final mode = offer['mode']?.toString() ?? 'india';
    final paymentTerm = offer['paymentTerm']?.toString();
    final items = (offer['items'] as List<dynamic>?) ?? [];
    final isWorldwide = mode == 'worldwide';
    final gradesCount = items.length;
    final offerId = offer['id']?.toString() ?? '';
    final isSelected = _selectedOfferIds.contains(offerId);

    // Wrap with Dismissible for swipe-to-delete (admin only, not in select mode)
    Widget card = GestureDetector(
      onTap: _isSelectMode && offerId.isNotEmpty
          ? () => setState(() {
              if (isSelected) { _selectedOfferIds.remove(offerId); }
              else { _selectedOfferIds.add(offerId); }
            })
          : () => _showOfferDetail(offer),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFEF2F2) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isSelected ? const Color(0xFFEF4444) : const Color(0xFFE2E8F0)),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2)),
          ],
        ),
        child: Row(
          children: [
            // Checkbox in select mode
            if (_isSelectMode) ...[
              Checkbox(
                value: isSelected,
                onChanged: offerId.isNotEmpty ? (val) => setState(() {
                  if (val == true) { _selectedOfferIds.add(offerId); }
                  else { _selectedOfferIds.remove(offerId); }
                }) : null,
                activeColor: const Color(0xFFEF4444),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
            ],
            // Left: client name + grades summary
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    client,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$gradesCount grade${gradesCount != 1 ? 's' : ''} offered${isWorldwide ? '  •  ${paymentTerm ?? "WW"}' : ''}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            // Company badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                billing,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF22C55E)),
              ),
            ),
            const SizedBox(width: 6),
            // Share button
            IconButton(
              onPressed: () => _shareOffer(offer),
              icon: const Icon(Icons.share, size: 18, color: Color(0xFF25D366)),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: 'Share',
            ),
            // Re-edit button
            if (!_isSelectMode)
              IconButton(
                onPressed: () => _reuseOffer(offer),
                icon: const Icon(Icons.edit_note, size: 20, color: Color(0xFF3B82F6)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Re-edit',
              ),
          ],
        ),
      ),
    );

    // Wrap with Dismissible for swipe-to-delete (admin only, not in select mode)
    if (_isAdmin && !_isSelectMode && offerId.isNotEmpty) {
      card = Dismissible(
        key: ValueKey(offerId),
        direction: DismissDirection.endToStart,
        background: Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFEF4444),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        confirmDismiss: (_) async {
          HapticFeedback.mediumImpact();
          return await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Delete Offer'),
              content: const Text('Are you sure you want to delete this offer?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ) ?? false;
        },
        onDismissed: (_) async {
          try {
            await _apiService.deleteOffer(offerId);
            setState(() => _offers.removeWhere((o) => o['id'] == offerId));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Offer deleted')));
            }
          } catch (e) {
            _loadOffers(); // Reload on failure
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
            }
          }
        },
        child: card,
      );
    }

    return card;
  }
}
