import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;
import '../services/whatsapp_service.dart';
import '../services/api_service.dart';
import '../services/navigation_service.dart';
import '../widgets/app_shell.dart';
import '../widgets/grade_grouped_dropdown.dart';
import 'offer_history_screen.dart';

class OfferPriceScreen extends StatefulWidget {
  final Map<String, dynamic>? prefillData;

  const OfferPriceScreen({super.key, this.prefillData});

  @override
  State<OfferPriceScreen> createState() => _OfferPriceScreenState();
}

class _OfferPriceScreenState extends State<OfferPriceScreen> with RouteAware {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;

  // Header fields
  String _billingFrom = 'SYGT';
  late DateTime _selectedDate;
  String _selectedClient = '';
  final TextEditingController _clientController = TextEditingController();

  // India / Worldwide toggle
  bool _isWorldwide = false;
  String _paymentTerm = 'FOB'; // FOB, CNF, CIF

  // GST toggle: true = Including Tax (default), false = Excluding GST (base + GST)
  bool _isIncludingTax = true;

  // Dropdown data
  List<String> _grades = [];
  List<String> _clients = [];

  // Smart suggestions
  List<Map<String, dynamic>> _suggestions = [];
  bool _suggestionsLoading = true;

  // Exchange rate
  double? _usdToInrRate;

  // Grade rows: each {grade, qty, price} with controllers
  final List<Map<String, String>> _gradeRows = [];
  final List<_RowControllers> _rowControllers = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void didPopNext() => _loadSuggestions();

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _loadDropdowns();
    _loadSuggestions();

    // Prefill from existing offer (re-edit from history)
    final prefill = widget.prefillData;
    if (prefill != null) {
      _billingFrom = prefill['billingFrom']?.toString() ?? 'SYGT';
      _selectedClient = prefill['client']?.toString() ?? '';
      _clientController.text = _selectedClient;
      _isWorldwide = prefill['mode']?.toString() == 'worldwide';
      _paymentTerm = prefill['paymentTerm']?.toString() ?? 'FOB';

      // Parse date
      try {
        final dateStr = prefill['date']?.toString() ?? '';
        final parts = dateStr.split('/');
        if (parts.length == 3) {
          var year = int.parse(parts[2]);
          if (year < 100) year += 2000;
          _selectedDate = DateTime(year, int.parse(parts[1]), int.parse(parts[0]));
        }
      } catch (_) {}

      // Prefill grade rows
      final items = (prefill['items'] as List<dynamic>?) ?? [];
      for (var item in items) {
        final grade = item['grade']?.toString() ?? '';
        final qty = item['qty']?.toString() ?? '';
        final price = item['price']?.toString() ?? '';
        _gradeRows.add({'grade': grade, 'qty': qty, 'price': price});
        final rc = _RowControllers();
        rc.qtyController.text = qty;
        rc.priceController.text = price;
        _rowControllers.add(rc);
      }
      if (_gradeRows.isEmpty) _addGradeRow();
    } else {
      _addGradeRow();
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _clientController.dispose();
    for (final rc in _rowControllers) {
      rc.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDropdowns() async {
    try {
      final response = await _apiService.getDropdownOptions();
      setState(() {
        _grades = (response.data['grade'] as List<dynamic>?)
                ?.map((e) => e.toString()).toList() ?? [];
        _clients = (response.data['client'] as List<dynamic>?)
                ?.map((e) => e.toString()).toList() ?? [];
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading data: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _loadSuggestions() async {
    try {
      final results = await Future.wait([
        _apiService.getOfferSuggestions(),
        _apiService.getExchangeRate(),
      ]);

      final sugData = results[0].data;
      final rateData = results[1].data;

      setState(() {
        if (sugData['success'] == true && sugData['suggestions'] != null) {
          _suggestions = List<Map<String, dynamic>>.from(sugData['suggestions']);
        }
        if (rateData['success'] == true && rateData['usdToInr'] != null) {
          _usdToInrRate = (rateData['usdToInr'] as num).toDouble();
        }
        _suggestionsLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading suggestions: $e');
      setState(() => _suggestionsLoading = false);
    }
  }

  void _applySuggestion(Map<String, dynamic> suggestion) {
    final grade = suggestion['grade']?.toString() ?? '';
    final price = suggestion['price']?.toString() ?? '';
    final qty = suggestion['qty']?.toString() ?? '';

    setState(() {
      // If first row is empty, fill it
      if (_gradeRows.length == 1 &&
          _gradeRows[0]['grade']!.isEmpty &&
          _gradeRows[0]['price']!.isEmpty) {
        _gradeRows[0] = {'grade': grade, 'qty': qty, 'price': price};
        _rowControllers[0].qtyController.text = qty;
        _rowControllers[0].priceController.text = price;
      } else {
        // Add new row with suggestion values
        _gradeRows.add({'grade': grade, 'qty': qty, 'price': price});
        final rc = _RowControllers();
        rc.qtyController.text = qty;
        rc.priceController.text = price;
        _rowControllers.add(rc);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added $grade'),
        backgroundColor: const Color(0xFF22C55E),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _addGradeRow() {
    setState(() {
      _gradeRows.add({'grade': '', 'qty': '', 'price': ''});
      _rowControllers.add(_RowControllers());
    });
  }

  void _removeGradeRow(int index) {
    if (_gradeRows.length <= 1) return;
    setState(() {
      _rowControllers[index].dispose();
      _gradeRows.removeAt(index);
      _rowControllers.removeAt(index);
    });
  }

  String _companyName() {
    return _billingFrom.toUpperCase() == 'ESPL'
        ? 'Emperor Spices Pvt Ltd'
        : 'Sri Yogaganapathi Traders';
  }

  String _formatBasePrice(String priceText) {
    final price = double.tryParse(priceText);
    if (price == null || price <= 0) return '';
    final base = price / 1.05;
    return base == base.roundToDouble()
        ? base.round().toString()
        : base.toStringAsFixed(2);
  }

  Widget _buildOfferCardWidget(List<Map<String, String>> items) {
    final companyName = _companyName();
    final dateStr = DateFormat('dd/MM/yy').format(_selectedDate);

    return Material(
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
              // Green top banner with title
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
                    if (_isWorldwide) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _paymentTerm,
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Card content
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Company logo + name
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(
                            _billingFrom.toUpperCase() == 'ESPL' ? 'assets/emperor_logo.jpg' : 'assets/yoga_logo.png',
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                          ),
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
                    // Client + date
                    Row(
                      children: [
                        const Icon(Icons.person, color: Color(0xFF64748B), size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _selectedClient,
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
                            Text(
                              dateStr,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Grade items
                    ...items.map((item) {
                      final hasQty = item['qty'] != null && item['qty']!.isNotEmpty && item['qty'] != '0';
                      final qtyText = hasQty ? ' — ${item['qty']} kgs' : '';
                      String priceText;
                      if (_isWorldwide) {
                        priceText = '\$${item['price']}';
                      } else if (_isIncludingTax) {
                        priceText = '₹${item['price']} incl. GST';
                      } else {
                        final basePrice = _formatBasePrice(item['price']!);
                        priceText = '₹$basePrice plus GST';
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: const Border(
                            left: BorderSide(color: Color(0xFF22C55E), width: 3),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                '${item['grade']}$qtyText — $priceText',
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF334155)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF22C55E),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _billingFrom,
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
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
  }

  Future<void> _sendOffer() async {
    // Validate
    final validRows = _gradeRows.where((r) =>
        r['grade']!.isNotEmpty && r['price']!.isNotEmpty).toList();
    if (validRows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one grade with price'), backgroundColor: Colors.orange),
      );
      return;
    }
    if (_selectedClient.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a client'), backgroundColor: Colors.orange),
      );
      return;
    }

    // Show preview dialog
    final confirmed = await _showPreviewDialog(validRows);
    if (confirmed != true || !mounted) return;

    try {
      // Save to backend (non-blocking — don't wait for response)
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username') ?? '';
      // Fire API save in background — don't block image capture
      _apiService.createOffer({
        'billingFrom': _billingFrom,
        'date': DateFormat('dd/MM/yy').format(_selectedDate),
        'client': _selectedClient,
        'mode': _isWorldwide ? 'worldwide' : 'india',
        'currency': _isWorldwide ? 'USD' : 'INR',
        'paymentTerm': _isWorldwide ? _paymentTerm : null,
        'items': validRows.map((r) => {
          'grade': r['grade'],
          'qty': r['qty'],
          'price': r['price'],
        }).toList(),
        'createdBy': username,
      }).then((_) {
        // Offer saved successfully
      }).catchError((e) {
        debugPrint('Error saving offer: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save offer: $e'), backgroundColor: Colors.red),
          );
        }
      });

      // Generate image and share immediately (no loading dialog)
      await _captureAndShare(validRows, () {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<bool?> _showPreviewDialog(List<Map<String, String>> items) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(
                  children: [
                    const Icon(Icons.preview, color: Color(0xFF3B82F6), size: 22),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Preview Offer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      icon: const Icon(Icons.close, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Scrollable preview
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _buildOfferCardWidget(items),
                ),
              ),
              const Divider(height: 1),
              // Action buttons
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF64748B),
                          side: const BorderSide(color: Color(0xFFCBD5E1)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Edit', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.pop(ctx, true),
                        icon: const Icon(Icons.send_rounded, size: 18),
                        label: const Text('Confirm & Share', style: TextStyle(fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF22C55E),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _captureAndShare(List<Map<String, String>> items, VoidCallback closeLoading) async {
    final cardWidget = _buildOfferCardWidget(items);

    // Render offscreen and capture
    final overlayState = Overlay.of(context);
    late OverlayEntry overlayEntry;
    final captureKey = GlobalKey();

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: -1000,
        top: -1000,
        child: RepaintBoundary(
          key: captureKey,
          child: cardWidget,
        ),
      ),
    );

    overlayState.insert(overlayEntry);
    await Future.delayed(const Duration(milliseconds: 300));

    final RenderRepaintBoundary boundary =
        captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final Uint8List rawPngBytes = byteData!.buffer.asUint8List();

    overlayEntry.remove();

    // Convert PNG → high-quality JPEG to reduce file size (WhatsApp compresses large PNGs aggressively)
    final decoded = img.decodeImage(rawPngBytes);
    final Uint8List pngBytes;
    if (decoded != null) {
      pngBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 95));
    } else {
      pngBytes = rawPngBytes; // fallback to original PNG
    }

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/offer_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(pngBytes);

    closeLoading();

    if (!mounted) return;

    // Open native share sheet — user manually selects WhatsApp contact
    if (mounted) {
      final box = context.findRenderObject() as RenderBox?;
      final sharePositionOrigin = box != null
          ? box.localToGlobal(Offset.zero) & box.size
          : const Rect.fromLTWH(0, 0, 100, 100);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/jpeg')],
        sharePositionOrigin: sharePositionOrigin,
      );
    }

    // Soft reset and show success popup
    if (mounted) {
      _resetForm();
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          contentPadding: const EdgeInsets.all(32),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 48),
              ),
              const SizedBox(height: 20),
              const Text('✅ Offer Shared', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF185A9D),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('➕ Create Another', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => OfferHistoryScreen(clients: _clients, grades: _grades),
                    ));
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF22C55E),
                    side: const BorderSide(color: Color(0xFF22C55E)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('📋 View History', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  void _resetForm() {
    setState(() {
      _billingFrom = 'SYGT';
      _selectedDate = DateTime.now();
      _selectedClient = '';
      _clientController.clear();

      _isWorldwide = false;
      _paymentTerm = 'FOB';
      // Clear all grade rows and controllers
      for (final rc in _rowControllers) {
        rc.dispose();
      }
      _gradeRows.clear();
      _rowControllers.clear();
      // Add one fresh empty row
      _gradeRows.add({'grade': '', 'qty': '', 'price': ''});
      _rowControllers.add(_RowControllers());
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return AppShell(
      disableInternalScrolling: true,
      title: '🏷️ Offer Price',
      subtitle: 'Create and share price offers for clients.',
      topActions: [
        ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OfferHistoryScreen(
                  clients: _clients,
                  grades: _grades,
                ),
              ),
            );
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF3B82F6),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
          child: const Text('📋 Offer History', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ],
      content: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: EdgeInsets.all(isMobile ? 12 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header card
                  Container(
                    padding: EdgeInsets.all(isMobile ? 16 : 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Billing From + Date row
                        if (isMobile) ...[
                          _buildBillingDropdown(),
                          const SizedBox(height: 16),
                          _buildDatePicker(),
                        ] else
                          Row(
                            children: [
                              Expanded(child: _buildBillingDropdown()),
                              const SizedBox(width: 16),
                              Expanded(child: _buildDatePicker()),
                            ],
                          ),
                        const SizedBox(height: 16),
                        // Client field
                        _buildClientField(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // India / Worldwide toggle
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildToggleButton('🇮🇳 India', !_isWorldwide, () => setState(() => _isWorldwide = false)),
                          _buildToggleButton('🌍 Worldwide', _isWorldwide, () => setState(() => _isWorldwide = true)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Payment Term (Worldwide only)
                  if (_isWorldwide) ...[
                    Container(
                      padding: EdgeInsets.all(isMobile ? 16 : 24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Payment Term', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: const Color(0xFFE2E8F0)),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _paymentTerm,
                                isExpanded: true,
                                items: const [
                                  DropdownMenuItem(value: 'FOB', child: Text('FOB (Free on Board)', style: TextStyle(fontWeight: FontWeight.w600))),
                                  DropdownMenuItem(value: 'CNF', child: Text('CNF (Cost & Freight)', style: TextStyle(fontWeight: FontWeight.w600))),
                                  DropdownMenuItem(value: 'CIF', child: Text('CIF (Cost, Insurance & Freight)', style: TextStyle(fontWeight: FontWeight.w600))),
                                ],
                                onChanged: (v) => setState(() => _paymentTerm = v!),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Subheading
                  const Padding(
                    padding: EdgeInsets.only(left: 4, bottom: 12),
                    child: Text(
                      '🌿 Small Green Cardamom - Price Offer',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF2D6A4F)),
                    ),
                  ),

                  // Smart suggestions
                  if (!_suggestionsLoading && _suggestions.isNotEmpty)
                    _buildSuggestionsSection(),

                  // Grade rows
                  ...List.generate(_gradeRows.length, (i) => _buildGradeRow(i)),

                  // Add row button
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: OutlinedButton.icon(
                      onPressed: _addGradeRow,
                      icon: const Icon(Icons.add_circle_outline, size: 20),
                      label: const Text('Add Grade'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF3B82F6),
                        side: const BorderSide(color: Color(0xFF3B82F6)),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // GST Toggle — only for India (domestic) mode
                  if (!_isWorldwide)
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: _isIncludingTax ? const Color(0xFFF0FDF4) : const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _isIncludingTax ? const Color(0xFF22C55E).withOpacity(0.3) : const Color(0xFFF59E0B).withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _isIncludingTax ? Icons.receipt_long : Icons.receipt,
                            color: _isIncludingTax ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isIncludingTax ? 'Including Tax' : 'Excluding GST',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: _isIncludingTax ? const Color(0xFF166534) : const Color(0xFF92400E),
                                  ),
                                ),
                                Text(
                                  _isIncludingTax ? 'Price shown as entered (incl. GST)' : 'Price reduced by 5% GST and shown as base + GST',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: _isIncludingTax ? const Color(0xFF166534).withOpacity(0.7) : const Color(0xFF92400E).withOpacity(0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _isIncludingTax,
                            onChanged: (val) => setState(() => _isIncludingTax = val),
                            activeColor: const Color(0xFF22C55E),
                            inactiveThumbColor: const Color(0xFFF59E0B),
                            inactiveTrackColor: const Color(0xFFF59E0B).withOpacity(0.3),
                          ),
                        ],
                      ),
                    ),

                  // Send Offer button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _sendOffer,
                      icon: const Icon(Icons.send_rounded, size: 20),
                      label: const Text('Send Offer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF22C55E),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  // =========== FORM WIDGETS ===========

  Widget _buildSuggestionsSection() {
    final targetCurrency = _isWorldwide ? 'USD' : 'INR';
    final filteredSuggestions = _suggestions
        .where((s) => (s['currency']?.toString() ?? 'INR') == targetCurrency)
        .toList();

    if (filteredSuggestions.isEmpty) return const SizedBox.shrink();

    final currencySymbol = _isWorldwide ? '\$' : '₹';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Row(
              children: [
                Icon(Icons.lightbulb_outline, size: 16, color: Color(0xFFF59E0B)),
                SizedBox(width: 6),
                Text(
                  'Recent Prices (tap to add)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: filteredSuggestions.map((s) {
                final grade = s['grade']?.toString() ?? '';
                final price = s['price']?.toString() ?? '';
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(Icons.add, size: 16, color: Color(0xFF2D6A4F)),
                    label: Text(
                      '$grade  $currencySymbol$price',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2D6A4F)),
                    ),
                    backgroundColor: const Color(0xFFDCFCE7),
                    side: const BorderSide(color: Color(0xFFA7F3D0)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    onPressed: () => _applySuggestion(s),
                  ),
                );
              }).toList(),
            ),
          ),
          // Exchange rate info (shown in Worldwide mode)
          if (_isWorldwide && _usdToInrRate != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 6),
              child: Text(
                'Exchange rate: 1 USD = ₹${_usdToInrRate!.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBillingDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Billing From', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _billingFrom,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'SYGT', child: Text('SYGT', style: TextStyle(fontWeight: FontWeight.w600))),
                DropdownMenuItem(value: 'ESPL', child: Text('ESPL', style: TextStyle(fontWeight: FontWeight.w600))),
              ],
              onChanged: (v) => setState(() => _billingFrom = v!),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDatePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
        const SizedBox(height: 6),
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _selectedDate,
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (picked != null) setState(() => _selectedDate = picked);
          },
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE2E8F0)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_today, size: 16, color: Color(0xFF64748B)),
                const SizedBox(width: 8),
                Text(
                  DateFormat('dd MMM yyyy').format(_selectedDate),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToggleButton(String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: isActive
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 4, offset: const Offset(0, 2))]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: isActive ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
          ),
        ),
      ),
    );
  }

  Widget _buildClientField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Client', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
        const SizedBox(height: 6),
        SearchableClientDropdown(
          clients: _clients,
          value: _selectedClient.isEmpty ? null : _selectedClient,
          showAllOption: false,
          showAddNew: true,
          hintText: 'Search client...',
          onChanged: (val) {
            setState(() {
              _selectedClient = val ?? '';
              _clientController.text = val ?? '';
            });
          },
          onAddNew: (name) => _showAddNewClientDialog(name),
        ),
      ],
    );
  }

  Future<void> _showAddNewClientDialog(String name) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return;

    // Search for similar clients via API
    List<Map<String, dynamic>> similarClients = [];
    try {
      final response = await _apiService.searchDropdownItems('clients', trimmedName);
      final data = response.data as Map<String, dynamic>;
      final exact = (data['exactMatches'] as List<dynamic>?) ?? [];
      final similar = (data['similarMatches'] as List<dynamic>?) ?? [];
      similarClients = [...exact, ...similar].cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('Error searching dropdown options: $e');
    }

    if (!mounted) return;

    bool shouldAdd = true;

    // Show similar clients dialog if found
    if (similarClients.isNotEmpty) {
      shouldAdd = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Similar Client Found', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Found clients with similar names:'),
              const SizedBox(height: 12),
              ...similarClients.take(5).map((c) {
                final clientName = c['value'] ?? c['name'] ?? '';
                final similarity = c['similarity'];
                final pct = similarity != null
                    ? (similarity is int ? '$similarity% similar' : '${(similarity * 100).toInt()}% similar')
                    : '';
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: const Color(0xFFCBD5E1),
                    child: Text(
                      clientName.isNotEmpty ? clientName[0].toUpperCase() : '?',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E)),
                    ),
                  ),
                  title: Text(clientName),
                  trailing: pct.isNotEmpty
                      ? Text(pct, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12))
                      : null,
                  onTap: () {
                    Navigator.pop(ctx, false);
                    setState(() {
                      _selectedClient = clientName;
                      _clientController.text = clientName;
                
                    });
                  },
                );
              }),
              const SizedBox(height: 12),
              Text('Do you still want to add "$trimmedName" as a new client?'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
              child: const Text('Add Anyway', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ) ?? false;
    }

    if (!shouldAdd || !mounted) return;

    // Save new client
    try {
      final response = similarClients.isNotEmpty
          ? await _apiService.forceAddDropdownItem('clients', trimmedName)
          : await _apiService.addDropdownItem('clients', trimmedName);
      if (response.data['success'] == true) {
        await _loadDropdowns();
        if (!mounted) return;
        setState(() {
          _selectedClient = trimmedName;
          _clientController.text = trimmedName;
    
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text('Client "$trimmedName" added successfully!')),
            ]),
            backgroundColor: const Color(0xFF22C55E),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      } else if (response.data['isDuplicate'] == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Client "${response.data['existingValue']}" already exists'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error adding client: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _buildGradeRow(int index) {
    final row = _gradeRows[index];
    final rc = _rowControllers[index];
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row number + remove button
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '#${index + 1}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF3B82F6)),
                ),
              ),
              const Spacer(),
              if (_gradeRows.length > 1)
                IconButton(
                  onPressed: () => _removeGradeRow(index),
                  icon: const Icon(Icons.close_rounded, size: 20, color: Color(0xFFEF4444)),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Grade autocomplete
          const Text('Grade', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
          const SizedBox(height: 4),
          SearchableGradeDropdown(
            key: ValueKey('grade_${index}_${row['grade']}'),
            grades: _grades,
            value: (row['grade'] ?? '').isEmpty ? null : row['grade'],
            showAllOption: false,
            hintText: 'Search grade...',
            onChanged: (val) => setState(() => _gradeRows[index]['grade'] = val ?? ''),
          ),
          const SizedBox(height: 12),

          // Qty + Price row
          Row(
            children: [
              // Qty field
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Qty (kgs)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                    const SizedBox(height: 4),
                    TextField(
                      controller: rc.qtyController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        hintText: 'Optional',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        isDense: true,
                      ),
                      onChanged: (val) => setState(() => _gradeRows[index]['qty'] = val),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Price field (GST inclusive)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isWorldwide ? 'Price (USD)' : 'Price (incl. GST)',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 4),
                    TextField(
                      controller: rc.priceController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        hintText: _isWorldwide ? '\$' : '₹',
                        prefixText: _isWorldwide ? '\$ ' : '₹ ',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        isDense: true,
                      ),
                      onChanged: (val) => setState(() => _gradeRows[index]['price'] = val),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Base price helper text (India only — shows GST breakdown)
          if (!_isWorldwide && _gradeRows[index]['price'] != null && _gradeRows[index]['price']!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Base: ₹${_formatBasePrice(_gradeRows[index]['price']!)} + GST (5%)',
              style: const TextStyle(fontSize: 11, color: Color(0xFF22C55E), fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }
}

/// Holds TextEditingControllers for a single grade row
class _RowControllers {
  final TextEditingController qtyController = TextEditingController();
  final TextEditingController priceController = TextEditingController();

  void dispose() {
    qtyController.dispose();
    priceController.dispose();
  }
}
