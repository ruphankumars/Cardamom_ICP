import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/cache_manager.dart';
import '../services/operation_queue.dart';
import '../mixins/optimistic_action_mixin.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/grade_grouped_dropdown.dart';

class ClientLedgerDetailScreen extends StatefulWidget {
  final String clientName;

  const ClientLedgerDetailScreen({super.key, required this.clientName});

  @override
  State<ClientLedgerDetailScreen> createState() => _ClientLedgerDetailScreenState();
}

class _ClientLedgerDetailScreenState extends State<ClientLedgerDetailScreen> with OptimisticActionMixin {
  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();

  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  Map<String, dynamic> _ordersData = {};
  Map<String, dynamic> _dropdownOptions = {'grade': [], 'bagbox': [], 'brand': []};
  String _statusFilter = 'All';
  String _gradeFilter = '';
  String _userRole = 'user';

  // Share selection mode state
  bool _isShareMode = false;
  final Set<String> _selectedOrderIds = {};

  // Add to Cart mode state
  bool _isAddToCartMode = false;
  final Set<String> _cartSelectedIds = {};
  final Map<String, Map<String, dynamic>> _cartOrderData = {};

  // Dispatch document linkage
  Map<String, String> _orderDispatchDocMap = {};

  bool _canEditOrders = false;
  bool _canDeleteOrders = false;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';
      final prefs = await SharedPreferences.getInstance();
      final pageAccessJson = prefs.getString('pageAccess');
      if (pageAccessJson != null) {
        try {
          final pa = jsonDecode(pageAccessJson) as Map<String, dynamic>;
          _canEditOrders = pa['edit_orders'] != false;
          _canDeleteOrders = pa['delete_orders'] != false;
        } catch (_) {
          _canEditOrders = true;
          _canDeleteOrders = true;
        }
      } else {
        _canEditOrders = true;
        _canDeleteOrders = true;
      }
      await Future.wait([
        _loadOrders(showLoading: false),
        _loadDropdowns(),
      ]);
      setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('Error loading initial data: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadOrders({bool showLoading = true}) async {
    if (showLoading) setState(() => _isLoading = true);
    try {
      final response = await _apiService.getFilteredOrders(
        status: _statusFilter,
        client: widget.clientName,
        grade: _gradeFilter,
      );
      if (!mounted) return;
      setState(() {
        var rawData = response.data;
        if (rawData is Map && rawData.containsKey('orders')) {
          final ordersMap = rawData['orders'];
          _ordersData = ordersMap is Map ? Map<String, dynamic>.from(ordersMap) : {};
        } else if (rawData is Map) {
          _ordersData = Map<String, dynamic>.from(rawData);
        } else {
          _ordersData = {};
        }
        if (showLoading) _isLoading = false;
      });
      _loadDispatchDocMap();
    } catch (e) {
      debugPrint('Error loading orders: $e');
      if (!mounted) return;
      if (showLoading) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadDispatchDocMap() async {
    if (_statusFilter.toLowerCase() != 'billed' && _statusFilter.toLowerCase() != 'all') return;
    try {
      final docIds = <String>[];
      _ordersData.forEach((date, clients) {
        if (clients is Map) {
          clients.forEach((client, rows) {
            if (rows is List) {
              for (final row in rows) {
                if (row is List && row.isNotEmpty) {
                  final rawId = row[row.length - 1].toString();
                  final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;
                  if (docId.isNotEmpty) docIds.add(docId);
                }
              }
            }
          });
        }
      });
      if (docIds.isEmpty) return;
      final resp = await _apiService.getDocumentsForOrders(docIds);
      if (resp.data['orderDocumentMap'] != null && mounted) {
        setState(() {
          _orderDispatchDocMap = Map<String, String>.from(resp.data['orderDocumentMap']);
        });
      }
    } catch (e) {
      debugPrint('Error loading dispatch doc map: $e');
    }
  }

  Future<void> _loadDropdowns() async {
    try {
      final cacheManager = context.read<CacheManager>();
      final result = await cacheManager.fetchWithCache<Map<String, dynamic>>(
        apiCall: () async {
          final response = await _apiService.getDropdownOptions();
          return Map<String, dynamic>.from(response.data);
        },
        cache: cacheManager.dropdownCache,
      );
      setState(() => _dropdownOptions = result.data);
    } catch (e) {
      debugPrint('Error loading dropdowns: $e');
    }
  }

  bool get _isAdmin => _userRole.toLowerCase() == 'superadmin' || _userRole.toLowerCase() == 'admin' || _userRole.toLowerCase() == 'ops';
  bool get _isSuperAdmin => _userRole.toLowerCase() == 'superadmin';

  // ===== DELETE =====
  Future<void> _deleteOrder(String docId, {List<dynamic>? orderRow}) async {
    if (!_isAdmin || !_canDeleteOrders) {
      await _requestApproval(actionType: 'delete', resourceType: 'order', resourceId: docId, resourceData: orderRow != null ? _rowToMap(orderRow) : {'docId': docId});
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete Order?'),
        content: const Text('Are you sure? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    Map<String, dynamic>? removedFrom;
    String? removedDate;
    String? removedClient;
    int removedIndex = -1;

    outer:
    for (final dateEntry in _ordersData.entries) {
      if (dateEntry.value is Map) {
        for (final clientEntry in (dateEntry.value as Map).entries) {
          if (clientEntry.value is List) {
            final rows = clientEntry.value as List;
            for (int i = 0; i < rows.length; i++) {
              if (rows[i] is List) {
                final rawId = rows[i][rows[i].length - 1].toString();
                final id = rawId.startsWith('-') ? rawId.substring(1) : rawId;
                if (id == docId) {
                  removedFrom = {'row': List.from(rows[i])};
                  removedDate = dateEntry.key;
                  removedClient = clientEntry.key.toString();
                  removedIndex = i;
                  break outer;
                }
              }
            }
          }
        }
      }
    }

    optimistic(
      type: 'delete',
      applyLocal: () {
        if (removedDate != null && removedClient != null && removedIndex >= 0) {
          setState(() {
            final clients = _ordersData[removedDate];
            if (clients is Map) {
              final rows = clients[removedClient];
              if (rows is List && removedIndex < rows.length) {
                rows.removeAt(removedIndex);
                if (rows.isEmpty) clients.remove(removedClient);
                if (clients.isEmpty) _ordersData.remove(removedDate);
              }
            }
          });
        }
      },
      apiCall: () async {
        await _apiService.deleteOrder(docId);
        _loadOrders(showLoading: false);
      },
      rollback: () {
        if (removedFrom != null && removedDate != null && removedClient != null && removedIndex >= 0) {
          setState(() {
            _ordersData.putIfAbsent(removedDate!, () => <String, dynamic>{});
            final clients = _ordersData[removedDate] as Map;
            clients.putIfAbsent(removedClient!, () => <dynamic>[]);
            final rows = clients[removedClient] as List;
            rows.insert(removedIndex.clamp(0, rows.length), removedFrom!['row']);
          });
        }
      },
      successMessage: 'Order deleted',
      failureMessage: 'Failed to delete order. Restored.',
    );
  }

  Map<String, dynamic> _rowToMap(List<dynamic> row) => {
    'orderDate': row[0] ?? '', 'billingFrom': row[1] ?? '', 'client': row[2] ?? '',
    'lot': row[3] ?? '', 'grade': row[4] ?? '', 'bagbox': row[5] ?? '',
    'no': row[6] ?? 0, 'kgs': row[7] ?? 0, 'price': row[8] ?? 0,
    'brand': row[9] ?? '', 'status': row[10] ?? '',
    'notes': row.length > 11 ? row[11] ?? '' : '',
  };

  Future<void> _requestApproval({required String actionType, required String resourceType, required dynamic resourceId, Map<String, dynamic>? resourceData, Map<String, dynamic>? proposedChanges}) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId') ?? '';
    final userName = prefs.getString('username') ?? 'Unknown User';
    final reason = await showDialog<String>(
      context: context,
      builder: (c) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(actionType == 'delete' ? 'Request Delete Approval' : 'Request Edit Approval'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('This action requires Super Admin approval.', style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 16),
            TextField(controller: controller, decoration: InputDecoration(labelText: 'Reason (optional)', hintText: 'Why do you need this change?', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))), maxLines: 2),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, null), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(c, controller.text), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E)), child: const Text('Submit Request')),
          ],
        );
      },
    );
    if (reason == null) return;
    fireAndForget(
      type: 'send',
      apiCall: () => _apiService.createApprovalRequest({'requesterId': userId, 'requesterName': userName, 'actionType': actionType, 'resourceType': resourceType, 'resourceId': resourceId, 'resourceData': resourceData, 'proposedChanges': proposedChanges, 'reason': reason}),
      successMessage: 'Approval request submitted',
      failureMessage: 'Failed to submit request',
    );
  }

  // ===== DISPATCH =====
  Future<void> _dispatchOrder(List<dynamic> row, String orderDocId) async {
    final orderData = _rowToMap(row);
    orderData['index'] = orderDocId;
    showDialog(context: context, barrierDismissible: false, builder: (_) => AlertDialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), contentPadding: const EdgeInsets.all(32), content: const Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(color: Color(0xFF10B981)), SizedBox(height: 20), Text('Adding to Cart...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))])));
    try {
      await _apiService.addToCart([orderData]);
      await _loadOrders(showLoading: false);
      if (mounted) Navigator.pop(context);
      HapticFeedback.heavyImpact();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Row(children: [const Icon(Icons.check_circle, color: Colors.white, size: 20), const SizedBox(width: 12), Text('${orderData['lot']} - ${orderData['grade']} dispatched!')]), backgroundColor: const Color(0xFF10B981), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), duration: const Duration(seconds: 2)));
    } catch (e) {
      if (mounted) Navigator.pop(context);
      HapticFeedback.vibrate();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error dispatching: $e'), backgroundColor: Colors.red));
    }
  }

  // ===== PARTIAL DISPATCH =====
  void _showPartialDispatchModal(List<dynamic> row, String orderId) {
    final totalKgs = (num.tryParse(row[7].toString()) ?? 0).toDouble();
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.all(24),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [Icon(Icons.content_cut, color: Color(0xFFF59E0B), size: 22), SizedBox(width: 8), Text('Partial Dispatch', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))]),
          const SizedBox(height: 12),
          Text('${row[3]}: ${row[4]} - ${row[7]} kgs', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
          const SizedBox(height: 4),
          Text('Enter quantity to dispatch (Total: $totalKgs kg)', style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
          const SizedBox(height: 16),
          TextField(controller: controller, decoration: InputDecoration(labelText: 'Enter Kgs', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)), keyboardType: const TextInputType.numberWithOptions(decimal: true), autofocus: true, style: const TextStyle(fontSize: 14)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final qty = double.tryParse(controller.text) ?? 0;
              if (qty <= 0 || qty >= totalKgs) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid quantity')));
                return;
              }
              Navigator.pop(ctx);
              showDialog(context: context, barrierDismissible: false, builder: (_) => AlertDialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), contentPadding: const EdgeInsets.all(32), content: const Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(strokeWidth: 3, valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF5D6E7E))), SizedBox(height: 20), Text('Dispatching...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))])));
              try {
                final rawId = row[row.length - 1].toString();
                final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;
                final orderObj = _rowToMap(row);
                orderObj['index'] = docId;
                await _apiService.partialDispatch(orderObj, qty);
                if (mounted) Navigator.pop(context);
                HapticFeedback.heavyImpact();
                await _loadOrders(showLoading: false);
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${row[3]} - ${row[4]}: ${qty}kg dispatched!'), backgroundColor: const Color(0xFFF59E0B), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
              } catch (e) {
                if (mounted) Navigator.pop(context);
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
            child: const Text('Dispatch'),
          ),
        ],
      ),
    );
  }

  // ===== CART SUBMIT =====
  Future<void> _submitCartOrders() async {
    if (_cartSelectedIds.isEmpty) return;
    final selectedOrders = _cartSelectedIds.where((id) => _cartOrderData.containsKey(id)).map((id) => _cartOrderData[id]!).toList();
    if (selectedOrders.isEmpty) return;
    _showCartDatePicker(selectedOrders);
  }

  void _showCartDatePicker(List<Map<String, dynamic>> selectedOrders) {
    DateTime? selectedDate;
    bool isTodaySelected = true;
    final today = DateTime.now();
    final todayStr = '${today.day.toString().padLeft(2, '0')}/${today.month.toString().padLeft(2, '0')}/${today.year.toString().substring(2)}';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final displayDate = selectedDate != null ? '${selectedDate!.day.toString().padLeft(2, '0')}/${selectedDate!.month.toString().padLeft(2, '0')}/${selectedDate!.year.toString().substring(2)}' : todayStr;
          final isOldDate = selectedDate != null && selectedDate!.isBefore(DateTime(today.year, today.month, today.day));
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            insetPadding: const EdgeInsets.symmetric(horizontal: 32),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.calendar_month, color: Color(0xFF10B981), size: 22),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Select Cart Date', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1E293B)))),
                  GestureDetector(onTap: () => Navigator.pop(ctx), child: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 20)),
                ]),
                const SizedBox(height: 6),
                Text('${selectedOrders.length} order(s) selected', style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500)),
                const SizedBox(height: 16),
                // Today option
                GestureDetector(
                  onTap: () => setDialogState(() { isTodaySelected = true; selectedDate = null; }),
                  child: Container(width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: isTodaySelected ? const Color(0xFF10B981).withOpacity(0.08) : const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(12), border: Border.all(color: isTodaySelected ? const Color(0xFF10B981) : const Color(0xFFE2E8F0), width: isTodaySelected ? 2 : 1)),
                    child: Row(children: [Icon(isTodaySelected ? Icons.radio_button_checked : Icons.radio_button_off, color: isTodaySelected ? const Color(0xFF10B981) : const Color(0xFF94A3B8), size: 20), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Today', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))), Text(todayStr, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)))])), Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: const Color(0xFF8B5CF6).withOpacity(0.1), borderRadius: BorderRadius.circular(6)), child: const Text('On Progress', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF8B5CF6))))]),
                  ),
                ),
                const SizedBox(height: 10),
                // Old date option
                GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(context: ctx, initialDate: selectedDate ?? today.subtract(const Duration(days: 1)), firstDate: DateTime(2020), lastDate: today);
                    if (picked != null) setDialogState(() { selectedDate = picked; isTodaySelected = (picked.year == today.year && picked.month == today.month && picked.day == today.day); });
                  },
                  child: Container(width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: !isTodaySelected ? const Color(0xFF3B82F6).withOpacity(0.08) : const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(12), border: Border.all(color: !isTodaySelected ? const Color(0xFF3B82F6) : const Color(0xFFE2E8F0), width: !isTodaySelected ? 2 : 1)),
                    child: Row(children: [Icon(!isTodaySelected ? Icons.radio_button_checked : Icons.radio_button_off, color: !isTodaySelected ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8), size: 20), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(!isTodaySelected && selectedDate != null ? displayDate : 'Select Old Date', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: !isTodaySelected ? const Color(0xFF1E293B) : const Color(0xFF94A3B8))), const Text('Tap to pick a date', style: TextStyle(fontSize: 11, color: Color(0xFF64748B)))])), const Icon(Icons.calendar_today, size: 18, color: Color(0xFF64748B)), if (!isTodaySelected) ...[const SizedBox(width: 8), Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: const Color(0xFF3B82F6).withOpacity(0.1), borderRadius: BorderRadius.circular(6)), child: const Text('Billed', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF3B82F6))))]]),
                  ),
                ),
                const SizedBox(height: 16),
                if (isOldDate) Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)), child: const Row(children: [Icon(Icons.info_outline, size: 16, color: Color(0xFF92400E)), SizedBox(width: 8), Expanded(child: Text('Old date: Orders will be marked as Billed with packed date set.', style: TextStyle(fontSize: 11, color: Color(0xFF92400E), fontWeight: FontWeight.w500)))])),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      final dateToUse = selectedDate ?? today;
                      final dateStr = '${dateToUse.day.toString().padLeft(2, '0')}/${dateToUse.month.toString().padLeft(2, '0')}/${dateToUse.year.toString().substring(2)}';
                      _executeCartSubmission(selectedOrders, dateStr, isOldDate);
                    },
                    icon: const Icon(Icons.rocket_launch, size: 18),
                    label: const Text('PUSH', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
                    style: ElevatedButton.styleFrom(backgroundColor: isOldDate ? const Color(0xFF3B82F6) : const Color(0xFF10B981), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 2),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _executeCartSubmission(List<Map<String, dynamic>> selectedOrders, String cartDate, bool markBilled) async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => AlertDialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), contentPadding: const EdgeInsets.all(32), content: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(color: Color(0xFF10B981)), const SizedBox(height: 20), Text('Adding ${selectedOrders.length} order(s) to Cart...', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))])));
    try {
      await _apiService.addToCart(selectedOrders, cartDate: cartDate, markBilled: markBilled);
      await _loadOrders(showLoading: false);
      if (mounted) Navigator.pop(context);
      HapticFeedback.heavyImpact();
      setState(() { _cartSelectedIds.clear(); _cartOrderData.clear(); _isAddToCartMode = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${selectedOrders.length} order(s) pushed to cart!'), backgroundColor: const Color(0xFF10B981), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      HapticFeedback.vibrate();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error adding to cart: $e'), backgroundColor: Colors.red));
    }
  }

  // ===== SHARE =====
  Future<void> _shareSelectedOrders() async {
    if (_selectedOrderIds.isEmpty) return;
    final List<Map<String, dynamic>> selectedOrders = [];
    for (var date in _ordersData.keys) {
      final clients = _ordersData[date] is Map ? _ordersData[date] as Map<String, dynamic> : <String, dynamic>{};
      for (var clientName in clients.keys) {
        final rows = (clients[clientName] as List?) ?? [];
        for (var row in rows) {
          final rawId = row[row.length - 1].toString();
          final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;
          final orderId = '$date|$clientName|$docId';
          if (_selectedOrderIds.contains(orderId)) {
            selectedOrders.add({'orderDate': date, 'billingFrom': '${row[1]}', 'client': clientName, 'lot': '${row[3]}', 'grade': '${row[4]}', 'bagbox': '${row[5]}', 'no': '${row[6]}', 'kgs': '${row[7]}', 'price': '${row[8]}', 'brand': '${row[9]}', 'status': '${row[10]}', 'notes': row.length > 11 && row[11] != null && row[11] is! int && row[11] is! double ? '${row[11]}' : ''});
          }
        }
      }
    }
    if (selectedOrders.isEmpty) return;
    // Build text share
    final buffer = StringBuffer();
    buffer.writeln('Orders for ${widget.clientName}');
    buffer.writeln('${'=' * 30}');
    for (final o in selectedOrders) {
      buffer.writeln('${o['orderDate']} | ${o['lot']}: ${o['grade']} - ${o['no']} ${o['bagbox']} - ${o['kgs']} kgs x ₹${o['price']}');
    }
    await Share.share(buffer.toString());
    setState(() { _isShareMode = false; _selectedOrderIds.clear(); });
  }

  // ===== EDIT =====
  Future<void> _openEditModal(List<dynamic> row) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _OrderEditDialog(row: row, dropdownOptions: _dropdownOptions, isAdmin: _isAdmin),
    );
    if (result == null) return;

    if (!_isAdmin || !_canEditOrders) {
      final rawId = row[row.length - 1].toString();
      await _requestApproval(actionType: 'edit', resourceType: 'order', resourceId: rawId.startsWith('-') ? rawId.substring(1) : rawId, resourceData: _rowToMap(row), proposedChanges: result);
      return;
    }

    final rawId = row[row.length - 1].toString();
    final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;
    final originalRow = List<dynamic>.from(row);
    final fieldIndex = {'grade': 4, 'bagbox': 5, 'no': 6, 'kgs': 7, 'price': 8, 'brand': 9, 'status': 10, 'notes': 11};
    optimistic(
      type: 'update',
      applyLocal: () { setState(() { for (final entry in result.entries) { final idx = fieldIndex[entry.key]; if (idx != null && idx < row.length) row[idx] = entry.value; } }); },
      apiCall: () async { await _apiService.updateOrder(docId, result); _loadOrders(showLoading: false); },
      rollback: () { setState(() { for (int i = 0; i < originalRow.length && i < row.length; i++) row[i] = originalRow[i]; }); },
      successMessage: 'Order updated',
      failureMessage: 'Failed to update order. Reverted.',
    );
  }

  // ===== BUILD =====
  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: widget.clientName,
      disableInternalScrolling: true,
      topActions: [
        if (_isShareMode)
          _buildTopButton(label: 'Cancel Share', onPressed: () => setState(() { _isShareMode = false; _selectedOrderIds.clear(); }), color: const Color(0xFFEF4444))
        else if (_isAddToCartMode)
          _buildTopButton(label: 'Cancel Cart', onPressed: () => setState(() { _isAddToCartMode = false; _cartSelectedIds.clear(); _cartOrderData.clear(); }), color: const Color(0xFFEF4444))
        else
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF475569), size: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              switch (value) {
                case 'share_order': setState(() { _isShareMode = true; _isAddToCartMode = false; _cartSelectedIds.clear(); _cartOrderData.clear(); }); break;
                case 'add_to_cart': setState(() { _isAddToCartMode = true; _isShareMode = false; _selectedOrderIds.clear(); _cartSelectedIds.clear(); _cartOrderData.clear(); }); break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'share_order', child: Row(children: [Icon(Icons.share_rounded, color: Color(0xFF25D366), size: 20), SizedBox(width: 10), Text('Share Order', style: TextStyle(fontWeight: FontWeight.w600))])),
              if (_isAdmin) const PopupMenuItem(value: 'add_to_cart', child: Row(children: [Icon(Icons.add_shopping_cart, color: Color(0xFF10B981), size: 20), SizedBox(width: 10), Text('Add to Cart', style: TextStyle(fontWeight: FontWeight.w600))])),
            ],
          ),
      ],
      content: RefreshIndicator(
        onRefresh: () => _loadOrders(),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 80),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Filters
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Row(children: [
                            Expanded(
                              child: _buildDropdownFilter('Status', _statusFilter, ['All', 'Pending', 'On Progress', 'Billed'], (val) { _statusFilter = val ?? 'All'; _loadOrders(); }),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: SearchableGradeDropdown(
                                grades: (_dropdownOptions['grade'] as List?)?.cast<String>() ?? [],
                                value: _gradeFilter.isEmpty ? null : _gradeFilter,
                                onChanged: (val) { _gradeFilter = val ?? ''; _loadOrders(); },
                              ),
                            ),
                          ]),
                        ),
                        // Mode banners
                        if (_isShareMode)
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: const Color(0xFF25D366).withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF25D366).withOpacity(0.3))),
                            child: Row(children: [const Icon(Icons.touch_app_rounded, color: Color(0xFF25D366), size: 18), const SizedBox(width: 8), Text('Tap orders to select for sharing (${_selectedOrderIds.length} selected)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF25D366)))]),
                          ),
                        if (_isAddToCartMode)
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: const Color(0xFF10B981).withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3))),
                            child: Row(children: [const Icon(Icons.shopping_cart_checkout, color: Color(0xFF10B981), size: 18), const SizedBox(width: 8), Text('Select pending orders for cart (${_cartSelectedIds.length} selected)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF10B981)))]),
                          ),
                        // Orders list
                        _buildOrderList(),
                      ],
                    ),
                  ),
                  // FABs
                  if (_isShareMode && _selectedOrderIds.isNotEmpty)
                    Positioned(
                      bottom: 16, right: 16,
                      child: FloatingActionButton.extended(
                        heroTag: 'share_fab',
                        onPressed: _shareSelectedOrders,
                        backgroundColor: const Color(0xFF25D366),
                        icon: const Icon(Icons.share_rounded, color: Colors.white),
                        label: Text('Share ${_selectedOrderIds.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  if (_isAddToCartMode && _cartSelectedIds.isNotEmpty)
                    Positioned(
                      bottom: 16, right: 16,
                      child: FloatingActionButton.extended(
                        heroTag: 'cart_fab',
                        onPressed: _submitCartOrders,
                        backgroundColor: const Color(0xFF10B981),
                        icon: const Icon(Icons.rocket_launch, color: Colors.white),
                        label: Text('Push ${_cartSelectedIds.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildTopButton({required String label, required VoidCallback onPressed, required Color color}) {
    return Container(
      height: 32,
      decoration: BoxDecoration(gradient: LinearGradient(colors: [color, color.withOpacity(0.8)]), borderRadius: BorderRadius.circular(20)),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(backgroundColor: Colors.transparent, shadowColor: Colors.transparent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildDropdownFilter(String hint, String? value, List<String> items, Function(String?) onChanged) {
    return SizedBox(
      width: double.infinity,
      child: DropdownButtonFormField<String>(
        value: (value != null && value.isNotEmpty) ? value : null,
        decoration: InputDecoration(filled: true, fillColor: Colors.white, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC)))),
        style: const TextStyle(fontSize: 13, color: Colors.black),
        borderRadius: BorderRadius.circular(20),
        hint: Text(hint, style: const TextStyle(fontSize: 13)),
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildOrderList() {
    final dates = _ordersData.keys.toList();
    if (dates.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(40), child: Text('No orders found.')));

    DateTime? parseOrderDate(String dateStr) {
      try {
        final parts = dateStr.split('/');
        if (parts.length == 3) {
          final day = int.parse(parts[0]);
          final month = int.parse(parts[1]);
          int year = int.parse(parts[2]);
          if (year < 100) year = year < 50 ? 2000 + year : 1900 + year;
          return DateTime(year, month, day);
        }
      } catch (e) { /* ignore */ }
      return null;
    }

    // Ledger: always newest first
    dates.sort((a, b) {
      final dateA = parseOrderDate(a);
      final dateB = parseOrderDate(b);
      if (dateA == null && dateB == null) return b.compareTo(a);
      if (dateA == null) return 1;
      if (dateB == null) return -1;
      return dateB.compareTo(dateA);
    });

    List<Widget> children = [];
    for (var date in dates) {
      final clientsRaw = _ordersData[date];
      if (clientsRaw is! Map) continue;
      final clientsMap = clientsRaw as Map<String, dynamic>;
      List<Widget> orderWidgets = [];

      for (var clientName in clientsMap.keys.toList()..sort()) {
        final rawRows = clientsMap[clientName];
        if (rawRows is! List || rawRows.isEmpty) continue;
        for (var row in rawRows) {
          final rawId = row[row.length - 1].toString();
          final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;
          final orderId = '$date|$clientName|$docId';
          final statusText = '${row[10]}'.toLowerCase();
          final isPending = statusText == 'pending';

          orderWidgets.add(
            Slidable(
              key: ValueKey(orderId),
              enabled: !_isShareMode && !_isAddToCartMode,
              startActionPane: (isPending && _isAdmin) ? ActionPane(motion: const DrawerMotion(), extentRatio: 0.25, children: [
                SlidableAction(onPressed: (_) { HapticFeedback.mediumImpact(); _dispatchOrder(row, docId); }, backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white, icon: Icons.local_shipping_rounded, label: 'Dispatch', borderRadius: const BorderRadius.horizontal(left: Radius.circular(16))),
              ]) : null,
              endActionPane: (_isAdmin || _canDeleteOrders) ? ActionPane(motion: const DrawerMotion(), extentRatio: 0.25, children: [
                SlidableAction(onPressed: (_) { HapticFeedback.mediumImpact(); _deleteOrder(docId, orderRow: row); }, backgroundColor: const Color(0xFFEF4444), foregroundColor: Colors.white, icon: Icons.delete_rounded, label: 'Delete', borderRadius: const BorderRadius.horizontal(right: Radius.circular(16))),
              ]) : null,
              child: _OrderLine(
                row: row, date: date, clientName: clientName,
                isAdmin: _isAdmin, isSuperAdmin: _isSuperAdmin,
                canEdit: _isAdmin || _canEditOrders, canDelete: _isAdmin || _canDeleteOrders,
                isShareMode: _isShareMode,
                hasDispatchDoc: _orderDispatchDocMap.containsKey(docId),
                onViewDispatchDoc: _orderDispatchDocMap.containsKey(docId) ? () => Navigator.pushNamed(context, '/dispatch_documents') : null,
                isAddToCartMode: _isAddToCartMode && isPending,
                isSelected: _isAddToCartMode ? _cartSelectedIds.contains(orderId) : _selectedOrderIds.contains(orderId),
                onEdit: (_isAdmin || _canEditOrders) ? () => _openEditModal(row) : null,
                onDelete: (_isAdmin || _canDeleteOrders) ? () => _deleteOrder(docId, orderRow: row) : null,
                onPartialDispatch: (_isAddToCartMode && isPending) ? () => _showPartialDispatchModal(row, orderId) : null,
                onSelectionChanged: (selected) {
                  setState(() {
                    if (_isAddToCartMode) {
                      if (selected) { _cartSelectedIds.add(orderId); _cartOrderData[orderId] = {..._rowToMap(row), 'index': docId}; } else { _cartSelectedIds.remove(orderId); _cartOrderData.remove(orderId); }
                    } else {
                      if (selected) _selectedOrderIds.add(orderId); else _selectedOrderIds.remove(orderId);
                    }
                  });
                },
              ),
            ),
          );
        }
      }

      if (orderWidgets.isNotEmpty) {
        children.add(Padding(padding: const EdgeInsets.only(top: 24.0, left: 16, bottom: 8.0), child: Text(date, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))));
        children.addAll(orderWidgets);
      }
    }

    if (children.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(40), child: Text('No orders found for this filter.')));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

// ============================================================================
// _OrderLine — replicated from view_orders_screen.dart
// ============================================================================

class _OrderLine extends StatefulWidget {
  final List<dynamic> row;
  final String date;
  final String clientName;
  final bool isAdmin;
  final bool isSuperAdmin;
  final bool canEdit;
  final bool canDelete;
  final bool isShareMode;
  final bool isAddToCartMode;
  final bool isSelected;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onPartialDispatch;
  final Function(bool) onSelectionChanged;
  final bool hasDispatchDoc;
  final VoidCallback? onViewDispatchDoc;

  const _OrderLine({
    required this.row, required this.date, required this.clientName,
    required this.isAdmin, this.isSuperAdmin = false,
    this.canEdit = true, this.canDelete = true,
    required this.isShareMode, this.isAddToCartMode = false,
    required this.isSelected,
    this.onEdit, this.onDelete, this.onPartialDispatch,
    required this.onSelectionChanged,
    this.hasDispatchDoc = false, this.onViewDispatchDoc,
  });

  @override
  State<_OrderLine> createState() => _OrderLineState();
}

class _OrderLineState extends State<_OrderLine> with SingleTickerProviderStateMixin {
  AnimationController? _pulseController;
  Animation<double>? _pulseAnimation;

  @override
  void initState() { super.initState(); _setupAnimation(); }

  @override
  void didUpdateWidget(covariant _OrderLine oldWidget) { super.didUpdateWidget(oldWidget); if (oldWidget.date != widget.date) _setupAnimation(); }

  void _setupAnimation() {
    final ageInfo = _getOrderAgeInfo();
    final ageDays = (ageInfo['days'] as int?) ?? 0;
    if (ageDays > 10 && _pulseController == null) {
      _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
      _pulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _pulseController!, curve: Curves.easeInOut));
      _pulseController!.repeat(reverse: true);
    } else if (ageDays <= 10 && _pulseController != null) {
      _pulseController!.dispose(); _pulseController = null; _pulseAnimation = null;
    }
  }

  @override
  void dispose() { _pulseController?.dispose(); super.dispose(); }

  Map<String, dynamic> _getOrderAgeInfo() {
    try {
      final parts = widget.date.split('/');
      if (parts.length == 3) {
        final day = int.parse(parts[0]);
        final month = int.parse(parts[1]);
        var year = int.parse(parts[2]);
        if (year < 100) year += 2000;
        final orderDate = DateTime(year, month, day);
        final days = DateTime.now().difference(orderDate).inDays;
        Color color;
        if (days > 10) { color = const Color(0xFFEF4444); }
        else if (days >= 5) { color = const Color(0xFFF59E0B); }
        else { color = const Color(0xFF10B981); }
        return {'days': days, 'color': color};
      }
    } catch (_) {}
    return {'days': 0, 'color': const Color(0xFF94A3B8)};
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending': return AppTheme.warning;
      case 'on progress': return const Color(0xFF5D6E7E);
      case 'done': return AppTheme.success;
      case 'billed': return const Color(0xFF4A5568);
      case 'cancelled': return AppTheme.danger;
      default: return AppTheme.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final isMobile = constraints.maxWidth < 600;
      final row = widget.row;
      final brand = (row.length > 9 && row[9] != null) ? '${row[9]}' : null;
      final notes = (row.length > 11 && row[11] != null && row[11] is! int && row[11] is! double && '${row[11]}'.trim().isNotEmpty) ? '${row[11]}' : null;
      final price = row.length > 8 ? double.tryParse('${row[8]}') ?? 0.0 : 0.0;
      final ageInfo = _getOrderAgeInfo();
      final ageColor = ageInfo['color'] as Color;
      final ageDays = (ageInfo['days'] as int?) ?? 0;
      final isRed = ageDays > 10;
      final isBilled = '${row[10]}'.toLowerCase() == 'billed';
      final isAnySelectMode = widget.isShareMode || widget.isAddToCartMode;
      final isCartSelected = widget.isAddToCartMode && widget.isSelected;

      Color borderColor;
      double borderWidth;
      if (widget.isShareMode && widget.isSelected) { borderColor = const Color(0xFF25D366); borderWidth = 2.0; }
      else if (isCartSelected) { borderColor = const Color(0xFF10B981); borderWidth = 2.0; }
      else if (isBilled) { borderColor = const Color(0xFFCBD5E1); borderWidth = 1.0; }
      else { borderColor = ageColor; borderWidth = 2.0; }

      final innerContent = _buildCardContent(isMobile, row, brand, notes, price, ageColor, ageDays, isBilled, isCartSelected);

      Widget cardWidget;
      if (isRed && !isBilled && _pulseAnimation != null) {
        cardWidget = AnimatedBuilder(animation: _pulseAnimation!, builder: (context, child) {
          final pulseValue = _pulseAnimation!.value;
          return Container(margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: ageColor, width: 2.0 + pulseValue * 0.5), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2))]), child: child);
        }, child: Padding(padding: const EdgeInsets.all(12), child: innerContent));
      } else {
        cardWidget = Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          decoration: BoxDecoration(
            color: widget.isShareMode && widget.isSelected ? const Color(0xFF25D366).withOpacity(0.08) : isCartSelected ? const Color(0xFF10B981).withOpacity(0.08) : isBilled ? const Color(0xFFF8F9FA) : Colors.white,
            borderRadius: BorderRadius.circular(16), border: Border.all(color: borderColor, width: borderWidth),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Padding(padding: const EdgeInsets.all(12), child: innerContent),
        );
      }

      return GestureDetector(
        onTap: isAnySelectMode ? () => widget.onSelectionChanged(!widget.isSelected) : () => _showOrderDetailPopup(context, row, brand, notes, price, ageColor, ageDays, isBilled),
        child: Stack(children: [
          cardWidget,
          if (isBilled) Positioned.fill(child: Container(margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12), child: ClipRRect(borderRadius: BorderRadius.circular(16), child: IgnorePointer(child: Center(child: Transform.rotate(angle: -0.35, child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4), decoration: BoxDecoration(border: Border.all(color: const Color(0xFF4A5568).withOpacity(0.35), width: 2), borderRadius: BorderRadius.circular(6)), child: Text('BILLED', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: const Color(0xFF4A5568).withOpacity(0.18), letterSpacing: 6))))))))),
          if (isBilled && widget.hasDispatchDoc) Positioned(top: 8, right: 16, child: GestureDetector(onTap: widget.onViewDispatchDoc, child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: const Color(0xFF10B981).withOpacity(0.12), shape: BoxShape.circle), child: const Icon(Icons.description_rounded, size: 16, color: Color(0xFF10B981))))),
        ]),
      );
    });
  }

  Widget _buildCardContent(bool isMobile, List<dynamic> row, String? brand, String? notes, double price, Color ageColor, int ageDays, bool isBilled, bool isCartSelected) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (widget.isShareMode) _buildSelectionCheckbox(),
        Expanded(child: Row(children: [
          Expanded(child: Text('${row[3]}: ${row[4]} - ${row[6]} ${row[5]}', style: TextStyle(fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.w900, color: const Color(0xFF1E293B)), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: ageColor.withOpacity(0.15), borderRadius: BorderRadius.circular(6), border: Border.all(color: ageColor.withOpacity(0.3))), child: Text('${ageDays}d', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: ageColor))),
          const SizedBox(width: 6),
          Text('${row[7]} kgs ${price > 0 ? "x ₹${price.toInt()}" : ""}', style: TextStyle(fontSize: isMobile ? 11 : 12, fontWeight: FontWeight.w700, color: const Color(0xFF475569))),
        ])),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        if (brand != null && brand != 'N/A' && brand.isNotEmpty) ...[Text('- $brand', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primary)), const SizedBox(width: 8)],
        if (notes != null) ...[const Icon(Icons.notes_rounded, size: 14, color: Color(0xFF94A3B8)), const SizedBox(width: 4), Expanded(child: Text(notes, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontStyle: FontStyle.italic, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis)), const SizedBox(width: 8)] else const Spacer(),
        _buildStatusBadge('${row[10]}'),
      ]),
      if (widget.isAddToCartMode) ...[
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (widget.onPartialDispatch != null) IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(), icon: Icon(Icons.content_cut, color: const Color(0xFFF59E0B), size: isMobile ? 18 : 20), onPressed: widget.onPartialDispatch, tooltip: 'Partial Dispatch'),
          SizedBox(width: isMobile ? 8 : 12),
          GestureDetector(onTap: () => widget.onSelectionChanged(!widget.isSelected), child: Container(width: isMobile ? 22 : 26, height: isMobile ? 22 : 26, decoration: BoxDecoration(color: widget.isSelected ? const Color(0xFF10B981) : Colors.transparent, borderRadius: BorderRadius.circular(6), border: Border.all(color: widget.isSelected ? const Color(0xFF10B981) : const Color(0xFFCBD5E1), width: 1.5)), child: widget.isSelected ? Icon(Icons.check, size: isMobile ? 14 : 18, color: Colors.white) : null)),
        ]),
      ] else if (!widget.isShareMode && !isBilled && (widget.canEdit || widget.canDelete)) ...[
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (widget.onEdit != null) _buildRowButton('Edit', const Color(0xFF475569), widget.onEdit!, icon: Icons.edit_note_rounded),
          if (widget.onEdit != null && widget.onDelete != null) const SizedBox(width: 8),
          if (widget.onDelete != null) _buildRowButton('Delete', const Color(0xFFEF4444), widget.onDelete!, icon: Icons.delete_outline_rounded),
        ]),
      ],
    ]);
  }

  Widget _buildSelectionCheckbox() {
    return Padding(padding: const EdgeInsets.only(right: 12), child: Container(width: 18, height: 18, decoration: BoxDecoration(color: widget.isSelected ? const Color(0xFF25D366) : Colors.white, borderRadius: BorderRadius.circular(5), border: Border.all(color: widget.isSelected ? const Color(0xFF25D366) : const Color(0xFFCBD5E1), width: 1.2)), child: widget.isSelected ? const Icon(Icons.check, color: Colors.white, size: 14) : null));
  }

  Widget _buildStatusBadge(String status) {
    final color = _getStatusColor(status);
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withOpacity(0.15))), child: Text(status.toUpperCase(), style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.3)));
  }

  Widget _buildRowButton(String label, Color color, VoidCallback onPressed, {required IconData icon}) {
    return InkWell(onTap: onPressed, borderRadius: BorderRadius.circular(8), child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.12))), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14, color: color), const SizedBox(width: 4), Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color))])));
  }

  void _showOrderDetailPopup(BuildContext context, List<dynamic> row, String? brand, String? notes, double price, Color ageColor, int ageDays, bool isBilled) {
    final lot = '${row[3]}'; final grade = '${row[4]}'; final bags = '${row[6]} ${row[5]}'; final kgs = '${row[7]}'; final status = '${row[10]}'; final billing = '${row[1]}';
    showDialog(context: context, barrierColor: Colors.black38, builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Container(width: 5, height: 32, decoration: BoxDecoration(color: ageColor, borderRadius: BorderRadius.circular(3))), const SizedBox(width: 10), Expanded(child: Text(widget.clientName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF1E293B)))), GestureDetector(onTap: () => Navigator.pop(ctx), child: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 22))]),
        const Divider(height: 20),
        _popupRow('Date', widget.date), _popupRow('Lot', lot), _popupRow('Grade', grade), _popupRow('Quantity', '$bags  •  $kgs kgs'),
        if (price > 0) _popupRow('Price', '₹${price.toInt()} / kg'),
        if (brand != null && brand.isNotEmpty && brand != 'N/A') _popupRow('Brand', brand),
        if (notes != null && notes.isNotEmpty) _popupRow('Notes', notes),
        _popupRow('Status', status),
        if (billing.isNotEmpty) _popupRow('Billing', billing),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerRight, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: ageColor.withOpacity(0.12), borderRadius: BorderRadius.circular(8), border: Border.all(color: ageColor.withOpacity(0.3))), child: Text('$ageDays days old', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ageColor)))),
      ]))),
    ));
  }

  Widget _popupRow(String label, String value) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 70, child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8)))), Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))))]));
  }
}

// ============================================================================
// _OrderEditDialog — replicated from view_orders_screen.dart
// ============================================================================

class _OrderEditDialog extends StatefulWidget {
  final List<dynamic> row;
  final Map<String, dynamic> dropdownOptions;
  final bool isAdmin;
  const _OrderEditDialog({required this.row, required this.dropdownOptions, required this.isAdmin});
  @override
  State<_OrderEditDialog> createState() => _OrderEditDialogState();
}

class _OrderEditDialogState extends State<_OrderEditDialog> {
  late TextEditingController _noController;
  late TextEditingController _kgsController;
  late TextEditingController _priceController;
  late TextEditingController _notesController;
  String? _selectedGrade;
  String? _selectedBagbox;
  String? _selectedBrand;

  @override
  void initState() {
    super.initState();
    _noController = TextEditingController(text: '${widget.row[6]}');
    _kgsController = TextEditingController(text: '${widget.row[7]}');
    _priceController = TextEditingController(text: '${widget.row[8]}');
    _notesController = TextEditingController(text: widget.row.length > 11 ? '${widget.row[11] ?? ''}' : '');
    _selectedGrade = '${widget.row[4]}';
    _selectedBagbox = '${widget.row[5]}';
    _selectedBrand = widget.row.length > 9 ? '${widget.row[9]}' : null;
  }

  @override
  void dispose() { _noController.dispose(); _kgsController.dispose(); _priceController.dispose(); _notesController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final grades = (widget.dropdownOptions['grade'] as List?)?.cast<String>() ?? [];
    final bagboxes = (widget.dropdownOptions['bagbox'] as List?)?.cast<String>() ?? [];
    final brands = (widget.dropdownOptions['brand'] as List?)?.cast<String>() ?? [];

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [Icon(Icons.edit_rounded, color: Color(0xFF3B82F6), size: 24), SizedBox(width: 8), Text('Edit Order', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))]),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Lot (read-only)
        TextFormField(initialValue: '${widget.row[3]}', decoration: const InputDecoration(labelText: 'Lot', enabled: false), readOnly: true),
        const SizedBox(height: 12),
        // Grade
        DropdownButtonFormField<String>(value: _selectedGrade, decoration: const InputDecoration(labelText: 'Grade'), items: grades.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(), onChanged: (val) => setState(() => _selectedGrade = val)),
        const SizedBox(height: 12),
        // Bag/Box
        DropdownButtonFormField<String>(value: _selectedBagbox, decoration: const InputDecoration(labelText: 'Bag/Box'), items: bagboxes.map((b) => DropdownMenuItem(value: b, child: Text(b))).toList(), onChanged: (val) => setState(() => _selectedBagbox = val)),
        const SizedBox(height: 12),
        // No.
        TextField(controller: _noController, decoration: const InputDecoration(labelText: 'No.'), keyboardType: TextInputType.number),
        const SizedBox(height: 12),
        // Kgs
        TextField(controller: _kgsController, decoration: const InputDecoration(labelText: 'Kgs'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        const SizedBox(height: 12),
        // Price
        TextField(controller: _priceController, decoration: const InputDecoration(labelText: 'Price'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        const SizedBox(height: 12),
        // Brand
        DropdownButtonFormField<String>(value: brands.contains(_selectedBrand) ? _selectedBrand : null, decoration: const InputDecoration(labelText: 'Brand'), items: brands.map((b) => DropdownMenuItem(value: b, child: Text(b))).toList(), onChanged: (val) => setState(() => _selectedBrand = val)),
        const SizedBox(height: 12),
        // Notes
        TextField(controller: _notesController, decoration: const InputDecoration(labelText: 'Notes'), maxLines: 2),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            final changes = <String, dynamic>{};
            if (_selectedGrade != '${widget.row[4]}') changes['grade'] = _selectedGrade;
            if (_selectedBagbox != '${widget.row[5]}') changes['bagbox'] = _selectedBagbox;
            if (_noController.text != '${widget.row[6]}') changes['no'] = num.tryParse(_noController.text) ?? _noController.text;
            if (_kgsController.text != '${widget.row[7]}') changes['kgs'] = num.tryParse(_kgsController.text) ?? _kgsController.text;
            if (_priceController.text != '${widget.row[8]}') changes['price'] = num.tryParse(_priceController.text) ?? _priceController.text;
            if (_selectedBrand != (widget.row.length > 9 ? '${widget.row[9]}' : null)) changes['brand'] = _selectedBrand ?? '';
            final oldNotes = widget.row.length > 11 ? '${widget.row[11] ?? ''}' : '';
            if (_notesController.text != oldNotes) changes['notes'] = _notesController.text;
            if (changes.isEmpty) { Navigator.pop(context); return; }
            Navigator.pop(context, changes);
          },
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3B82F6), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
