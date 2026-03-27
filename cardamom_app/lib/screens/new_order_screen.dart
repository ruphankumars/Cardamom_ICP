import 'dart:convert';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/whatsapp_service.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../services/api_service.dart';
import '../services/analytics_service.dart';
import '../services/cache_manager.dart';
import '../services/connectivity_service.dart';
import '../services/persistent_operation_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/suggested_price_card.dart';
import '../widgets/grade_grouped_dropdown.dart';

class NewOrderScreen extends StatefulWidget {
  final Map<String, dynamic>? prefillData;
  const NewOrderScreen({super.key, this.prefillData});

  @override
  State<NewOrderScreen> createState() => _NewOrderScreenState();
}

class _NewOrderScreenState extends State<NewOrderScreen> {
  final ApiService _apiService = ApiService();
  final _orderDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  String _billingFrom = 'SYGT';
  String? _selectedClient;
  Map<String, dynamic> _suborders = {}; 
  List<Map<String, dynamic>> _suborderList = []; 
  final Map<int, Map<String, TextEditingController>> _suborderControllers = {};
  final TextEditingController _clientSearchController = TextEditingController();
  bool _showClientResults = false;
  Map<String, dynamic> _dropdowns = {};
  bool _isLoading = true;
  int _nextLotBaseNumber = 0;
  String? _requestId; // To track if this is a conversion
  bool _isConversion = false;
  List<Map<String, dynamic>> _lastSubmittedOrders = []; // Store for sharing
  String _userRole = 'user';
  bool _isSubmitting = false;

  bool get _isAdmin {
    final role = _userRole.toLowerCase().trim();
    final isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
    debugPrint('🔐 [NewOrder] Role: "$_userRole" -> isAdmin: $isAdmin');
    return isAdmin;
  }

  final AnalyticsService _analyticsService = AnalyticsService();
  List<SuggestedPrice> _suggestedPrices = [];

  static const List<Map<String, String>> _countryCodes = [
    {'code': '91', 'flag': '🇮🇳', 'label': '+91 India'},
    {'code': '971', 'flag': '🇦🇪', 'label': '+971 UAE'},
    {'code': '966', 'flag': '🇸🇦', 'label': '+966 Saudi'},
    {'code': '974', 'flag': '🇶🇦', 'label': '+974 Qatar'},
    {'code': '968', 'flag': '🇴🇲', 'label': '+968 Oman'},
    {'code': '973', 'flag': '🇧🇭', 'label': '+973 Bahrain'},
    {'code': '965', 'flag': '🇰🇼', 'label': '+965 Kuwait'},
    {'code': '1', 'flag': '🇺🇸', 'label': '+1 US'},
    {'code': '44', 'flag': '🇬🇧', 'label': '+44 UK'},
    {'code': '65', 'flag': '🇸🇬', 'label': '+65 Singapore'},
    {'code': '60', 'flag': '🇲🇾', 'label': '+60 Malaysia'},
  ];

  @override
  void initState() {
    super.initState();
    _loadDropdowns();
    if (widget.prefillData != null) {
      _processPrefillData(widget.prefillData!);
    } else {
      _addSuborder();
    }
  }

  @override
  void dispose() {
    _orderDateController.dispose();
    _clientSearchController.dispose();
    for (final controllers in _suborderControllers.values) {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _loadDropdowns() async {
    // Load each independently so one failure doesn't block the others
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';
    } catch (e) {
      debugPrint('[NewOrder] Error loading role: $e');
    }

    // Use CacheManager for dropdown data — works offline
    try {
      final cacheManager = context.read<CacheManager>();
      final result = await cacheManager.fetchWithCache<Map<String, dynamic>>(
        apiCall: () async {
          final response = await _apiService.getDropdownOptions();
          return Map<String, dynamic>.from(response.data);
        },
        cache: cacheManager.dropdownCache,
      );
      if (mounted) setState(() => _dropdowns = result.data);
    } catch (e) {
      debugPrint('[NewOrder] Error loading dropdowns: $e');
    }

    try {
      final suggestions = await _analyticsService.getSuggestedPrices();
      if (mounted) setState(() => _suggestedPrices = suggestions);
    } catch (e) {
      debugPrint('[NewOrder] Error loading suggestions: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  void _processPrefillData(Map<String, dynamic> data) {
    setState(() {
      _selectedClient = data['client'];
      _requestId = data['requestId']?.toString();
      _isConversion = _requestId != null;

      if (data['billingFrom'] != null) {
        _billingFrom = data['billingFrom'].toString();
      }

      if (data['items'] != null) {
        _suborderList.clear();
        for (var item in data['items']) {
          _addSuborder(item: item);
        }
      }
      
      if (_selectedClient != null) {
        _clientSearchController.text = _selectedClient!;
        _fetchNextLotNumber(_selectedClient!);
      }
    });
  }

  Future<void> _fetchNextLotNumber(String client) async {
    try {
      final resp = await _apiService.getNextLotNumber(client);
      final nextLot = resp.data['nextLotNumber'];
      setState(() {
        _nextLotBaseNumber = nextLot ?? 1;
        _assignAutoLots();
      });
    } catch (e) {
      debugPrint('Error fetching lot number: $e');
    }
  }

  void _assignAutoLots() {
    for (int i = 0; i < _suborderList.length; i++) {
        // Only assign lots to selected items to maintain sequence in those actually being ordered?
        // Actually, the manual says "Sequential Lot Numbering Logic (L + nextLot + index)".
        // It's better to assign to all, then filter.
        final lotNum = 'L${_nextLotBaseNumber + i}';
        _suborderList[i]['lot'] = lotNum;
        _suborderControllers[i]?['lot']?.text = lotNum;
    }
  }

  void _addSuborder({Map<String, dynamic>? item}) {
    setState(() {
      final index = _suborderList.length;
      final bagbox = item?['bagbox'] ?? 'Bag';
      final multiplier = (bagbox == 'Bag') ? 50 : (bagbox == 'Box' ? 20 : null);
      final kgs = item?['kgs'] ?? (item?['offeredKgs'] ?? item?['requestedKgs'] ?? 0);
      final no = item?['no'] ?? (item?['offeredNo'] ?? item?['requestedNo'] ?? (multiplier != null && kgs > 0 ? kgs / multiplier : 0));

      final lotText = '';
      final noText = no == 0 ? '' : no.toString().replaceFirst(RegExp(r'\.0$'), '');
      final kgsText = kgs == 0 ? '' : kgs.toString().replaceFirst(RegExp(r'\.0$'), '');
      final priceText = (item?['price'] ?? item?['unitPrice'] ?? '').toString();
      final notesText = item?['notes'] ?? '';

      _suborderControllers[index] = {
        'lot': TextEditingController(text: lotText),
        'no': TextEditingController(text: noText),
        'kgs': TextEditingController(text: kgsText),
        'price': TextEditingController(text: priceText),
        'notes': TextEditingController(text: notesText),
      };

      final newSub = {
        'lot': lotText,
        'grade': item?['grade'] ?? '',
        'bagbox': bagbox,
        'no': noText,
        'kgs': kgsText,
        'price': priceText,
        'brand': item?['brand'] ?? '',
        'notes': notesText,
        'isSelected': true,
      };
      _suborderList.add(newSub);
      _assignAutoLots();
    });
  }

  void _removeSuborder(int index) {
    setState(() {
      _suborderList.removeAt(index);
      // Clean up controllers and shift them
      final oldControllers = Map<int, Map<String, TextEditingController>>.from(_suborderControllers);
      _suborderControllers.clear();
      for (int i = 0; i < _suborderList.length; i++) {
        if (i < index) {
          _suborderControllers[i] = oldControllers[i]!;
        } else {
          _suborderControllers[i] = oldControllers[i+1]!;
        }
      }
      _assignAutoLots();
    });
  }

  Future<void> _submitAll() async {
    // Prevent double-tap / multiple submissions — set flag immediately
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    if (_selectedClient == null || _selectedClient!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a client')));
      setState(() => _isSubmitting = false);
      return;
    }

    final selectedSuborders = _suborderList.where((s) => s['isSelected'] == true).toList();
    if (selectedSuborders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select at least one suborder')));
      setState(() => _isSubmitting = false);
      return;
    }

    // Duplicate suborder detection: Compare date+client+grade+quantity+rate+notes
    final orderDate = _orderDateController.text;
    final Set<String> seen = {};
    for (int i = 0; i < _suborderList.length; i++) {
      final s = _suborderList[i];
      if (s['isSelected'] != true) continue;

      final controllers = _suborderControllers[i]!;
      final grade = s['grade']?.toString() ?? '';
      final kgs = controllers['kgs']!.text.trim();
      final price = controllers['price']!.text.trim();
      final notes = controllers['notes']!.text.trim();

      // Create unique key: date|client|grade|kgs|price|notes
      final key = '$orderDate|$_selectedClient|$grade|$kgs|$price|$notes';
      
      if (seen.contains(key)) {
        // Show duplicate alert popup
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 24),
                ),
                const SizedBox(width: 12),
                const Text('Duplicate Entry Found'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'You are trying to add a duplicate suborder entry:',
                  style: TextStyle(color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFCD34D)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Date: $orderDate', style: const TextStyle(fontSize: 12)),
                      Text('Client: $_selectedClient', style: const TextStyle(fontSize: 12)),
                      Text('Grade: $grade', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      Text('Quantity: $kgs kgs', style: const TextStyle(fontSize: 12)),
                      Text('Rate: ₹$price', style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Please remove or modify the duplicate entry before submitting.',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E)),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        setState(() => _isSubmitting = false);
        return;
      }
      seen.add(key);
    }

    // Comprehensive per-suborder validation (matching HTML/JS)
    for (int i = 0; i < _suborderList.length; i++) {
      final s = _suborderList[i];
      if (s['isSelected'] == false) continue; // Skip unselected items

      final controllers = _suborderControllers[i]!;
      final suborderNum = i + 1;
      
      // Validate grade
      if (s['grade'] == null || s['grade'].toString().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Please select a grade for Suborder $suborderNum'))
        );
        setState(() => _isSubmitting = false);
        return;
      }

      // Validate bagbox
      if (s['bagbox'] == null || s['bagbox'].toString().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Please select Bag/Box for Suborder $suborderNum'))
        );
        setState(() => _isSubmitting = false);
        return;
      }

      // Validate lot number
      final lotValue = controllers['lot']!.text.trim();
      if (lotValue.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lot numbers are not generated. Please select a client.'))
        );
        setState(() => _isSubmitting = false);
        return;
      }

      // Validate quantity for bag/box
      final bagbox = s['bagbox'].toString().toLowerCase();
      final multiplier = bagbox.contains('bag') ? 50 : (bagbox.contains('box') ? 20 : null);
      final noValue = double.tryParse(controllers['no']!.text) ?? 0;
      if (multiplier != null && noValue <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Enter the number of ${s['bagbox']} for Suborder $suborderNum'))
        );
        setState(() => _isSubmitting = false);
        return;
      }

      // Validate kgs
      final kgsValue = double.tryParse(controllers['kgs']!.text) ?? 0;
      if (kgsValue <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Enter a valid quantity in kgs for Suborder $suborderNum'))
        );
        setState(() => _isSubmitting = false);
        return;
      }

      // Validate price
      final priceValue = double.tryParse(controllers['price']!.text) ?? 0;
      if (priceValue <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Enter a valid price for Suborder $suborderNum'))
        );
        setState(() => _isSubmitting = false);
        return;
      }
    }

    // Format date to DD/MM/YY
    final dateParts = _orderDateController.text.split('-');
    final formattedDate = '${dateParts[2]}/${dateParts[1]}/${dateParts[0].substring(2)}';

    try {
      // Get current user info for createdBy tracking
      final prefs = await SharedPreferences.getInstance();
      final createdBy = prefs.getString('username') ?? 'unknown';
      
      final List<Map<String, dynamic>> orders = _suborderList.asMap().entries
          .where((entry) => entry.value['isSelected'] == true)
          .map((entry) {
        final i = entry.key;
        final s = entry.value;
        final controllers = _suborderControllers[i]!;
        return {
          'orderDate': formattedDate,
          'billingFrom': _billingFrom,
          'client': _selectedClient,
          'lot': controllers['lot']!.text,
          'grade': s['grade'],
          'bagbox': s['bagbox'],
          'no': double.tryParse(controllers['no']!.text) ?? 0,
          'kgs': double.tryParse(controllers['kgs']!.text) ?? 0,
          'price': double.tryParse(controllers['price']!.text) ?? 0,
          'brand': s['brand'],
          'notes': controllers['notes']!.text,
          'createdBy': createdBy, // Track which admin/user created this order
        };
      }).toList();

      if (_isConversion && _requestId != null) {
        final resp = await _apiService.convertRequestToOrder(_requestId!, {
          'billingFrom': _billingFrom,
          'brand': orders.isNotEmpty ? orders[0]['brand'] : '',
          'orders': orders,
        });
        if (resp.data['success'] == true) {
          // For conversion mode, return success result to caller
          if (Navigator.canPop(context)) {
            Navigator.pop(context, true); // Return success
          } else {
            Navigator.pushReplacementNamed(context, '/');
          }
        } else {
          throw Exception(resp.data['error'] ?? 'Conversion failed');
        }
      } else {
        // Non-admin users go through approval workflow
        if (!_isAdmin) {
          await _requestOrderApproval(orders);
          return;
        }

        // Admin flow - create orders directly (with offline support)
        final connectivity = context.read<ConnectivityService>();
        if (!connectivity.isOnline) {
          // Queue for later sync — add idempotency keys to prevent duplicates on replay
          final opId = 'order_${DateTime.now().millisecondsSinceEpoch}';
          final ordersWithKeys = orders.asMap().entries.map((e) {
            final order = Map<String, dynamic>.from(e.value as Map);
            order['idempotencyKey'] = '${opId}_${e.key}';
            return order;
          }).toList();

          final persistentQueue = context.read<PersistentOperationQueue>();
          await persistentQueue.enqueue(PendingOperation(
            id: opId,
            type: 'create_orders',
            method: 'POST',
            endpoint: '/orders/batch',
            payload: {
              'orders': ordersWithKeys,
              'sendWhatsApp': true,  // Backend will auto-send WhatsApp on replay
            },
          ));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Order queued — will sync when online'),
                backgroundColor: Colors.orange,
              ),
            );
            Navigator.pop(context);
          }
          return;
        }

        await _apiService.addOrders(orders);

        // Store orders for sharing
        _lastSubmittedOrders = orders;

        // Auto-send WhatsApp in background (don't await — show popup immediately)
        _shareOrderToClient(orders).catchError((e) {
          debugPrint('Auto WhatsApp send error: $e');
        });

        // Show success popup with remaining options (send already triggered)
        await _showSuccessPopup(orders);
      }
    } catch (e) {
      debugPrint('Error: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _showSuccessPopup(List<Map<String, dynamic>> orders) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.all(32),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 48),
              ),
              const SizedBox(height: 20),
              const Text(
                '✅ Submitted & Sent',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF4A5568)),
              ),
              const SizedBox(height: 12),
              Text(
                'Successfully added ${orders.length} order(s)!\nWhatsApp confirmation sent automatically.',
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A5568),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('📊 Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF185A9D),
                    side: const BorderSide(color: Color(0xFF185A9D)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('➕ Add Another', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pushNamed(context, '/view_orders');
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF22C55E),
                    side: const BorderSide(color: Color(0xFF22C55E)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('📋 View Orders', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Soft-reset form when dialog is dismissed (outside tap or any button)
    _resetForm();
  }

  /// Request approval for new orders (for non-admin users)
  Future<void> _requestOrderApproval(List<Map<String, dynamic>> orders) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId') ?? '';
    final userName = prefs.getString('username') ?? 'Unknown User';

    try {
      await _apiService.createApprovalRequest({
        'requesterId': userId,
        'requesterName': userName,
        'actionType': 'new_order',
        'resourceType': 'order',
        'resourceId': 'order_${DateTime.now().millisecondsSinceEpoch}',
        'resourceData': {
          'client': _selectedClient,
          'orderDate': _orderDateController.text,
          'billingFrom': _billingFrom,
          'itemCount': orders.length,
        },
        'proposedChanges': {'orders': orders},
        'reason': 'New order request for $_selectedClient',
      });

      // Show success dialog
      if (mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            contentPadding: const EdgeInsets.all(24),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 64),
                const SizedBox(height: 16),
                const Text('Request Submitted', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Your order request has been sent to admin for approval.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600])),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _resetForm();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E)),
                  child: const Text('OK'),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Shows a preview of the order card and allows sharing
  Future<void> _shareOrderToClient(List<Map<String, dynamic>> orders) async {
    if (orders.isEmpty) return;
    
    final GlobalKey repaintKey = GlobalKey();
    
    // Build the shareable card widget
    Widget buildOrderCard() {
      // Determine company name based on billingFrom
      final billingFrom = orders.first['billingFrom'] ?? 'SYGT';
      final isESPL = billingFrom.toString().toUpperCase() == 'ESPL';
      final companyName = isESPL ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';
      
      return RepaintBoundary(
        key: repaintKey,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Line 1: Company Logo + Name
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      isESPL ? 'assets/emperor_logo.jpg' : 'assets/yoga_logo.png',
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      companyName,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A5568)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Line 2: Client icon + Client Name + Date on right
              Row(
                children: [
                  const Icon(Icons.person, color: Color(0xFF64748B), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      orders.first['client'] ?? 'Client',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF4A5568)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.calendar_today, color: Color(0xFF64748B), size: 14),
                      const SizedBox(width: 4),
                      Text(
                        orders.first['orderDate'] ?? DateFormat('dd/MM/yy').format(DateTime.now()),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // Order items
              ...orders.map((order) => Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '${order['lot']}: ${order['grade']} - ${order['no']} ${order['bagbox']} - ${order['kgs']} kgs x ₹${order['price']}${(order['brand'] != null && order['brand'].toString().isNotEmpty) ? ' - ${order['brand']}' : ''}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF4A5568)),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF22C55E),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            order['billingFrom'] ?? 'SYGT',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    if (order['notes'] != null && order['notes'].toString().trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Text('≡ ', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                          Expanded(
                            child: Text(
                              order['notes'].toString(),
                              style: const TextStyle(color: Color(0xFF64748B), fontSize: 12, fontStyle: FontStyle.italic),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              )).toList(),
            ],
          ),
        ),
      );
    }
    
    // Fetch client contact first
    List<String> clientPhones = [];
    String? clientPhoneDisplay;
    final clientName = orders.first['client'] ?? 'Client';
    try {
      final contactResp = await _apiService.getClientContact(clientName);
      if (contactResp.data['success'] == true && contactResp.data['contact'] != null) {
        final contact = contactResp.data['contact'];
        if (contact['phones'] is List && (contact['phones'] as List).isNotEmpty) {
          clientPhones = (contact['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
        } else if (contact['phone'] != null && contact['phone'].toString().trim().isNotEmpty) {
          clientPhones = [contact['phone'].toString().trim()];
        }
        if (clientPhones.isNotEmpty) {
          clientPhoneDisplay = clientPhones.length == 1
              ? (contact['rawPhone']?.toString() ?? clientPhones.first)
              : '${clientPhones.length} numbers';
        }
      }
    } catch (e) {
      debugPrint('⚠️ Could not fetch client contact: $e');
    }

    // Always call direct share — admin notification numbers will be
    // merged inside, so messages go out even if client has no phone.
    // If client phone is available, it goes to client + admin numbers.
    // If client has no phone, it still sends to admin numbers only.
    await _captureAndShareDirect(orders, repaintKey, clientPhones);
    if (clientPhones.isNotEmpty) return;

    // Show preview dialog with share button (only if client had no phone)
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 650),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with client info
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFF4A5568),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.preview_rounded, color: Colors.white, size: 22),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Order Preview',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.close, color: Colors.white, size: 18),
                          ),
                        ),
                      ],
                    ),
                    // Show client phone status
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: clientPhones.isNotEmpty
                          ? const Color(0xFF25D366).withOpacity(0.2)
                          : Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            clientPhones.isNotEmpty ? Icons.phone : Icons.phone_disabled,
                            color: clientPhones.isNotEmpty ? const Color(0xFF25D366) : Colors.orange,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            clientPhones.isNotEmpty
                              ? 'Will send to: $clientPhoneDisplay'
                              : 'No phone found - will use share sheet',
                            style: TextStyle(
                              color: clientPhones.isNotEmpty ? Colors.white : Colors.orange[100],
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Preview card
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: buildOrderCard(),
                ),
              ),
              // Print + Share buttons
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    // Print button
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _captureAndPrintDirect(orders, repaintKey);
                        },
                        icon: const Icon(Icons.print_rounded, size: 20),
                        label: const Text('Print', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8B5CF6),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 4,
                          shadowColor: const Color(0xFF8B5CF6).withOpacity(0.4),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Share button
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _captureAndShareDirect(orders, repaintKey, clientPhones);
                        },
                        icon: const Icon(Icons.send_rounded, size: 20),
                        label: Text(
                          clientPhones.isNotEmpty ? 'Send' : 'Share',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF25D366),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 4,
                          shadowColor: const Color(0xFF25D366).withOpacity(0.4),
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

  /// Builds the shareable/printable order card widget
  Widget _buildShareCardWidget(List<Map<String, dynamic>> orders, String companyName, {required bool isESPL}) {
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
              colors: [Color(0xFFF8FAFC), Color(0xFFEFF6FF)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: const Border(left: BorderSide(color: Color(0xFF1E40AF), width: 5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFF1E40AF), Color(0xFF3B82F6)]),
                ),
                child: const Text(
                  'Green Cardamom - Order Confirmation',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(isESPL ? 'assets/emperor_logo.jpg' : 'assets/yoga_logo.png', width: 44, height: 44, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(companyName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
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
                            orders.first['client'] ?? 'Client',
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
                              orders.first['orderDate'] ?? DateFormat('dd/MM/yy').format(DateTime.now()),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ...orders.map((order) => Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: const Border(left: BorderSide(color: Color(0xFF3B82F6), width: 3)),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  '${order['lot']}: ${order['grade']} - ${order['no']} ${order['bagbox']} - ${order['kgs']} kgs x ₹${order['price']}${(order['brand'] != null && order['brand'].toString().isNotEmpty) ? ' - ${order['brand']}' : ''}',
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF334155)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(color: const Color(0xFF3B82F6), borderRadius: BorderRadius.circular(8)),
                                child: Text(order['billingFrom'] ?? 'SYGT', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                          if (order['notes'] != null && order['notes'].toString().trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Text('≡ ', style: TextStyle(color: Color(0xFF64748B), fontSize: 14)),
                                Expanded(
                                  child: Text(order['notes'].toString(), style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontStyle: FontStyle.italic)),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Captures the order card as an image and prints via AirPrint
  Future<void> _captureAndPrintDirect(List<Map<String, dynamic>> orders, GlobalKey repaintKey) async {
    if (!mounted) return;

    bool loadingShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    void closeLoading() {
      if (loadingShowing && mounted && Navigator.of(context).canPop()) {
        loadingShowing = false;
        Navigator.of(context).pop();
      }
    }

    try {
      final billingFrom = orders.first['billingFrom'] ?? 'SYGT';
      final isESPL = billingFrom.toString().toUpperCase() == 'ESPL';
      final companyName = isESPL ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';

      // Build same card widget as _captureAndShareDirect
      final cardWidget = _buildShareCardWidget(orders, companyName, isESPL: isESPL);

      final overlayState = Overlay.of(context);
      late OverlayEntry overlayEntry;
      final newKey = GlobalKey();

      overlayEntry = OverlayEntry(
        builder: (context) => Positioned(
          left: -1000,
          top: -1000,
          child: RepaintBoundary(
            key: newKey,
            child: cardWidget,
          ),
        ),
      );

      overlayState.insert(overlayEntry);
      await Future.delayed(const Duration(milliseconds: 300));

      final RenderRepaintBoundary boundary = newKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      final Uint8List pngBytes = byteData!.buffer.asUint8List();

      overlayEntry.remove();
      closeLoading();

      // Convert PNG to PDF and print
      final pdfDoc = pw.Document();
      final pdfImage = pw.MemoryImage(pngBytes);

      pdfDoc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(20),
          build: (pw.Context context) {
            return pw.Center(
              child: pw.Image(pdfImage, fit: pw.BoxFit.contain),
            );
          },
        ),
      );

      final pdfBytes = await pdfDoc.save();
      final clientName = orders.first['client'] ?? '';

      await Printing.layoutPdf(
        onLayout: (_) async => pdfBytes,
        name: 'Order_${clientName}_${DateTime.now().millisecondsSinceEpoch}',
      );

      // Soft reset — stay on page after printing
      if (mounted) _resetForm();
    } catch (e) {
      closeLoading();
      debugPrint('Error printing order: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error printing: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  /// Captures the order card as an image and shares it directly with the client
  Future<void> _captureAndShareDirect(List<Map<String, dynamic>> orders, GlobalKey repaintKey, List<String> clientPhones) async {
    if (!mounted) return;
    
    // Track if loading dialog is showing
    bool loadingShowing = true;
    
    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (loadingCtx) => const Center(child: CircularProgressIndicator()),
    );

    void closeLoading() {
      if (loadingShowing && mounted && Navigator.of(context).canPop()) {
        loadingShowing = false;
        Navigator.of(context).pop();
      }
    }

    try {
      // Determine company name based on billingFrom
      final billingFrom = orders.first['billingFrom'] ?? 'SYGT';
      final isESPL = billingFrom.toString().toUpperCase() == 'ESPL';
      final companyName = isESPL ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';
      
      final shareCardWidget = _buildShareCardWidget(orders, companyName, isESPL: isESPL);

      // Create an overlay entry to render the widget offscreen
      final overlayState = Overlay.of(context);
      late OverlayEntry overlayEntry;
      final newKey = GlobalKey();

      overlayEntry = OverlayEntry(
        builder: (context) => Positioned(
          left: -1000,
          top: -1000,
          child: RepaintBoundary(
            key: newKey,
            child: shareCardWidget,
          ),
        ),
      );
      
      overlayState.insert(overlayEntry);
      
      // Wait for the widget to be rendered
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Capture the image
      final RenderRepaintBoundary boundary = newKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      final Uint8List pngBytes = byteData!.buffer.asUint8List();
      
      // Remove the overlay
      overlayEntry.remove();
      
      // Save to temp file
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/order_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(pngBytes);
      
      // Close loading dialog
      closeLoading();
      
      final clientName = orders.first['client'] ?? '';

      // Try WhatsApp Cloud API first (sends directly, zero user interaction)
      bool sentViaApi = false;
      try {
        // Read phones from passed list, or fetch from contact
        List<String> phones = List<String>.from(clientPhones);
        if (phones.isEmpty) {
          final contactResp = await _apiService.getClientContact(clientName);
          final contact = contactResp.data['contact'];
          if (contact != null) {
            if (contact['phones'] is List && (contact['phones'] as List).isNotEmpty) {
              phones = (contact['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
            } else if (contact['phone'] != null && contact['phone'].toString().trim().isNotEmpty) {
              phones = [contact['phone'].toString().trim()];
            }
          }
        }

        // Merge admin notification numbers (owner + reference numbers)
        try {
          final notifResp = await _apiService.getNotificationNumbers();
          if (notifResp.data['success'] == true && notifResp.data['phones'] is List) {
            final adminPhones = (notifResp.data['phones'] as List)
                .map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
            for (final ap in adminPhones) {
              if (!phones.contains(ap)) phones.add(ap);
            }
          }
        } catch (_) {
          debugPrint('[WhatsApp] Could not fetch admin notification numbers');
        }

        if (phones.isNotEmpty) {
          final base64Image = base64Encode(pngBytes);
          final apiResp = await _apiService.sendWhatsAppImage(
            imageBase64: base64Image,
            phones: phones,
            caption: '*Green Cardamom - Order Confirmation* for *$clientName* from $companyName.',
            clientName: clientName,
            operationType: 'order_confirmation',
            companyName: companyName,
          );
          if (apiResp.data['success'] == true) {
            sentViaApi = true;
            final sentCount = apiResp.data['sentCount'] ?? phones.length;
            final totalCount = apiResp.data['totalCount'] ?? phones.length;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Sent to $sentCount of $totalCount number${totalCount > 1 ? 's' : ''} via WhatsApp!'),
                  backgroundColor: const Color(0xFF2E7D32),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          } else {
            debugPrint('[WhatsApp] API returned failure: ${apiResp.data}');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('WhatsApp send failed: ${apiResp.data['error'] ?? 'Unknown error'}'), backgroundColor: Colors.orange),
              );
            }
          }
        } else {
          debugPrint('[WhatsApp] No phone numbers found for $clientName');
        }
      } catch (apiErr) {
        debugPrint('[WhatsApp] API exception, falling back: $apiErr');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('WhatsApp error: $apiErr'), backgroundColor: Colors.orange, duration: const Duration(seconds: 4)),
          );
        }
      }

      // Fallback 1: Open WhatsApp chat directly with client's first number
      bool sentViaFallback = false;
      if (!sentViaApi && mounted && clientPhones.isNotEmpty) {
        final opened = await WhatsAppService.openChat(
          phone: clientPhones.first,
          message: 'Green cardamom - Order Confirmation for $clientName',
        );
        if (opened) {
          await WhatsAppService.shareImage(file.path);
          sentViaFallback = true;
        }
      }

      // Fallback 2: native WhatsApp share or generic share sheet
      if (!sentViaApi && !sentViaFallback && mounted) {
        final opened = await WhatsAppService.shareImage(file.path);
        if (!opened && mounted) {
          final box = context.findRenderObject() as RenderBox?;
          final sharePositionOrigin = box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : const Rect.fromLTWH(0, 0, 100, 100);

          await Share.shareXFiles(
            [XFile(file.path)],
            text: '*Green cardamom - Order Confirmation for $clientName*',
            sharePositionOrigin: sharePositionOrigin,
          );
        }
      }
    } catch (e) {
      // Close loading dialog
      closeLoading();
      debugPrint('Error sharing order: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sharing: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  void _resetForm() {
    setState(() {
      _orderDateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
      _billingFrom = 'SYGT';
      _selectedClient = null;
      _clientSearchController.clear();
      _suborderList.clear();
      _suborderControllers.clear();
      _nextLotBaseNumber = 0;
      _requestId = null;
      _isConversion = false;
      _isSubmitting = false;
      _addSuborder();
    });
  }


  @override
  Widget build(BuildContext context) {
    return AppShell(
      disableInternalScrolling: true,
      title: '➕ New Order',
      subtitle: 'Auto-generate lots and capture bag/box plans.',
      topActions: [
        _buildNavBtn(
          label: '📊 Dashboard',
          onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false),
          color: const Color(0xFF5D6E7E),
        ),
        const SizedBox(width: 12),
        _buildNavBtn(
          label: '📋 View Orders',
          onPressed: () => Navigator.pushNamed(context, '/view_orders'),
          color: const Color(0xFF22C55E),
        ),
      ],
      content: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      decoration: AppTheme.glassDecoration,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Center(
                            child: Text(
                              '➕ Enter Multiple Suborders',
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF4A5568), letterSpacing: -0.5),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildOrderDetails(),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('SUBORDERS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1.2)),
                              if (!_isConversion)
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.add, size: 16),
                                  label: const Text('Add Suborder', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                  onPressed: () => _addSuborder(),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF185A9D).withOpacity(0.1),
                                    foregroundColor: const Color(0xFF185A9D),
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF185A9D))),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ..._suborderList.asMap().entries.map((entry) => _buildSuborderBlock(entry.key, entry.value)),
                // Add Suborder button below last suborder for easy access
                if (!_isConversion && _suborderList.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Center(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Suborder', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        onPressed: () => _addSuborder(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF185A9D).withOpacity(0.1),
                          foregroundColor: const Color(0xFF185A9D),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF185A9D))),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 40),
                Center(
                  child: SizedBox(
                    width: 250,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: (_isLoading || _isSubmitting) ? null : _submitAll,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF185A9D),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        elevation: 8,
                        shadowColor: const Color(0xFF185A9D).withOpacity(0.5),
                      ),
                      child: (_isLoading || _isSubmitting)
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text('🚀 SUBMIT ALL ORDERS', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1, fontSize: 13)),
                    ),
                  ),
                ),
                const SizedBox(height: 60),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavBtn({required String label, required VoidCallback onPressed, required Color color}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withOpacity(0.15),
        foregroundColor: color,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: color.withOpacity(0.3))),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildOrderDetails() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isMobile) ...[
              _buildLabel('Order Date'),
              TextField(
                controller: _orderDateController,
                decoration: _inputDecoration().copyWith(hintText: 'YYYY-MM-DD', isDense: true),
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2030),
                  );
                  if (date != null) {
                    _orderDateController.text = DateFormat('yyyy-MM-dd').format(date);
                  }
                },
              ),
              const SizedBox(height: 12),
              _buildLabel('Billing From'),
              DropdownButtonFormField<String>(
                value: _billingFrom,
                decoration: _inputDecoration().copyWith(isDense: true),
                borderRadius: BorderRadius.circular(20),
                items: const [
                  DropdownMenuItem(value: 'SYGT', child: Text('SYGT')),
                  DropdownMenuItem(value: 'ESPL', child: Text('ESPL')),
                ],
                menuMaxHeight: 350,
                dropdownColor: AppTheme.bluishWhite,
                onChanged: (val) => setState(() => _billingFrom = val!),
              ),
            ] else 
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildLabel('Order Date'),
                        TextField(
                          controller: _orderDateController,
                          decoration: _inputDecoration().copyWith(hintText: 'YYYY-MM-DD'),
                          onTap: () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2030),
                            );
                            if (date != null) {
                              _orderDateController.text = DateFormat('yyyy-MM-dd').format(date);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildLabel('Billing From'),
                        DropdownButtonFormField<String>(
                          value: _billingFrom,
                          decoration: _inputDecoration(),
                          borderRadius: BorderRadius.circular(20),
                          items: const [
                            DropdownMenuItem(value: 'SYGT', child: Text('SYGT')),
                            DropdownMenuItem(value: 'ESPL', child: Text('ESPL')),
                          ],
                          menuMaxHeight: 350,
                          dropdownColor: AppTheme.bluishWhite,
                          onChanged: (val) => setState(() => _billingFrom = val!),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            _buildLabel('Client'),
            TextField(
              controller: _clientSearchController,
              enabled: !_isConversion,
              decoration: _inputDecoration().copyWith(
                hintText: 'Select or Search Client',
                suffixIcon: _selectedClient != null && _selectedClient!.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18, color: Color(0xFF94A3B8)),
                        onPressed: () {
                          setState(() {
                            _selectedClient = null;
                            _clientSearchController.clear();
                            _showClientResults = true;
                          });
                        },
                      )
                    : const Icon(Icons.arrow_drop_down, color: Color(0xFF64748B)),
              ),
              onTap: () => setState(() => _showClientResults = true),
              onChanged: (val) {
                setState(() {
                  _showClientResults = true;
                  if (val.isEmpty) _selectedClient = null;
                });
              },
            ),
            if (_showClientResults) _buildClientSearchResults(),
          ],
        );
      },
    );
  }

  Widget _buildClientSearchResults() {
    final query = _clientSearchController.text.trim();
    final clients = (_dropdowns['client'] as List<dynamic>?)
        ?.map((c) => c.toString())
        .toList() ?? [];

    List<String> filtered;
    if (query.isEmpty) {
      filtered = clients;
    } else {
      filtered = clients.where((c) =>
          c.toLowerCase().contains(query.toLowerCase())).toList();
    }

    final hasExactMatch = clients.any((c) => c.toLowerCase() == query.toLowerCase());

    return Container(
      margin: const EdgeInsets.only(top: 4),
      constraints: const BoxConstraints(maxHeight: 250),
      decoration: BoxDecoration(
        color: AppTheme.bluishWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      child: ListView(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        children: [
          ...filtered.take(20).map((client) => ListTile(
            title: Text(client, style: const TextStyle(fontSize: 14)),
            dense: true,
            onTap: () {
              setState(() {
                _selectedClient = client;
                _clientSearchController.text = client;
                _showClientResults = false;
              });
              if (client.isNotEmpty) _fetchNextLotNumber(client);
            },
          )),
          if (query.isNotEmpty && !hasExactMatch)
            ListTile(
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: AppTheme.success,
                child: const Icon(Icons.person_add, color: Colors.white, size: 16),
              ),
              title: Text('Add "$query" as new client',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              subtitle: const Text('Tap to create', style: TextStyle(fontSize: 12)),
              dense: true,
              onTap: () {
                setState(() => _showClientResults = false);
                _showAddNewClientDialog(query);
              },
            ),
          if (filtered.isEmpty && query.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Loading clients...', style: TextStyle(color: Color(0xFF94A3B8))),
            ),
        ],
      ),
    );
  }

  /// Shows a dialog to collect phone numbers and address for a new client.
  /// Returns {'skipped': true} if skipped, {'phones': [...], 'address': '...'} if saved,
  /// or null if dismissed.
  Future<Map<String, dynamic>?> _showNewClientContactDialog(String clientName) async {
    final phoneEntries = <_NewOrderPhoneEntry>[_NewOrderPhoneEntry()];
    final addressController = TextEditingController();

    Future<bool> verifyPhone(int idx, StateSetter setDialogState) async {
      if (idx < 0 || idx >= phoneEntries.length) return true;
      final entry = phoneEntries[idx];
      final phone = entry.controller.text.trim().replaceAll(RegExp(r'\D'), '');
      if (phone.isEmpty) {
        setDialogState(() { entry.error = null; entry.verified = null; });
        return true;
      }
      if (phone.length < 4) {
        setDialogState(() { entry.error = 'Number too short'; entry.verified = false; });
        return false;
      }
      if (entry.code == '91') {
        if (phone.length != 10) {
          setDialogState(() { entry.error = 'Enter a valid 10-digit number'; entry.verified = false; });
          return false;
        }
        if (!RegExp(r'^[6-9]\d{9}$').hasMatch(phone)) {
          setDialogState(() { entry.error = 'Must start with 6, 7, 8, or 9'; entry.verified = false; });
          return false;
        }
      }
      setDialogState(() { entry.verifying = true; entry.error = null; });
      try {
        final fullNumber = '${entry.code}$phone';
        final resp = await _apiService.verifyWhatsAppNumber(fullNumber);
        if (resp.data['success'] == true) {
          final valid = resp.data['valid'] == true;
          if (mounted) {
            setDialogState(() {
              entry.verifying = false;
              entry.verified = valid;
              entry.error = valid ? null : 'Not active on WhatsApp';
            });
          }
          return valid;
        }
      } catch (_) {}
      if (mounted) {
        setDialogState(() { entry.verifying = false; entry.verified = true; });
      }
      return true;
    }

    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Contact Details', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 4),
              Text(clientName, style: const TextStyle(fontSize: 14, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              const Text('Optional — you can skip and add later', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Phone section header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('📱 Phone Numbers', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    TextButton.icon(
                      onPressed: () {
                        setDialogState(() {
                          phoneEntries.add(_NewOrderPhoneEntry());
                        });
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF22C55E),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Phone entries
                for (int i = 0; i < phoneEntries.length; i++)
                  Padding(
                    key: ValueKey(phoneEntries[i].key),
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Country code dropdown
                        Container(
                          height: 48,
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.only(left: 4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: phoneEntries[i].code,
                              isDense: true,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87),
                              items: _countryCodes.map((c) => DropdownMenuItem<String>(
                                value: c['code'],
                                child: Text('${c['flag']} +${c['code']}', style: const TextStyle(fontSize: 13)),
                              )).toList(),
                              onChanged: (val) {
                                if (val == null) return;
                                setDialogState(() {
                                  phoneEntries[i].code = val;
                                  phoneEntries[i].verified = null;
                                  phoneEntries[i].error = null;
                                });
                              },
                            ),
                          ),
                        ),
                        // Phone number input
                        Expanded(
                          child: TextField(
                            controller: phoneEntries[i].controller,
                            keyboardType: TextInputType.phone,
                            onChanged: (_) {
                              if (phoneEntries[i].verified != null || phoneEntries[i].error != null) {
                                setDialogState(() { phoneEntries[i].verified = null; phoneEntries[i].error = null; });
                              }
                            },
                            decoration: InputDecoration(
                              labelText: phoneEntries.length > 1 ? 'Phone ${i + 1}' : 'WhatsApp Number',
                              hintText: phoneEntries[i].code == '91' ? 'e.g. 9876543210' : 'Phone number',
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                              errorBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: Colors.red, width: 1.5),
                              ),
                              errorText: phoneEntries[i].error,
                              errorStyle: const TextStyle(fontSize: 11),
                              suffixIcon: phoneEntries[i].verifying
                                  ? const Padding(
                                      padding: EdgeInsets.all(10),
                                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                                    )
                                  : phoneEntries[i].verified == true
                                      ? const Icon(Icons.verified, color: Color(0xFF22C55E), size: 20)
                                      : phoneEntries[i].verified == false
                                          ? const Icon(Icons.error_outline, color: Colors.red, size: 20)
                                          : phoneEntries[i].controller.text.trim().isNotEmpty
                                              ? IconButton(
                                                  icon: const Icon(Icons.check_circle_outline, color: Colors.orange, size: 20),
                                                  tooltip: 'Verify WhatsApp',
                                                  onPressed: () => verifyPhone(i, setDialogState),
                                                )
                                              : null,
                            ),
                          ),
                        ),
                        // Remove button
                        if (phoneEntries.length > 1)
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                            tooltip: 'Remove',
                            onPressed: () {
                              setDialogState(() {
                                phoneEntries[i].controller.dispose();
                                phoneEntries.removeAt(i);
                              });
                            },
                            padding: const EdgeInsets.only(top: 8),
                            constraints: const BoxConstraints(),
                          ),
                      ],
                    ),
                  ),

                const SizedBox(height: 12),
                // Address section
                const Text('📍 Address', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 8),
                TextField(
                  controller: addressController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: 'Enter address (optional)',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, {'skipped': true}),
              child: const Text('Skip'),
            ),
            ElevatedButton(
              onPressed: () {
                // Validate phones before saving
                for (final entry in phoneEntries) {
                  final p = entry.controller.text.trim().replaceAll(RegExp(r'\D'), '');
                  if (p.isNotEmpty && entry.code == '91' && p.length != 10) {
                    setDialogState(() { entry.error = 'Enter a valid 10-digit number'; entry.verified = false; });
                    return;
                  }
                  if (p.isNotEmpty && entry.code == '91' && !RegExp(r'^[6-9]').hasMatch(p)) {
                    setDialogState(() { entry.error = 'Must start with 6, 7, 8, or 9'; entry.verified = false; });
                    return;
                  }
                  if (p.isNotEmpty && p.length < 4) {
                    setDialogState(() { entry.error = 'Number too short'; entry.verified = false; });
                    return;
                  }
                }
                // Collect phones
                final phones = <String>[];
                for (final entry in phoneEntries) {
                  final p = entry.controller.text.trim().replaceAll(RegExp(r'\D'), '');
                  if (p.isNotEmpty) {
                    final full = '${entry.code}$p';
                    if (!phones.contains(full)) phones.add(full);
                  }
                }
                final address = addressController.text.trim();
                Navigator.pop(ctx, {
                  'phones': phones,
                  'address': address,
                });
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
              child: const Text('Save & Continue', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
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
                    backgroundColor: AppTheme.titaniumMid,
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
                      _clientSearchController.text = clientName;
                      _showClientResults = false;
                    });
                    if (clientName.isNotEmpty) _fetchNextLotNumber(clientName);
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
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
              child: const Text('Add Anyway', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ) ?? false;
    }

    if (!shouldAdd || !mounted) return;

    // Show contact details dialog before adding client
    final contactResult = await _showNewClientContactDialog(trimmedName);
    if (contactResult == null || !mounted) return; // Dismissed → abort

    try {
      final response = similarClients.isNotEmpty
          ? await _apiService.forceAddDropdownItem('clients', trimmedName)
          : await _apiService.addDropdownItem('clients', trimmedName);
      if (response.data['success'] == true) {
        // Save contact info if provided (not skipped)
        if (contactResult['skipped'] != true) {
          final phones = (contactResult['phones'] as List<String>?) ?? [];
          final address = (contactResult['address'] as String?) ?? '';
          if (phones.isNotEmpty || address.isNotEmpty) {
            try {
              await _apiService.updateClientContact(
                trimmedName,
                phones: phones.isNotEmpty ? phones : null,
                address: address.isNotEmpty ? address : null,
              );
              debugPrint('[NewClient] Contact saved: phones=$phones, address=$address');
            } catch (e) {
              debugPrint('[NewClient] Error saving contact: $e');
            }
          }
        }

        await _loadDropdowns();
        if (!mounted) return;
        setState(() {
          _selectedClient = trimmedName;
          _clientSearchController.text = trimmedName;
          _showClientResults = false;
        });
        _fetchNextLotNumber(trimmedName);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text('Client "$trimmedName" added successfully!')),
            ]),
            backgroundColor: AppTheme.success,
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
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(response.data['message']?.toString() ?? 'Failed to add client'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error adding client: $e'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }


  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFF4A5568))),
    );
  }

  InputDecoration _inputDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: Colors.white.withOpacity(0.8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.accent, width: 2)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.danger, width: 1)),
    );
  }

  Widget _buildSuborderBlock(int index, Map<String, dynamic> suborder) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final isNarrow = constraints.maxWidth < 400;
        return Container(
          margin: const EdgeInsets.only(top: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, 10))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 10 : 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC).withOpacity(0.8),
                  borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_isConversion)
                          Checkbox(
                            value: suborder['isSelected'] ?? true,
                            activeColor: AppTheme.primary,
                            onChanged: (val) => setState(() => suborder['isSelected'] = val),
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: (suborder['isSelected'] == false) ? Colors.grey : const Color(0xFF4A5568), borderRadius: BorderRadius.circular(8)),
                          child: Text('SUBORDER #${index + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10, letterSpacing: 1)),
                        ),
                        const Spacer(),
                        if (!_isConversion)
                          InkWell(
                            onTap: () => _removeSuborder(index),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(color: const Color(0xFFEF4444).withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                              child: const Icon(Icons.close, color: Color(0xFFEF4444), size: 16),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: isNarrow ? 2 : 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Lot'),
                              TextField(
                                controller: _suborderControllers[index]?['lot'],
                                decoration: _inputDecoration().copyWith(hintText: 'Auto', fillColor: const Color(0xFFF1F5F9), isDense: isMobile),
                                readOnly: true,
                                style: TextStyle(color: const Color(0xFF64748B), fontWeight: FontWeight.bold, fontSize: isMobile ? 12 : 13),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: isNarrow ? 3 : 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Grade'),
                              SearchableGradeDropdown(
                                grades: ((_dropdowns['grade'] as List<dynamic>?) ?? []).map((g) => g.toString()).toList(),
                                value: suborder['grade'].isEmpty ? null : suborder['grade'],
                                showAllOption: false,
                                hintText: 'Search grade...',
                                onChanged: _isConversion ? (val) {} : (val) => setState(() => suborder['grade'] = val ?? ''),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!isMobile)
                      Row(
                        children: [
                          Expanded(flex: 2, child: _buildBagBoxField(index, suborder, isMobile: isMobile)),
                          const SizedBox(width: 12),
                          Expanded(flex: 1, child: _buildQtyField(index, suborder, isMobile: isMobile)),
                          const SizedBox(width: 12),
                          Expanded(flex: 1, child: _buildKgsField(index, suborder, isMobile: isMobile)),
                          const SizedBox(width: 12),
                          Expanded(flex: 1, child: _buildPriceField(index, suborder, isMobile: isMobile)),
                        ],
                      )
                    else 
                      Column(
                        children: [
                          _buildBagBoxField(index, suborder, isMobile: isMobile),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(child: _buildQtyField(index, suborder, isMobile: isMobile)),
                              const SizedBox(width: 8),
                              Expanded(child: _buildKgsField(index, suborder, isMobile: isMobile)),
                              const SizedBox(width: 8),
                              Expanded(child: _buildPriceField(index, suborder, isMobile: isMobile)),
                            ],
                          ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    if (isMobile)
                      Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           _buildLabel('Brand'),
                            DropdownButtonFormField<String>(
                              value: suborder['brand'].isEmpty ? null : suborder['brand'],
                              decoration: _inputDecoration().copyWith(isDense: isMobile),
                              borderRadius: BorderRadius.circular(20),
                              items: (_dropdowns['brand'] as List<dynamic>?)
                                  ?.map((b) => DropdownMenuItem(value: b.toString(), child: Text(b.toString(), style: TextStyle(fontSize: isMobile ? 12 : 13))))
                                  .toList(),
                              menuMaxHeight: 300,
                              dropdownColor: AppTheme.bluishWhite,
                              onChanged: _isConversion ? null : (val) => setState(() => suborder['brand'] = val!),
                            ),
                            const SizedBox(height: 12),
                            _buildLabel('Notes'),
                            TextField(
                              controller: _suborderControllers[index]?['notes'],
                              decoration: _inputDecoration().copyWith(hintText: 'Local Pouch Name / Extra pouch / White Bag Info', isDense: isMobile),
                              style: TextStyle(fontSize: isMobile ? 12 : 13),
                              keyboardType: TextInputType.multiline,
                              maxLines: null,
                              minLines: 1,
                              textInputAction: TextInputAction.newline,
                              onChanged: (val) => suborder['notes'] = val,
                            ),
                         ],
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildLabel('Brand'),
                                DropdownButtonFormField<String>(
                                  value: suborder['brand'].isEmpty ? null : suborder['brand'],
                                  decoration: _inputDecoration(),
                                  borderRadius: BorderRadius.circular(20),
                                  items: (_dropdowns['brand'] as List<dynamic>?)
                                      ?.map((b) => DropdownMenuItem(value: b.toString(), child: Text(b.toString(), style: const TextStyle(fontSize: 13))))
                                      .toList(),
                                  menuMaxHeight: 350,
                                  dropdownColor: AppTheme.bluishWhite,
                                  onChanged: _isConversion ? null : (val) => setState(() => suborder['brand'] = val!),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildLabel('Notes'),
                                TextField(
                                  controller: _suborderControllers[index]?['notes'],
                                  decoration: _inputDecoration().copyWith(hintText: 'Optional notes...'),
                                  style: const TextStyle(fontSize: 13),
                                  keyboardType: TextInputType.multiline,
                                  maxLines: null,
                                  minLines: 1,
                                  textInputAction: TextInputAction.newline,
                                  onChanged: (val) => suborder['notes'] = val,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    );
  }

  Widget _buildBagBoxField(int index, Map<String, dynamic> suborder, {bool isMobile = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Bag / Box'),
        DropdownButtonFormField<String>(
          value: suborder['bagbox'],
          decoration: _inputDecoration().copyWith(isDense: isMobile),
          borderRadius: BorderRadius.circular(20),
          items: (_dropdowns['bagbox'] as List<dynamic>?)
              ?.map((b) => DropdownMenuItem(value: b.toString(), child: Text(b.toString(), style: TextStyle(fontSize: isMobile ? 12 : 13))))
              .toList() ?? [],
          menuMaxHeight: 300,
          dropdownColor: AppTheme.bluishWhite,
          onChanged: _isConversion ? null : (val) => setState(() {
            suborder['bagbox'] = val!;
            final normalized = val.toLowerCase();
            final multiplier = normalized.contains('bag') ? 50 : (normalized.contains('box') ? 20 : null);
            final count = double.tryParse(_suborderControllers[index]?['no']?.text ?? '0') ?? 0;
            if (multiplier != null && count > 0) {
              final kgs = (count * multiplier).toStringAsFixed(2).replaceFirst(RegExp(r'\.00$'), '');
              suborder['kgs'] = kgs;
              _suborderControllers[index]?['kgs']?.text = kgs;
            }
          }),
        ),
      ],
    );
  }

  Widget _buildQtyField(int index, Map<String, dynamic> suborder, {bool isMobile = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Qty'),
        TextField(
          controller: _suborderControllers[index]?['no'],
          decoration: _inputDecoration().copyWith(isDense: isMobile),
          keyboardType: TextInputType.number,
          readOnly: _isConversion,
          style: TextStyle(fontSize: isMobile ? 12 : 13),
          onChanged: (val) => setState(() {
            suborder['no'] = val;
            final normalized = (suborder['bagbox'] ?? '').toLowerCase();
            final multiplier = normalized.contains('bag') ? 50 : (normalized.contains('box') ? 20 : null);
            final count = double.tryParse(val) ?? 0;
            if (multiplier != null && count > 0) {
              final kgs = (count * multiplier).toStringAsFixed(2).replaceFirst(RegExp(r'\.00$'), '');
              suborder['kgs'] = kgs;
              _suborderControllers[index]?['kgs']?.text = kgs;
            }
          }),
        ),
      ],
    );
  }

  Widget _buildKgsField(int index, Map<String, dynamic> suborder, {bool isMobile = false}) {
    final normalized = (suborder['bagbox'] ?? '').toLowerCase();
    final multiplier = normalized.contains('bag') ? 50 : (normalized.contains('box') ? 20 : null);
    final isReadOnly = multiplier != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Kgs'),
        TextField(
          controller: _suborderControllers[index]?['kgs'],
          decoration: _inputDecoration().copyWith(fillColor: isReadOnly ? const Color(0xFFF1F5F9) : null, isDense: isMobile),
          keyboardType: TextInputType.number,
          readOnly: isReadOnly || _isConversion,
          style: TextStyle(fontSize: isMobile ? 12 : 13, color: isReadOnly ? const Color(0xFF64748B) : null),
          onChanged: (val) => setState(() {
            suborder['kgs'] = val;
          }),
        ),
      ],
    );
  }

  Widget _buildPriceField(int index, Map<String, dynamic> suborder, {bool isMobile = false}) {
    final grade = suborder['grade'];
    final suggestion = _suggestedPrices.where((s) => s.grade == grade).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildLabel('Price'),
            if (suggestion != null)
              const Icon(Icons.auto_awesome, size: 12, color: Color(0xFF5D6E7E)),
          ],
        ),
        TextField(
          controller: _suborderControllers[index]?['price'],
          decoration: _inputDecoration().copyWith(isDense: isMobile),
          keyboardType: TextInputType.number,
          readOnly: _isConversion,
          style: TextStyle(fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.bold, color: const Color(0xFF4A5568)),
          onChanged: (val) => suborder['price'] = val,
        ),
        if (suggestion != null) ...[
          const SizedBox(height: 8),
          SuggestedPriceCard(
            suggestion: suggestion,
            onApply: () {
              _suborderControllers[index]?['price']?.text = suggestion.suggestedPrice.toString();
              setState(() {
                suborder['price'] = suggestion.suggestedPrice.toString();
              });
            },
          ),
        ],
      ],
    );
  }
}

/// Phone entry state for new client contact dialog
class _NewOrderPhoneEntry {
  final int key;
  final TextEditingController controller;
  String code;
  bool? verified;
  String? error;
  bool verifying;

  static int _nextKey = 0;

  _NewOrderPhoneEntry({
    TextEditingController? controller,
    this.code = '91',
    this.verified,
    this.error,
    this.verifying = false,
  })  : key = _nextKey++,
        controller = controller ?? TextEditingController();
}
