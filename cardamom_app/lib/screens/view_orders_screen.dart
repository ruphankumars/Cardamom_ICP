import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/whatsapp_service.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/cache_manager.dart';
import '../services/operation_queue.dart';
import '../services/navigation_service.dart';
import '../mixins/optimistic_action_mixin.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/offline_indicator.dart';
import '../widgets/grade_grouped_dropdown.dart';

class ViewOrdersScreen extends StatefulWidget {
  final String? initialStatus;
  final String? initialBilling;
  final String? initialSearch;
  
  const ViewOrdersScreen({
    super.key,
    this.initialStatus,
    this.initialBilling,
    this.initialSearch,
  });

  @override
  State<ViewOrdersScreen> createState() => _ViewOrdersScreenState();
}

class _ViewOrdersScreenState extends State<ViewOrdersScreen> with RouteAware, OptimisticActionMixin {
  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();

  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  Map<String, dynamic> _ordersData = {};
  Map<String, dynamic> _dropdownOptions = {'grade': [], 'bagbox': [], 'brand': []};
  String _billingFilter = '';
  String _statusFilter = 'Pending';  // Default to Pending
  String _gradeFilter = '';  // Grade filter
  String _searchQuery = '';
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  String _userRole = 'user';  // Track user role for edit access
  List<String> _searchSuggestions = [];  // Client names for dropdown

  // Offline cache state
  bool _isFromCache = false;
  String _cacheAge = '';

  // Share selection mode state
  bool _isShareMode = false;
  final Set<String> _selectedOrderIds = {};  // Using "date|client|lot" as unique key

  // Add to Cart mode state
  bool _isAddToCartMode = false;
  final Set<String> _cartSelectedIds = {};  // Same key format: "date|client|lot"
  final Map<String, Map<String, dynamic>> _cartOrderData = {};  // orderId -> order data map

  // Dispatch document linkage (orderId -> dispatch doc ID)
  Map<String, String> _orderDispatchDocMap = {};

  @override
  void initState() {
    super.initState();
    _applyInitialFilters();
    _loadInitialData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() => _loadOrders();

  /// Apply initial filters from widget parameters (URL query params)
  void _applyInitialFilters() {
    if (widget.initialStatus != null && widget.initialStatus!.isNotEmpty) {
      final status = widget.initialStatus!.toLowerCase();
      // Explicit mapping to ensure correct capitalization for multi-word statuses
      const statusMap = {'all': 'All', 'pending': 'Pending', 'on progress': 'On Progress', 'billed': 'Billed'};
      if (statusMap.containsKey(status)) {
        _statusFilter = statusMap[status]!;
      }
    }
    if (widget.initialBilling != null && widget.initialBilling!.isNotEmpty) {
      final billing = widget.initialBilling!.toUpperCase();
      if (billing == 'SYGT' || billing == 'ESPL') {
        _billingFilter = billing;
      }
    }
    if (widget.initialSearch != null && widget.initialSearch!.isNotEmpty) {
      _searchQuery = widget.initialSearch!;
    }
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      // Get user role and page access from auth state
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

  /// Load orders from server with current filter values applied server-side.
  /// The backend only queries the relevant Firestore collection(s) and
  /// applies client/billing/grade filters before returning data.
  Future<void> _loadOrders({bool showLoading = true}) async {
    if (showLoading) setState(() => _isLoading = true);
    // When called as background refresh (after mutation), invalidate related caches
    if (!showLoading) _invalidateRelatedCaches();
    try {
      final response = await _apiService.getFilteredOrders(
        status: _statusFilter,
        client: _searchQuery,
        billing: _billingFilter,
        grade: _gradeFilter,
      );
      if (!mounted) return;
      final rawData = Map<String, dynamic>.from(response.data as Map);
      setState(() {
        // The filtered endpoint returns { orders: {...}, clients: [...] }
        if (rawData.containsKey('orders')) {
          final ordersMap = rawData['orders'];
          _ordersData = ordersMap is Map
              ? Map<String, dynamic>.from(ordersMap)
              : {};
          // Update client dropdown from server-provided full client list
          final clientsList = rawData['clients'];
          if (clientsList is List) {
            _searchSuggestions = clientsList.cast<String>();
          }
        } else {
          // Fallback: plain { date: { client: [rows] } } shape
          _ordersData = Map<String, dynamic>.from(rawData);
        }
        _isFromCache = false;
        _cacheAge = '';
        if (showLoading) _isLoading = false;
      });
      // Background: check if any billed orders have dispatch documents
      _loadDispatchDocMap();
    } catch (e) {
      debugPrint('Error loading orders: $e');
      if (!mounted) return;
      if (showLoading) setState(() => _isLoading = false);
    }
  }

  /// Invalidate related caches after order mutations so other screens see fresh data.
  void _invalidateRelatedCaches() {
    try {
      final cm = context.read<CacheManager>();
      cm.dailyCartCache.clear();
      cm.pendingOrdersCache.clear();
      cm.dashboardCache.clear();
      cm.stockCache.clear();
      cm.salesSummaryCache.clear();
    } catch (_) {}
  }

  /// Load dispatch document linkage for billed orders (runs in background)
  Future<void> _loadDispatchDocMap() async {
    if (_statusFilter.toLowerCase() != 'billed' && _statusFilter.toLowerCase() != 'all') {
      return; // Only check for billed orders
    }
    try {
      // Collect all doc IDs from current orders
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
      setState(() {
        _dropdownOptions = result.data;
      });
    } catch (e) {
      debugPrint('Error loading dropdowns: $e');
    }
  }

  Future<void> _deleteOrder(String docId, {List<dynamic>? orderRow}) async {
    // Route through approval for non-admin users OR restricted admins
    if (!_isAdmin || !_canDeleteOrders) {
      await _requestApproval(
        actionType: 'delete',
        resourceType: 'order',
        resourceId: docId,
        resourceData: orderRow != null ? {
          'orderDate': orderRow[0] ?? '',
          'billingFrom': orderRow[1] ?? '',
          'client': orderRow[2] ?? '',
          'lot': orderRow[3] ?? '',
          'grade': orderRow[4] ?? '',
          'bagbox': orderRow[5] ?? '',
          'no': orderRow[6] ?? 0,
          'kgs': orderRow[7] ?? 0,
          'price': orderRow[8] ?? 0,
          'brand': orderRow[9] ?? '',
          'status': orderRow[10] ?? '',
          'notes': orderRow.length > 11 ? orderRow[11] ?? '' : '',
        } : {'docId': docId},
      );
      return;
    }

    // Admin with permission - delete directly
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

    if (confirmed == true) {
      // Snapshot for rollback: find and remove the row from local data
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
                  // Clean up empty client/date entries
                  if (rows.isEmpty) (clients as Map).remove(removedClient);
                  if ((clients as Map).isEmpty) _ordersData.remove(removedDate);
                }
              }
            });
          }
        },
        apiCall: () async {
          await _apiService.deleteOrder(docId);
          // Silently refresh in background
          _loadOrders(showLoading: false);
        },
        rollback: () {
          if (removedFrom != null && removedDate != null && removedClient != null && removedIndex >= 0) {
            setState(() {
              _ordersData.putIfAbsent(removedDate!, () => <String, dynamic>{});
              final clients = _ordersData[removedDate!] as Map;
              clients.putIfAbsent(removedClient!, () => <dynamic>[]);
              final rows = clients[removedClient!] as List;
              rows.insert(removedIndex.clamp(0, rows.length), removedFrom!['row']);
            });
          }
        },
        successMessage: 'Order deleted',
        failureMessage: 'Failed to delete order. Restored.',
      );
    }
  }

  /// Request approval for edit/delete operations (for non-admin users)
  Future<void> _requestApproval({
    required String actionType,
    required String resourceType,
    required dynamic resourceId,
    Map<String, dynamic>? resourceData,
    Map<String, dynamic>? proposedChanges,
  }) async {
    // Get user info from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId') ?? '';
    final userName = prefs.getString('username') ?? 'Unknown User';
    
    // Show reason input dialog
    final reason = await showDialog<String>(
      context: context,
      builder: (c) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(actionType == 'delete' ? 'Request Delete Approval' : 'Request Edit Approval'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This action requires Super Admin approval.',
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: 'Reason (optional)',
                  hintText: 'Why do you need this change?',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, null), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(c, controller.text),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E)),
              child: const Text('Submit Request'),
            ),
          ],
        );
      },
    );

    if (reason == null) return; // User cancelled

    fireAndForget(
      type: 'send',
      apiCall: () => _apiService.createApprovalRequest({
        'requesterId': userId,
        'requesterName': userName,
        'actionType': actionType,
        'resourceType': resourceType,
        'resourceId': resourceId,
        'resourceData': resourceData,
        'proposedChanges': proposedChanges,
        'reason': reason,
      }),
      successMessage: 'Approval request submitted',
      failureMessage: 'Failed to submit request',
    );
  }

  // Phase 3.5: Dispatch order via swipe gesture
  Future<void> _dispatchOrder(List<dynamic> row, String orderDocId) async {
    // Extract order data from row
    final orderData = {
      'orderDate': row[0] ?? '',
      'billingFrom': row[1] ?? '',
      'client': row[2] ?? '',
      'lot': row[3] ?? '',
      'grade': row[4] ?? '',
      'bagbox': row[5] ?? '',
      'no': row[6] ?? 0,
      'kgs': row[7] ?? 0,
      'price': row[8] ?? 0,
      'brand': row[9] ?? '',
      'notes': row.length > 11 ? (row[11] ?? '') : '',
      'index': orderDocId,
    };

    // Show loading popup
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.all(32),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF10B981)),
            const SizedBox(height: 20),
            const Text('Adding to Cart...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );

    try {
      await _apiService.addToCart([orderData]);
      await _loadOrders(showLoading: false);
      
      // Close loading popup
      if (mounted) Navigator.pop(context);
      
      // Success haptic
      HapticFeedback.heavyImpact();
      
      // Show success snackbar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${orderData['lot']} - ${orderData['grade']} dispatched!',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // Close loading popup
      if (mounted) Navigator.pop(context);
      
      // Error haptic
      HapticFeedback.vibrate();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error dispatching: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Add to Cart: Partial dispatch modal
  void _showPartialDispatchModal(List<dynamic> row, String orderId) {
    final totalKgs = (num.tryParse(row[7].toString()) ?? 0).toDouble();
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.all(24),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.content_cut, color: Color(0xFFF59E0B), size: 22),
                SizedBox(width: 8),
                Text('Partial Dispatch', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            Text('${row[3]}: ${row[4]} - ${row[7]} kgs', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            const SizedBox(height: 4),
            Text('Enter quantity to dispatch (Total: $totalKgs kg)', style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Enter Kgs',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
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

              // Show progress
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  contentPadding: const EdgeInsets.all(32),
                  content: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(strokeWidth: 3, valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF5D6E7E))),
                      SizedBox(height: 20),
                      Text('Dispatching...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              );

              try {
                final rawId = row[row.length - 1].toString();
                final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;
                final orderObj = {
                  'orderDate': row[0] ?? '',
                  'billingFrom': row[1] ?? '',
                  'client': row[2] ?? '',
                  'lot': row[3] ?? '',
                  'grade': row[4] ?? '',
                  'bagbox': row[5] ?? '',
                  'no': row[6] ?? 0,
                  'kgs': row[7] ?? 0,
                  'price': row[8] ?? 0,
                  'brand': row[9] ?? '',
                  'notes': row.length > 11 ? (row[11] ?? '') : '',
                  'index': docId,
                };
                await _apiService.partialDispatch(orderObj, qty);
                if (mounted) Navigator.pop(context);
                HapticFeedback.heavyImpact();
                await _loadOrders(showLoading: false);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✂️ ${row[3]} - ${row[4]}: ${qty}kg dispatched!'),
                      backgroundColor: const Color(0xFFF59E0B),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) Navigator.pop(context);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5D6E7E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            child: const Text('Dispatch'),
          ),
        ],
      ),
    );
  }

  // Add to Cart: Bulk submit selected orders
  Future<void> _submitCartOrders() async {
    if (_cartSelectedIds.isEmpty) return;

    // Gather order data for selected IDs
    final selectedOrders = _cartSelectedIds
        .where((id) => _cartOrderData.containsKey(id))
        .map((id) => _cartOrderData[id]!)
        .toList();

    if (selectedOrders.isEmpty) return;

    // Show date picker popup before submitting
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
          final displayDate = selectedDate != null
              ? '${selectedDate!.day.toString().padLeft(2, '0')}/${selectedDate!.month.toString().padLeft(2, '0')}/${selectedDate!.year.toString().substring(2)}'
              : todayStr;
          final isOldDate = selectedDate != null && selectedDate!.isBefore(DateTime(today.year, today.month, today.day));

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            insetPadding: const EdgeInsets.symmetric(horizontal: 32),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Row(
                    children: [
                      const Icon(Icons.calendar_month, color: Color(0xFF10B981), size: 22),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Select Cart Date', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx),
                        child: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${selectedOrders.length} order(s) selected',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 16),

                  // Today option
                  GestureDetector(
                    onTap: () {
                      setDialogState(() {
                        isTodaySelected = true;
                        selectedDate = null;
                      });
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isTodaySelected ? const Color(0xFF10B981).withOpacity(0.08) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isTodaySelected ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
                          width: isTodaySelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isTodaySelected ? Icons.radio_button_checked : Icons.radio_button_off,
                            color: isTodaySelected ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Today', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
                                Text(todayStr, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8B5CF6).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('On Progress', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF8B5CF6))),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Old date option
                  GestureDetector(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: selectedDate ?? today.subtract(const Duration(days: 1)),
                        firstDate: DateTime(2020),
                        lastDate: today,
                      );
                      if (picked != null) {
                        setDialogState(() {
                          selectedDate = picked;
                          isTodaySelected = (picked.year == today.year && picked.month == today.month && picked.day == today.day);
                        });
                      }
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: !isTodaySelected ? const Color(0xFF3B82F6).withOpacity(0.08) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: !isTodaySelected ? const Color(0xFF3B82F6) : const Color(0xFFE2E8F0),
                          width: !isTodaySelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            !isTodaySelected ? Icons.radio_button_checked : Icons.radio_button_off,
                            color: !isTodaySelected ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8),
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  !isTodaySelected && selectedDate != null ? displayDate : 'Select Old Date',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: !isTodaySelected ? const Color(0xFF1E293B) : const Color(0xFF94A3B8),
                                  ),
                                ),
                                const Text('Tap to pick a date', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                              ],
                            ),
                          ),
                          const Icon(Icons.calendar_today, size: 18, color: Color(0xFF64748B)),
                          if (!isTodaySelected) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFF3B82F6).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('Billed', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF3B82F6))),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Info text
                  if (isOldDate)
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, size: 16, color: Color(0xFF92400E)),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Old date: Orders will be marked as Billed with packed date set.',
                              style: TextStyle(fontSize: 11, color: Color(0xFF92400E), fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 16),

                  // PUSH button
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        final dateToUse = selectedDate ?? today;
                        final dateStr = '${dateToUse.day.toString().padLeft(2, '0')}/${dateToUse.month.toString().padLeft(2, '0')}/${dateToUse.year.toString().substring(2)}';
                        final markBilled = isOldDate;
                        _executeCartSubmission(selectedOrders, dateStr, markBilled);
                      },
                      icon: const Icon(Icons.rocket_launch, size: 18),
                      label: const Text('PUSH', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isOldDate ? const Color(0xFF3B82F6) : const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _executeCartSubmission(List<Map<String, dynamic>> selectedOrders, String cartDate, bool markBilled) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.all(32),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF10B981)),
            const SizedBox(height: 20),
            Text('Adding ${selectedOrders.length} order(s) to Cart...', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );

    try {
      await _apiService.addToCart(selectedOrders, cartDate: cartDate, markBilled: markBilled);
      await _loadOrders(showLoading: false);
      if (mounted) Navigator.pop(context);
      HapticFeedback.heavyImpact();

      final count = selectedOrders.length;
      final statusLabel = markBilled ? 'Billed' : 'On Progress';
      setState(() {
        _cartSelectedIds.clear();
        _cartOrderData.clear();
        _isAddToCartMode = false;
      });

      if (mounted) {
        // Show success modal
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            contentPadding: const EdgeInsets.all(24),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 64),
                const SizedBox(height: 16),
                Text(
                  '$count order(s) pushed!',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Status: $statusLabel  •  Date: $cartDate',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600]),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('OK'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.pushNamed(context, '/daily_cart');
                      },
                      icon: const Icon(Icons.shopping_cart, size: 16),
                      label: const Text('View Daily Cart'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      HapticFeedback.vibrate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding to cart: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  bool get _isAdmin {
    final role = _userRole.toLowerCase().trim();
    return role == 'superadmin' || role == 'admin' || role == 'ops';
  }
  bool get _isSuperAdmin => _userRole.toLowerCase().trim() == 'superadmin';
  bool _canEditOrders = false;
  bool _canDeleteOrders = false;

  Future<void> _openEditModal(List<dynamic> row) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _OrderEditDialog(row: row, dropdownOptions: _dropdownOptions, isAdmin: _isAdmin),
    );

    if (result == null) return;

    // Route through approval for non-admin users OR restricted admins
    if (!_isAdmin || !_canEditOrders) {
      final rawId = row[row.length - 1].toString();
      final editDocId = rawId.startsWith('-') ? rawId.substring(1) : rawId;

      await _requestApproval(
        actionType: 'edit',
        resourceType: 'order',
        resourceId: editDocId,
        resourceData: {
          'orderDate': row[0] ?? '',
          'billingFrom': row[1] ?? '',
          'client': row[2] ?? '',
          'lot': row[3] ?? '',
          'grade': row[4] ?? '',
          'bagbox': row[5] ?? '',
          'no': row[6] ?? 0,
          'kgs': row[7] ?? 0,
          'price': row[8] ?? 0,
          'brand': row[9] ?? '',
          'status': row[10] ?? '',
          'notes': row.length > 11 ? row[11] ?? '' : '',
        },
        proposedChanges: result,
      );
      return;
    }

    // Admin flow - update directly (optimistic)
    final rawId = row[row.length - 1].toString();
    final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;

    // Snapshot original row for rollback
    final originalRow = List<dynamic>.from(row);

    // Map field names to row indices for local update
    final fieldIndex = {
      'grade': 4, 'bagbox': 5, 'no': 6, 'kgs': 7,
      'price': 8, 'brand': 9, 'status': 10, 'notes': 11,
    };

    optimistic(
      type: 'update',
      applyLocal: () {
        setState(() {
          for (final entry in result.entries) {
            final idx = fieldIndex[entry.key];
            if (idx != null && idx < row.length) {
              row[idx] = entry.value;
            }
          }
        });
      },
      apiCall: () async {
        await _apiService.updateOrder(docId, result);
        _loadOrders(showLoading: false);
      },
      rollback: () {
        setState(() {
          for (int i = 0; i < originalRow.length && i < row.length; i++) {
            row[i] = originalRow[i];
          }
        });
      },
      successMessage: 'Order updated',
      failureMessage: 'Failed to update order. Reverted.',
    );
  }

  Future<void> _editPackedDate(List<dynamic> row) async {
    // Parse current packedDate from row[13] (dd/MM/yy format)
    DateTime initialDate = DateTime.now();
    final packedDateStr = row.length > 13 ? '${row[13]}' : '';
    if (packedDateStr.isNotEmpty) {
      try {
        initialDate = DateFormat('dd/MM/yy').parse(packedDateStr);
      } catch (_) {
        // fallback to today
      }
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'Select Packed Date',
    );
    if (picked == null) return;

    final formatted = DateFormat('dd/MM/yy').format(picked);
    final rawId = row[row.length > 13 ? 12 : row.length - 1].toString();
    final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;

    final oldPackedDate = row.length > 13 ? row[13] : '';

    optimistic(
      type: 'update',
      applyLocal: () {
        setState(() {
          if (row.length > 13) row[13] = formatted;
        });
      },
      apiCall: () async {
        await _apiService.updatePackedOrder(docId, {'packedDate': formatted});
        _loadOrders(showLoading: false);
      },
      rollback: () {
        setState(() {
          if (row.length > 13) row[13] = oldPackedDate;
        });
      },
      successMessage: 'Packed date updated to $formatted',
      failureMessage: 'Failed to update packed date. Reverted.',
    );
  }

  Future<void> _editBilledOrder(List<dynamic> row) async {
    final rawId = row[row.length > 13 ? 12 : row.length - 1].toString();
    final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _OrderEditDialog(
        row: row,
        dropdownOptions: _dropdownOptions,
        isAdmin: true,
        isBilledOrder: true,
      ),
    );
    if (result == null) return;

    final originalRow = List<dynamic>.from(row);
    const fieldIndex = {
      'orderDate': 0, 'billingFrom': 1, 'client': 2, 'lot': 3,
      'grade': 4, 'bagbox': 5, 'no': 6, 'kgs': 7,
      'price': 8, 'brand': 9, 'status': 10, 'notes': 11,
    };

    optimistic(
      type: 'update',
      applyLocal: () {
        setState(() {
          for (final entry in result.entries) {
            final idx = fieldIndex[entry.key];
            if (idx != null && idx < row.length) {
              row[idx] = entry.value;
            }
          }
          if (result.containsKey('packedDate') && row.length > 13) {
            row[13] = result['packedDate'];
          }
        });
      },
      apiCall: () async {
        await _apiService.updatePackedOrder(docId, result);
        _loadOrders(showLoading: false);
      },
      rollback: () {
        setState(() {
          for (int i = 0; i < originalRow.length && i < row.length; i++) {
            row[i] = originalRow[i];
          }
        });
      },
      successMessage: 'Billed order updated',
      failureMessage: 'Failed to update billed order. Reverted.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      disableInternalScrolling: true,
      title: '📋 View Orders',
      subtitle: 'Browse, filter, and manage all orders in the system.',
      topActions: [
        // Cancel buttons shown directly when in a mode
        if (_isShareMode)
          _buildTopButton(
            label: '✖ Cancel Share',
            onPressed: () => setState(() {
              _isShareMode = false;
              _selectedOrderIds.clear();
            }),
            color: const Color(0xFFEF4444),
          )
        else if (_isAddToCartMode)
          _buildTopButton(
            label: '✖ Cancel Cart',
            onPressed: () => setState(() {
              _isAddToCartMode = false;
              _cartSelectedIds.clear();
              _cartOrderData.clear();
            }),
            color: const Color(0xFFEF4444),
          )
        else
          // 3-dot menu with all actions
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF475569), size: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              switch (value) {
                case 'dashboard':
                  if (Navigator.canPop(context)) {
                    Navigator.pop(context);
                  } else {
                    Navigator.pushReplacementNamed(context, '/');
                  }
                  break;
                case 'new_order':
                  Navigator.pushNamed(context, '/new_order');
                  break;
                case 'share_order':
                  setState(() {
                    _isShareMode = true;
                    _isAddToCartMode = false;
                    _cartSelectedIds.clear();
                    _cartOrderData.clear();
                  });
                  break;
                case 'manual_send':
                  _manualSendOrder();
                  break;
                case 'add_to_cart':
                  setState(() {
                    _isAddToCartMode = true;
                    _isShareMode = false;
                    _selectedOrderIds.clear();
                    _cartSelectedIds.clear();
                    _cartOrderData.clear();
                  });
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'dashboard',
                child: Row(
                  children: [
                    Icon(Icons.dashboard_rounded, color: Color(0xFF5D6E7E), size: 20),
                    SizedBox(width: 10),
                    Text('Dashboard', style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'new_order',
                child: Row(
                  children: [
                    Icon(Icons.add_circle_rounded, color: Color(0xFF22C55E), size: 20),
                    SizedBox(width: 10),
                    Text('New Order', style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'share_order',
                child: Row(
                  children: [
                    Icon(Icons.share_rounded, color: Color(0xFF25D366), size: 20),
                    SizedBox(width: 10),
                    Text('Share Order', style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'manual_send',
                child: Row(
                  children: [
                    Icon(Icons.send_rounded, color: Color(0xFF3B82F6), size: 20),
                    SizedBox(width: 10),
                    Text('Manual Send', style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              if (_isAdmin)
                const PopupMenuItem<String>(
                  value: 'add_to_cart',
                  child: Row(
                    children: [
                      Icon(Icons.add_shopping_cart, color: Color(0xFF10B981), size: 20),
                      SizedBox(width: 10),
                      Text('Add to Cart', style: TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
          ),
      ],
      // Floating Action Button - for Share mode or Add to Cart mode
      floatingActionButton: _isShareMode ? GestureDetector(
        onTap: _selectedOrderIds.isNotEmpty ? _shareSelectedOrders : null,
        child: Container(
          width: 64,
          height: 64,
          margin: const EdgeInsets.only(bottom: 60),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _selectedOrderIds.isNotEmpty
                  ? [const Color(0xFF25D366), const Color(0xFF128C7E)]
                  : [Colors.grey.shade400, Colors.grey.shade500],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _selectedOrderIds.isNotEmpty
                    ? const Color(0xFF25D366).withOpacity(0.5)
                    : Colors.grey.withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            children: [
              const Center(child: Icon(Icons.share_rounded, color: Colors.white, size: 28)),
              if (_selectedOrderIds.isNotEmpty)
                Positioned(
                  top: 2, right: 2,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                    child: Text('${_selectedOrderIds.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ) : _isAddToCartMode ? GestureDetector(
        onTap: _cartSelectedIds.isNotEmpty ? _submitCartOrders : null,
        child: Container(
          width: 64,
          height: 64,
          margin: const EdgeInsets.only(bottom: 60),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _cartSelectedIds.isNotEmpty
                  ? [const Color(0xFF10B981), const Color(0xFF059669)]
                  : [Colors.grey.shade400, Colors.grey.shade500],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _cartSelectedIds.isNotEmpty
                    ? const Color(0xFF10B981).withOpacity(0.5)
                    : Colors.grey.withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            children: [
              const Center(child: Icon(Icons.shopping_cart_rounded, color: Colors.white, size: 28)),
              if (_cartSelectedIds.isNotEmpty)
                Positioned(
                  top: 2, right: 2,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                    child: Text('${_cartSelectedIds.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ) : null,
      content: Column(
        children: [
          if (_isFromCache)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: CachedDataChip(ageString: _cacheAge),
            ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                _isShareMode ? '📤 Select Orders to Share' : _isAddToCartMode ? '🛒 Select Orders for Cart' : '📋 Grouped Orders View',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF222222)),
              ),
            ),
          ),
          if (_isShareMode)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF25D366).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF25D366).withOpacity(0.3)),
              ),
              child: Text(
                '${_selectedOrderIds.length} order(s) selected',
                style: const TextStyle(color: Color(0xFF25D366), fontWeight: FontWeight.bold),
              ),
            ),
          if (_isAddToCartMode)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
              ),
              child: Text(
                '${_cartSelectedIds.length} order(s) selected for cart  •  Tap ✂️ for partial, ☑️ to select',
                style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          _buildFilters(),
          const SizedBox(height: 24),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : Container(
                    decoration: AppTheme.glassDecoration,
                    padding: const EdgeInsets.all(20),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        children: [
                          _buildOrderList(),
                          if (_isShareMode || _isAddToCartMode) const SizedBox(height: 80),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopButton({required String label, required VoidCallback onPressed, required Color color}) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.5),
            offset: const Offset(0, 4),
            blurRadius: 12,
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildFilters() {
    return Column(
      children: [
        // Row 1: Billing + Status (same style as Sales Summary)
        Row(
          children: [
            Expanded(
              child: _buildDropdownFilterWithValue(
                'Billing', _billingFilter.isEmpty ? 'All' : _billingFilter,
                ['All', 'SYGT', 'ESPL'],
                (val) {
                  _billingFilter = (val == 'All') ? '' : (val ?? '');
                  _loadOrders();
                },
                isMobile: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildDropdownFilterWithValue(
                'Status', _statusFilter,
                ['All', 'Pending', 'On Progress', 'Billed'],
                (val) {
                  _statusFilter = val ?? 'All';
                  _loadOrders();
                },
                isMobile: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Row 2: Grade + Client (same style as Sales Summary)
        Row(
          children: [
            Expanded(
              child: SearchableGradeDropdown(
                grades: (_dropdownOptions['grade'] as List?)?.cast<String>() ?? [],
                value: _gradeFilter.isEmpty ? null : _gradeFilter,
                onChanged: (val) {
                  _gradeFilter = val ?? '';
                  _loadOrders();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SearchableClientDropdown(
                clients: _searchSuggestions,
                value: _searchQuery.isEmpty ? null : _searchQuery,
                showAllOption: true,
                hintText: 'Search client...',
                onChanged: (val) {
                  _searchQuery = val ?? '';
                  _loadOrders();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Row 3: Date range filter
        _buildDateRangeFilter(),
      ],
    );
  }

  Widget _buildDateRangeFilter() {
    final hasDateFilter = _filterStartDate != null && _filterEndDate != null;
    final dateFormat = DateFormat('dd MMM');
    return InkWell(
      onTap: _showDateRangePicker,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: hasDateFilter ? AppTheme.primary.withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hasDateFilter ? AppTheme.primary : const Color(0xFFCCCCCC),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.date_range_rounded,
              size: 18,
              color: hasDateFilter ? AppTheme.primary : Colors.grey,
            ),
            const SizedBox(width: 8),
            Text(
              hasDateFilter
                  ? '${dateFormat.format(_filterStartDate!)} - ${dateFormat.format(_filterEndDate!)}'
                  : 'Date Range',
              style: TextStyle(
                fontSize: 13,
                color: hasDateFilter ? AppTheme.primary : Colors.grey[700],
                fontWeight: hasDateFilter ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            if (hasDateFilter) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _filterStartDate = null;
                    _filterEndDate = null;
                  });
                },
                child: Icon(Icons.close, size: 16, color: AppTheme.primary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showDateRangePicker() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: (_filterStartDate != null && _filterEndDate != null)
          ? DateTimeRange(start: _filterStartDate!, end: _filterEndDate!)
          : DateTimeRange(start: now.subtract(const Duration(days: 30)), end: now),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppTheme.primary,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _filterStartDate = picked.start;
        _filterEndDate = picked.end;
      });
    }
  }

  Widget _buildDropdownFilterWithValue(String hint, String? value, List<String> items, Function(String?) onChanged, {bool isMobile = false}) {
    return SizedBox(
      width: double.infinity,
      child: DropdownButtonFormField<String>(
        value: (value != null && value.isNotEmpty) ? value : null,
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          isDense: isMobile,
          contentPadding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 14, vertical: isMobile ? 8 : 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
        ),
        style: TextStyle(fontSize: isMobile ? 13 : 14, color: Colors.black),
        borderRadius: BorderRadius.circular(20),
        hint: Text(hint, style: TextStyle(fontSize: isMobile ? 13 : 14)),
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildOrderList() {
    // Data is already filtered server-side — render _ordersData directly.
    // No client-side flatten/filter/regroup needed.
    final dates = _ordersData.keys.toList();
    if (dates.isEmpty) return const Center(child: Text('No orders found.'));

    // Sort dates by parsed dd/mm/yy
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

    // Apply date range filter (client-side)
    if (_filterStartDate != null && _filterEndDate != null) {
      final startDay = DateTime(_filterStartDate!.year, _filterStartDate!.month, _filterStartDate!.day);
      final endDay = DateTime(_filterEndDate!.year, _filterEndDate!.month, _filterEndDate!.day);
      dates.removeWhere((dateStr) {
        final parsed = parseOrderDate(dateStr);
        if (parsed == null) return false; // keep unparseable dates
        return parsed.isBefore(startDay) || parsed.isAfter(endDay);
      });
      if (dates.isEmpty) return const Center(child: Text('No orders found for selected date range.'));
    }

    final status = _statusFilter.toLowerCase();
    if (status == 'pending' || status == 'on progress') {
      dates.sort((a, b) {
        final dateA = parseOrderDate(a);
        final dateB = parseOrderDate(b);
        if (dateA == null && dateB == null) return a.compareTo(b);
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateA.compareTo(dateB); // Oldest first
      });
    } else {
      dates.sort((a, b) {
        final dateA = parseOrderDate(a);
        final dateB = parseOrderDate(b);
        if (dateA == null && dateB == null) return b.compareTo(a);
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateB.compareTo(dateA); // Newest first
      });
    }

    List<Widget> children = [];
    for (var date in dates) {
      final clientsRaw = _ordersData[date];
      if (clientsRaw is! Map) continue;
      final clientsMap = clientsRaw as Map<String, dynamic>;
      List<Widget> clientWidgets = [];

      for (var clientName in clientsMap.keys.toList()..sort()) {
        final rawRows = clientsMap[clientName];
        if (rawRows is! List || rawRows.isEmpty) continue;
        final rows = rawRows;
        if (rows.isNotEmpty) {
          clientWidgets.add(Padding(
            padding: const EdgeInsets.only(left: 16.0, top: 16.0, bottom: 8.0),
            child: Text('👤 $clientName', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ));
          clientWidgets.addAll(rows.map((row) {
                // Extract Firestore document ID from last element (may have '-' prefix for order book entries)
                final rawId = row[row.length - 1].toString();
                final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;
                // Create unique key for selection: date|client|docId
                final orderId = '$date|$clientName|$docId';
                final statusText = '${row[10]}'.toLowerCase();
                final isPending = statusText == 'pending';
                
                // Phase 3.5: Wrap with Slidable for swipe gestures
                return Slidable(
                  key: ValueKey(orderId),
                  enabled: !_isShareMode && !_isAddToCartMode,
                  // Swipe right: Add to Cart / Dispatch
                  startActionPane: ((isPending || _isSuperAdmin) && _isAdmin) ? ActionPane(
                    motion: const DrawerMotion(),
                    extentRatio: 0.25,
                    children: [
                      SlidableAction(
                        onPressed: (_) {
                          HapticFeedback.mediumImpact();
                          _dispatchOrder(row, docId);
                        },
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        icon: Icons.local_shipping_rounded,
                        label: 'Dispatch',
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                      ),
                    ],
                  ) : null,
                  // Swipe left: Delete / Cancel (only if user has delete access)
                  endActionPane: (_isAdmin || _canDeleteOrders) ? ActionPane(
                    motion: const DrawerMotion(),
                    extentRatio: 0.25,
                    children: [
                      SlidableAction(
                        onPressed: (_) {
                          HapticFeedback.mediumImpact();
                          _deleteOrder(docId, orderRow: row);
                        },
                        backgroundColor: const Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                        icon: Icons.delete_rounded,
                        label: 'Delete',
                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(16)),
                      ),
                    ],
                  ) : null,
                  child: _OrderLine(
                    row: row,
                    date: date,
                    clientName: clientName,
                    isAdmin: _isAdmin,
                    isSuperAdmin: _isSuperAdmin,
                    canEdit: _isAdmin || _canEditOrders,
                    canDelete: _isAdmin || _canDeleteOrders,
                    isShareMode: _isShareMode,
                    hasDispatchDoc: _orderDispatchDocMap.containsKey(docId),
                    onViewDispatchDoc: _orderDispatchDocMap.containsKey(docId)
                        ? () => Navigator.pushNamed(context, '/dispatch_documents')
                        : null,
                    isAddToCartMode: _isAddToCartMode && isPending,
                    isSelected: _isAddToCartMode ? _cartSelectedIds.contains(orderId) : _selectedOrderIds.contains(orderId),
                    onEdit: (_isAdmin || _canEditOrders) ? () => _openEditModal(row) : null,
                    onDelete: (_isAdmin || _canDeleteOrders) ? () => _deleteOrder(docId, orderRow: row) : null,
                    onEditPackedDate: _isSuperAdmin ? () => _editPackedDate(row) : null,
                    onEditBilledOrder: _isSuperAdmin ? () => _editBilledOrder(row) : null,
                    onPartialDispatch: (_isAddToCartMode && isPending) ? () => _showPartialDispatchModal(row, orderId) : null,
                    onSelectionChanged: (selected) {
                      setState(() {
                        if (_isAddToCartMode) {
                          if (selected) {
                            _cartSelectedIds.add(orderId);
                            // Store order data for bulk submit
                            _cartOrderData[orderId] = {
                              'orderDate': row[0] ?? '',
                              'billingFrom': row[1] ?? '',
                              'client': row[2] ?? '',
                              'lot': row[3] ?? '',
                              'grade': row[4] ?? '',
                              'bagbox': row[5] ?? '',
                              'no': row[6] ?? 0,
                              'kgs': row[7] ?? 0,
                              'price': row[8] ?? 0,
                              'brand': row[9] ?? '',
                              'notes': row.length > 11 ? (row[11] ?? '') : '',
                              'index': docId,
                            };
                          } else {
                            _cartSelectedIds.remove(orderId);
                            _cartOrderData.remove(orderId);
                          }
                        } else {
                          if (selected) {
                            _selectedOrderIds.add(orderId);
                          } else {
                            _selectedOrderIds.remove(orderId);
                          }
                        }
                      });
                    },
                  ),
                );
              }));
        }
      }

      if (clientWidgets.isNotEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 24.0, bottom: 8.0),
          child: Text('📅 $date', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ));
        children.addAll(clientWidgets);
      }
    }

    if (children.isEmpty) return const Center(child: Text('No orders found for this filter.'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
  
  /// Manual send - pick a client and open WhatsApp directly with order details
  Future<void> _manualSendOrder() async {
    // Collect all unique clients from current orders
    final Map<String, List<Map<String, dynamic>>> clientOrders = {};
    for (var date in _ordersData.keys) {
      final clients = _ordersData[date] is Map ? _ordersData[date] as Map<String, dynamic> : <String, dynamic>{};
      for (var clientName in clients.keys) {
        final rows = (clients[clientName] as List?) ?? [];
        for (var row in rows) {
          clientOrders.putIfAbsent(clientName, () => []).add({
            'orderDate': date,
            'billingFrom': '${row[1]}',
            'client': clientName,
            'lot': '${row[3]}',
            'grade': '${row[4]}',
            'bagbox': '${row[5]}',
            'no': '${row[6]}',
            'kgs': '${row[7]}',
            'price': '${row[8]}',
            'brand': '${row[9]}',
          });
        }
      }
    }

    if (clientOrders.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No orders to send'), backgroundColor: Color(0xFFEF4444)),
        );
      }
      return;
    }

    // Show bottom sheet to pick a client
    final selectedClient = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(children: [
                Icon(Icons.send_rounded, color: Color(0xFF3B82F6), size: 22),
                SizedBox(width: 8),
                Text('Manual Send — Select Client', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ]),
            ),
            const Divider(height: 1),
            ...clientOrders.keys.map((client) => ListTile(
              dense: true,
              leading: const Icon(Icons.person_outline, size: 20, color: Color(0xFF475569)),
              title: Text(client, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: Text('${clientOrders[client]!.length} order(s)', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.pop(ctx, client),
            )),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (selectedClient == null || !mounted) return;

    final orders = clientOrders[selectedClient]!;

    // Look up client phone
    String? clientPhone;
    try {
      final contactResp = await _apiService.getClientContact(selectedClient);
      final contact = contactResp.data['contact'];
      if (contact != null) {
        if (contact['phones'] is List && (contact['phones'] as List).isNotEmpty) {
          clientPhone = (contact['phones'] as List).first.toString().trim();
        } else if (contact['phone'] != null) {
          clientPhone = contact['phone'].toString().trim();
        }
      }
    } catch (_) {}

    // Build order summary text
    final billingFrom = (orders.first['billingFrom'] ?? 'SYGT').toString().toUpperCase();
    final companyName = billingFrom == 'ESPL' ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';
    final orderDate = orders.first['orderDate'] ?? '';
    final lines = orders.map((o) =>
      '${o['lot']}: ${o['grade']} - ${o['no']} ${o['bagbox']} - ${o['kgs']}kg × ₹${o['price']}${o['brand'] != null && o['brand'].toString().isNotEmpty ? ' (${o['brand']})' : ''}'
    ).join('\n');
    final message = '📋 *$companyName*\n👤 $selectedClient | 📅 $orderDate\n\n$lines';

    if (clientPhone != null && clientPhone.isNotEmpty) {
      // Clean phone number
      var phone = clientPhone.replaceAll(RegExp(r'[^\d]'), '');
      if (phone.length == 10) phone = '91$phone';

      await WhatsAppService.openChat(phone: phone, message: message);
    } else {
      // No phone — use share sheet
      await Share.share(message, subject: 'Order for $selectedClient');
    }
  }

  /// Share selected orders - creates preview and share
  Future<void> _shareSelectedOrders() async {
    if (_selectedOrderIds.isEmpty) return;
    
    // Build list of selected orders with their data
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
            selectedOrders.add({
              'orderDate': date,
              'billingFrom': '${row[1]}',
              'client': clientName,
              'lot': '${row[3]}',
              'grade': '${row[4]}',
              'bagbox': '${row[5]}',
              'no': '${row[6]}',
              'kgs': '${row[7]}',
              'price': '${row[8]}',
              'brand': '${row[9]}',
              'status': '${row[10]}',
              'notes': row.length > 11 && row[11] != null && row[11] is! int && row[11] is! double ? '${row[11]}' : '',
            });
          }
        }
      }
    }
    
    if (selectedOrders.isEmpty) return;
    
    // Show preview dialog
    await _showSharePreview(selectedOrders);
  }
  
  /// Shows preview dialog with order card and share button
  Future<void> _showSharePreview(List<Map<String, dynamic>> orders) async {
    final GlobalKey repaintKey = GlobalKey();
    
    Widget buildOrderCard() {
      // Group by client → then by date
      final Map<String, Map<String, List<Map<String, dynamic>>>> byClientByDate = {};
      for (var order in orders) {
        final client = order['client'] ?? 'Unknown';
        final date = order['orderDate'] ?? 'Unknown';
        byClientByDate.putIfAbsent(client, () => {});
        byClientByDate[client]!.putIfAbsent(date, () => []).add(order);
      }

      // Determine company name based on billingFrom
      final billingFrom = orders.first['billingFrom'] ?? 'SYGT';
      final isESPL = billingFrom.toString().toUpperCase() == 'ESPL';
      final companyName = isESPL ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';

      // Determine heading based on statuses
      final allStatuses = orders.map((o) => (o['status'] ?? '').toString().toLowerCase()).toSet();
      final allPending = allStatuses.every((s) => s == 'pending' || s == 'on progress');
      final headingText = allPending
          ? 'Green Cardamom - Pending Orders'
          : 'Green Cardamom - Order Summary';

      // Collect unique dates for the date range display
      final uniqueDates = orders.map((o) => o['orderDate'] ?? '').toSet().where((d) => d.isNotEmpty).toList();
      uniqueDates.sort();
      final dateRangeText = uniqueDates.length == 1
          ? uniqueDates.first
          : '${uniqueDates.first} - ${uniqueDates.last}';

      return RepaintBoundary(
        key: repaintKey,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF8FAFC), Color(0xFFEFF6FF)],
              ),
              borderRadius: BorderRadius.circular(20),
              border: const Border(
                left: BorderSide(color: Color(0xFF1E40AF), width: 5),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Blue top banner with title
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF1E40AF), Color(0xFF3B82F6)],
                    ),
                  ),
                  child: Text(
                    headingText,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                  ),
                ),
                // Card content
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Company Logo + Name + Date Range
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
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.calendar_today, color: Color(0xFF64748B), size: 14),
                              const SizedBox(width: 4),
                              Text(
                                dateRangeText,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Client header(s) → Date sub-headers → Orders
                      ...byClientByDate.entries.map((clientEntry) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.person, color: Color(0xFF64748B), size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  clientEntry.key,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Date sections under this client
                          ...clientEntry.value.entries.map((dateEntry) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Date sub-header
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    const Icon(Icons.calendar_today, color: Color(0xFF3B82F6), size: 13),
                                    const SizedBox(width: 6),
                                    Text(
                                      dateEntry.key,
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF3B82F6)),
                                    ),
                                  ],
                                ),
                              ),
                              ...dateEntry.value.map((order) => Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: const Border(
                                    left: BorderSide(color: Color(0xFF3B82F6), width: 3),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.04),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
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
                                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF334155)),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF3B82F6),
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
                          )).toList(),
                          const SizedBox(height: 8),
                        ],
              )).toList(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
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
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFF0F172A),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Row(
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
                          await _captureAndPrintOrders(orders);
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
                          await _captureAndShareOrders(orders);
                        },
                        icon: const Icon(Icons.share_rounded, size: 20),
                        label: const Text('Share', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
  Widget _buildShareCardWidget(List<Map<String, dynamic>> orders, Map<String, List<Map<String, dynamic>>> byClient, String companyName, {required bool isESPL}) {
    // Re-group by client → then by date for proper date separation
    final Map<String, Map<String, List<Map<String, dynamic>>>> byClientByDate = {};
    for (var order in orders) {
      final client = order['client'] ?? 'Unknown';
      final date = order['orderDate'] ?? 'Unknown';
      byClientByDate.putIfAbsent(client, () => {});
      byClientByDate[client]!.putIfAbsent(date, () => []).add(order);
    }

    // Determine heading based on statuses
    final allStatuses = orders.map((o) => (o['status'] ?? '').toString().toLowerCase()).toSet();
    final allPending = allStatuses.every((s) => s == 'pending' || s == 'on progress');
    final headingText = allPending
        ? 'Green Cardamom - Pending Orders'
        : 'Green Cardamom - Order Summary';

    // Collect unique dates for the date range display
    final uniqueDates = orders.map((o) => o['orderDate'] ?? '').toSet().where((d) => d.isNotEmpty).toList();
    uniqueDates.sort();
    final dateRangeText = uniqueDates.length == 1
        ? uniqueDates.first
        : '${uniqueDates.first} - ${uniqueDates.last}';

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
            border: const Border(
              left: BorderSide(color: Color(0xFF1E40AF), width: 5),
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
                  gradient: LinearGradient(colors: [Color(0xFF1E40AF), Color(0xFF3B82F6)]),
                ),
                child: Text(
                  headingText,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 0.3),
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
                          child: Image.asset(isESPL ? 'assets/emperor_logo.jpg' : 'assets/yoga_logo.png', width: 44, height: 44, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(companyName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.calendar_today, color: Color(0xFF64748B), size: 16),
                            const SizedBox(width: 4),
                            Text(
                              dateRangeText,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // Client header(s) → Date sub-headers → Orders
                    ...byClientByDate.entries.map((clientEntry) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.person, color: Color(0xFF64748B), size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(clientEntry.key, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)), overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Date sections under this client
                        ...clientEntry.value.entries.map((dateEntry) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Date sub-header
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.calendar_today, color: Color(0xFF3B82F6), size: 14),
                                  const SizedBox(width: 6),
                                  Text(
                                    dateEntry.key,
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF3B82F6)),
                                  ),
                                ],
                              ),
                            ),
                            ...dateEntry.value.map((order) => Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
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
                            )).toList(),
                          ],
                        )).toList(),
                        const SizedBox(height: 8),
                      ],
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

  /// Captures order card as image and prints via AirPrint
  Future<void> _captureAndPrintOrders(List<Map<String, dynamic>> orders) async {
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
      // Build the same card widget used for sharing
      final Map<String, List<Map<String, dynamic>>> byClient = {};
      for (var order in orders) {
        final client = order['client'] ?? 'Unknown';
        byClient.putIfAbsent(client, () => []).add(order);
      }

      final billingFrom = orders.first['billingFrom'] ?? 'SYGT';
      final isESPL = billingFrom.toString().toUpperCase() == 'ESPL';
      final companyName = isESPL ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';

      final cardWidget = _buildShareCardWidget(orders, byClient, companyName, isESPL: isESPL);

      final overlayState = Overlay.of(context);
      late OverlayEntry overlayEntry;
      final repaintKey = GlobalKey();

      overlayEntry = OverlayEntry(
        builder: (context) => Positioned(
          left: -1000,
          top: -1000,
          child: RepaintBoundary(
            key: repaintKey,
            child: cardWidget,
          ),
        ),
      );

      overlayState.insert(overlayEntry);
      await Future.delayed(const Duration(milliseconds: 300));

      final RenderRepaintBoundary boundary = repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
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

      await Printing.layoutPdf(
        onLayout: (_) async => pdfBytes,
        name: 'Order_${orders.first['client']}_${DateTime.now().millisecondsSinceEpoch}',
      );

      // Exit share mode
      if (mounted) {
        setState(() {
          _isShareMode = false;
          _selectedOrderIds.clear();
        });
      }
    } catch (e) {
      closeLoading();
      debugPrint('Error printing orders: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error printing: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  /// Captures order card as image and shares
  Future<void> _captureAndShareOrders(List<Map<String, dynamic>> orders) async {
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
      // Group by client for the card
      final Map<String, List<Map<String, dynamic>>> byClient = {};
      for (var order in orders) {
        final client = order['client'] ?? 'Unknown';
        byClient.putIfAbsent(client, () => []).add(order);
      }

      // Determine company name based on billingFrom
      final billingFrom = orders.first['billingFrom'] ?? 'SYGT';
      final isESPL = billingFrom.toString().toUpperCase() == 'ESPL';
      final companyName = isESPL ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';

      final cardWidget = _buildShareCardWidget(orders, byClient, companyName, isESPL: isESPL);

      final overlayState = Overlay.of(context);
      late OverlayEntry overlayEntry;
      final repaintKey = GlobalKey();
      
      overlayEntry = OverlayEntry(
        builder: (context) => Positioned(
          left: -1000,
          top: -1000,
          child: RepaintBoundary(
            key: repaintKey,
            child: cardWidget,
          ),
        ),
      );
      
      overlayState.insert(overlayEntry);
      await Future.delayed(const Duration(milliseconds: 300));
      
      final RenderRepaintBoundary boundary = repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      final Uint8List pngBytes = byteData!.buffer.asUint8List();
      
      overlayEntry.remove();
      
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/order_share_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(pngBytes);
      
      closeLoading();
      
      // Exit share mode
      setState(() {
        _isShareMode = false;
        _selectedOrderIds.clear();
      });
      
      // Get screen size for sharePositionOrigin (required on iOS/iPad)
      final box = context.findRenderObject() as RenderBox?;
      final sharePositionOrigin = box != null
          ? box.localToGlobal(Offset.zero) & box.size
          : const Rect.fromLTWH(0, 0, 100, 100);
      
      final clientName = orders.first['client']?.toString() ?? '';

      // Try WhatsApp Cloud API first (auto-send via approved template)
      bool sentViaApi = false;
      List<String> clientPhones = [];
      try {
        final contactResp = await _apiService.getClientContact(clientName);
        final contact = contactResp.data['contact'];
        if (contact != null) {
          if (contact['phones'] is List && (contact['phones'] as List).isNotEmpty) {
            clientPhones = (contact['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
          } else if (contact['phone'] != null && contact['phone'].toString().trim().isNotEmpty) {
            clientPhones = [contact['phone'].toString().trim()];
          }
        }
        if (clientPhones.isNotEmpty) {
          final base64Image = base64Encode(pngBytes);
          final apiResp = await _apiService.sendWhatsAppImage(
            imageBase64: base64Image,
            phones: clientPhones,
            caption: '*Green Cardamom - Order details* for *$clientName* from $companyName.',
            clientName: clientName,
            operationType: 'share_orders',
            companyName: companyName,
          );
          if (apiResp.data['success'] == true) {
            sentViaApi = true;
            final sentCount = apiResp.data['sentCount'] ?? clientPhones.length;
            final totalCount = apiResp.data['totalCount'] ?? clientPhones.length;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Sent to $sentCount of $totalCount number${totalCount > 1 ? 's' : ''} via WhatsApp!'),
                  backgroundColor: const Color(0xFF2E7D32),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          }
        }
      } catch (apiErr) {
        debugPrint('WhatsApp API failed, falling back: $apiErr');
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
          await Share.shareXFiles(
            [XFile(file.path)],
            text: '*Green cardamom - Order Confirmation for $clientName*',
            sharePositionOrigin: sharePositionOrigin,
          );
        }
      }
    } catch (e) {
      closeLoading();
      debugPrint('Error sharing orders: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sharing: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }
}

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
  final VoidCallback? onEditPackedDate;
  final VoidCallback? onEditBilledOrder;
  final VoidCallback? onPartialDispatch;
  final Function(bool) onSelectionChanged;
  final bool hasDispatchDoc;
  final VoidCallback? onViewDispatchDoc;

  const _OrderLine({
    required this.row,
    required this.date,
    required this.clientName,
    required this.isAdmin,
    this.isSuperAdmin = false,
    this.canEdit = true,
    this.canDelete = true,
    required this.isShareMode,
    this.isAddToCartMode = false,
    required this.isSelected,
    this.onEdit,
    this.onDelete,
    this.onEditPackedDate,
    this.onEditBilledOrder,
    this.onPartialDispatch,
    required this.onSelectionChanged,
    this.hasDispatchDoc = false,
    this.onViewDispatchDoc,
  });

  @override
  State<_OrderLine> createState() => _OrderLineState();
}

class _OrderLineState extends State<_OrderLine> with SingleTickerProviderStateMixin {
  AnimationController? _pulseController;
  Animation<double>? _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _setupAnimation();
  }

  @override
  void didUpdateWidget(covariant _OrderLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date != widget.date) {
      _setupAnimation();
    }
  }

  void _setupAnimation() {
    final ageInfo = _getOrderAgeInfo();
    final ageDays = (ageInfo['days'] as int?) ?? 0;
    final isRed = ageDays > 10;

    if (isRed && _pulseController == null) {
      _pulseController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1800),
      );
      _pulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _pulseController!, curve: Curves.easeInOut),
      );
      _pulseController!.repeat(reverse: true);
    } else if (!isRed && _pulseController != null) {
      _pulseController!.dispose();
      _pulseController = null;
      _pulseAnimation = null;
    }
  }

  @override
  void dispose() {
    _pulseController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final row = widget.row;
        final brand = (row.length > 9 && row[9] != null) ? '${row[9]}' : null;
        final notes = (row.length > 11 && row[11] != null && row[11] is! int && row[11] is! double && '${row[11]}'.trim().isNotEmpty) ? '${row[11]}' : null;
        final price = row.length > 8 ? double.tryParse('${row[8]}') ?? 0.0 : 0.0;

        // Calculate order age for flagging
        final ageInfo = _getOrderAgeInfo();
        final ageColor = ageInfo['color'] as Color;
        final ageDays = (ageInfo['days'] as int?) ?? 0;
        final isRed = ageDays > 10;

        final isBilled = '${row[10]}'.toLowerCase() == 'billed';

        final isAnySelectMode = widget.isShareMode || widget.isAddToCartMode;
        final isCartSelected = widget.isAddToCartMode && widget.isSelected;

        // Determine border color: selection modes override age color
        Color borderColor;
        double borderWidth;
        if (widget.isShareMode && widget.isSelected) {
          borderColor = const Color(0xFF25D366);
          borderWidth = 2.0;
        } else if (isCartSelected) {
          borderColor = const Color(0xFF10B981);
          borderWidth = 2.0;
        } else if (isBilled) {
          borderColor = const Color(0xFFCBD5E1);
          borderWidth = 1.0;
        } else {
          borderColor = ageColor;
          borderWidth = 2.0;
        }

        // Shared inner content
        final innerContent = _buildCardContent(isMobile, row, brand, notes, price, ageColor, ageDays, isBilled, isCartSelected);

        // Build card: pulsing for red non-billed orders, static otherwise
        Widget cardWidget;
        if (isRed && !isBilled && _pulseAnimation != null) {
          cardWidget = AnimatedBuilder(
            animation: _pulseAnimation!,
            builder: (context, child) {
              final pulseValue = _pulseAnimation!.value;
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: ageColor,
                    width: 2.0 + pulseValue * 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2)),
                  ],
                ),
                child: child,
              );
            },
            child: Padding(padding: const EdgeInsets.all(12), child: innerContent),
          );
        } else {
          cardWidget = Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            decoration: BoxDecoration(
              color: widget.isShareMode && widget.isSelected
                  ? const Color(0xFF25D366).withOpacity(0.08)
                  : isCartSelected
                      ? const Color(0xFF10B981).withOpacity(0.08)
                      : isBilled ? const Color(0xFFF8F9FA) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor, width: borderWidth),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2)),
              ],
            ),
            child: Padding(padding: const EdgeInsets.all(12), child: innerContent),
          );
        }

        return GestureDetector(
          onTap: isAnySelectMode
              ? () => widget.onSelectionChanged(!widget.isSelected)
              : () => _showOrderDetailPopup(context, row, brand, notes, price, ageColor, ageDays, isBilled),
          child: Stack(
            children: [
              cardWidget,
              // Diagonal "BILLED" stamp overlay for billed orders
              if (isBilled)
                Positioned.fill(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: IgnorePointer(
                        child: Center(
                          child: Transform.rotate(
                            angle: -0.35,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                              decoration: BoxDecoration(
                                border: Border.all(color: const Color(0xFF4A5568).withOpacity(0.35), width: 2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'BILLED',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  color: const Color(0xFF4A5568).withOpacity(0.18),
                                  letterSpacing: 6,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // Dispatch document icon for billed orders with linked docs
              if (isBilled && widget.hasDispatchDoc)
                Positioned(
                  top: 8,
                  right: 16,
                  child: GestureDetector(
                    onTap: widget.onViewDispatchDoc,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.description_rounded, size: 16, color: Color(0xFF10B981)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Build the inner card content (shared between static and pulsing cards)
  Widget _buildCardContent(bool isMobile, List<dynamic> row, String? brand, String? notes, double price, Color ageColor, int ageDays, bool isBilled, bool isCartSelected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // DEBUG: Show raw row[2] client name on each card
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (widget.isShareMode) _buildSelectionCheckbox(),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${row[3]}: ${row[4]} - ${row[6]} ${row[5]}',
                      style: TextStyle(fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.w900, color: const Color(0xFF1E293B)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: ageColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: ageColor.withOpacity(0.3)),
                    ),
                    child: Text('${ageDays}d', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: ageColor)),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${row[7]} kgs ${price > 0 ? "x ₹${price.toInt()}" : ""}',
                    style: TextStyle(fontSize: isMobile ? 11 : 12, fontWeight: FontWeight.w700, color: const Color(0xFF475569)),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (brand != null && brand != 'N/A' && brand.isNotEmpty) ...[
              Text('- $brand', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primary)),
              const SizedBox(width: 8),
            ],
            if (notes != null) ...[
              const Icon(Icons.notes_rounded, size: 14, color: Color(0xFF94A3B8)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(notes, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontStyle: FontStyle.italic, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
            ] else
              const Spacer(),
            _buildStatusBadge('${row[10]}'),
          ],
        ),
        if (!widget.isShareMode && !widget.isAddToCartMode && isBilled && widget.isSuperAdmin && widget.onEditBilledOrder != null) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Packed: ${row.length > 13 && row[13] != null && '${row[13]}'.isNotEmpty ? row[13] : '—'}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
              ),
              Row(
                children: [
                  _buildRowButton('Edit', const Color(0xFF3B82F6), widget.onEditBilledOrder!, icon: Icons.edit_rounded),
                  if (widget.onDelete != null) ...[
                    const SizedBox(width: 8),
                    _buildRowButton('Delete', const Color(0xFFEF4444), widget.onDelete!, icon: Icons.delete_outline_rounded),
                  ],
                ],
              ),
            ],
          ),
        ] else if (widget.isAddToCartMode) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onPartialDispatch != null)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(Icons.content_cut, color: const Color(0xFFF59E0B), size: isMobile ? 18 : 20),
                  onPressed: widget.onPartialDispatch,
                  tooltip: 'Partial Dispatch',
                ),
              SizedBox(width: isMobile ? 8 : 12),
              GestureDetector(
                onTap: () => widget.onSelectionChanged(!widget.isSelected),
                child: Container(
                  width: isMobile ? 22 : 26,
                  height: isMobile ? 22 : 26,
                  decoration: BoxDecoration(
                    color: widget.isSelected ? const Color(0xFF10B981) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: widget.isSelected ? const Color(0xFF10B981) : const Color(0xFFCBD5E1), width: 1.5),
                  ),
                  child: widget.isSelected ? Icon(Icons.check, size: isMobile ? 14 : 18, color: Colors.white) : null,
                ),
              ),
            ],
          ),
        ] else if (!widget.isShareMode && (!isBilled || widget.isSuperAdmin) && (widget.canEdit || widget.canDelete)) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onEdit != null) _buildRowButton('Edit', const Color(0xFF475569), widget.onEdit!, icon: Icons.edit_note_rounded),
              if (widget.onEdit != null && widget.onDelete != null) const SizedBox(width: 8),
              if (widget.onDelete != null) _buildRowButton('Delete', const Color(0xFFEF4444), widget.onDelete!, icon: Icons.delete_outline_rounded),
            ],
          ),
        ],
      ],
    );
  }

  /// Get order age info with color based on days since order date
  Map<String, dynamic> _getOrderAgeInfo() {
    try {
      // Parse date in dd/MM/yy format
      final parts = widget.date.split('/');
      if (parts.length == 3) {
        final day = int.parse(parts[0]);
        final month = int.parse(parts[1]);
        var year = int.parse(parts[2]);
        // Handle 2-digit year
        if (year < 100) year += 2000;

        final orderDate = DateTime(year, month, day);
        final now = DateTime.now();
        final days = now.difference(orderDate).inDays;

        Color color;
        if (days > 10) {
          color = const Color(0xFFEF4444); // Red
        } else if (days >= 5) {
          color = const Color(0xFFF59E0B); // Orange
        } else {
          color = const Color(0xFF10B981); // Green
        }

        return {'days': days, 'color': color};
      }
    } catch (e) {
      // Fallback
    }
    return {'days': 0, 'color': const Color(0xFF94A3B8)};
  }

  /// Show order detail popup on card tap
  void _showOrderDetailPopup(BuildContext context, List<dynamic> row, String? brand, String? notes, double price, Color ageColor, int ageDays, bool isBilled) {
    final lot = '${row[3]}';
    final grade = '${row[4]}';
    final bags = '${row[6]} ${row[5]}';
    final kgs = '${row[7]}';
    final status = '${row[10]}';
    final billing = '${row[1]}';
    final packedDate = row.length > 13 && row[13] != null && '${row[13]}'.isNotEmpty ? '${row[13]}' : null;

    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: Client + Close
                Row(
                  children: [
                    Container(
                      width: 5, height: 32,
                      decoration: BoxDecoration(color: ageColor, borderRadius: BorderRadius.circular(3)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(widget.clientName,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 22),
                    ),
                  ],
                ),
                const Divider(height: 20),
                // Detail rows
                _popupRow('Date', widget.date),
                _popupRow('Lot', lot),
                _popupRow('Grade', grade),
                _popupRow('Quantity', '$bags  •  $kgs kgs'),
                if (price > 0) _popupRow('Price', '₹${price.toInt()} / kg'),
                if (brand != null && brand.isNotEmpty && brand != 'N/A') _popupRow('Brand', brand),
                if (notes != null && notes.isNotEmpty) _popupRow('Notes', notes),
                _popupRow('Status', status),
                if (billing.isNotEmpty) _popupRow('Billing', billing),
                if (packedDate != null) _popupRow('Packed', packedDate),
                const SizedBox(height: 8),
                // Age badge
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: ageColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ageColor.withOpacity(0.3)),
                    ),
                    child: Text('${ageDays} days old',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ageColor)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _popupRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8))),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionCheckbox() {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Container(
        width: 18, height: 18,
        decoration: BoxDecoration(
          color: widget.isSelected ? const Color(0xFF25D366) : Colors.white,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: widget.isSelected ? const Color(0xFF25D366) : const Color(0xFFCBD5E1), width: 1.2),
        ),
        child: widget.isSelected ? const Icon(Icons.check, color: Colors.white, size: 14) : null,
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    final color = _getStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.3),
      ),
    );
  }

  Widget _buildRowButton(String label, Color color, VoidCallback onPressed, {required IconData icon}) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
      ),
    );
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
}

class _OrderEditDialog extends StatefulWidget {
  final List<dynamic> row;
  final Map<String, dynamic> dropdownOptions;
  final bool isAdmin;
  final bool isBilledOrder;

  const _OrderEditDialog({
    required this.row,
    required this.dropdownOptions,
    required this.isAdmin,
    this.isBilledOrder = false,
  });

  @override
  State<_OrderEditDialog> createState() => _OrderEditDialogState();
}

class _OrderEditDialogState extends State<_OrderEditDialog> {
  late TextEditingController _lotController;
  late TextEditingController _noController;
  late TextEditingController _kgsController;
  late TextEditingController _priceController;
  late TextEditingController _notesController;

  late String _grade;
  late String _bagbox;
  late String _brand;
  late String _status;
  DateTime _packedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    final row = widget.row;
    _lotController = TextEditingController(text: '${row[3]}');
    _noController = TextEditingController(text: '${row[6]}');
    _kgsController = TextEditingController(text: '${row[7]}');
    _priceController = TextEditingController(text: '${row[8]}');
    // Row index is appended at the end, notes is at index 11 if present
    // Check that row[11] exists and is not an integer (which would be the row index)
    String notesValue = '';
    if (row.length > 11 && row[11] != null) {
      final rawNotes = row[11];
      // Only use it if it's not a number (row indices are numbers)
      if (rawNotes is! int && rawNotes is! double) {
        final strNotes = '$rawNotes'.trim();
        if (strNotes.isNotEmpty) {
          notesValue = strNotes;
        }
      }
    }
    _notesController = TextEditingController(text: notesValue);

    _grade = '${row[4]}';
    _bagbox = '${row[5]}';
    _brand = '${row[9]}';
    _status = '${row[10]}';

    if (widget.isBilledOrder && row.length > 13) {
      final pd = '${row[13]}';
      if (pd.isNotEmpty && pd != 'null') {
        try { _packedDate = DateFormat('dd/MM/yy').parse(pd); } catch (_) {}
      }
    }

    _noController.addListener(_updateKgs);
  }

  void _updateKgs() {
    final count = double.tryParse(_noController.text) ?? 0;
    int multiplier = 0;
    if (_bagbox.toLowerCase().contains('bag')) multiplier = 50;
    if (_bagbox.toLowerCase().contains('box')) multiplier = 20;

    if (multiplier > 0) {
      final kgs = count * multiplier;
      setState(() {
        _kgsController.text = kgs.toStringAsFixed(2).replaceFirst(RegExp(r'\.00$'), '');
      });
    }
  }

  @override
  void dispose() {
    _lotController.dispose();
    _noController.dispose();
    _kgsController.dispose();
    _priceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 40, vertical: 24),
      child: Container(
        width: isMobile ? MediaQuery.of(context).size.width : 500,
        decoration: AppTheme.glassDecoration.copyWith(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: EdgeInsets.all(isMobile ? 16 : 32),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('✏️ Edit Order', style: TextStyle(fontSize: isMobile ? 18 : 22, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
              SizedBox(height: isMobile ? 16 : 24),
              
              _buildField('Lot', _lotController, readOnly: true),  // Lot No is unchangeable
              
              if (isMobile) ...[
                _buildGradeGroupedDropdown('Grade', _grade, ((widget.dropdownOptions['grade'] as List?) ?? []).cast<String>(), (v) => setState(() => _grade = v!)),
                _buildDropdown('Bag/Box', _bagbox, ((widget.dropdownOptions['bagbox'] as List?) ?? []).cast<String>(), (v) => setState(() {
                  _bagbox = v!;
                  _updateKgs();
                })),
              ] else
                Row(
                  children: [
                    Expanded(child: _buildGradeGroupedDropdown('Grade', _grade, ((widget.dropdownOptions['grade'] as List?) ?? []).cast<String>(), (v) => setState(() => _grade = v!))),
                    const SizedBox(width: 16),
                    Expanded(child: _buildDropdown('Bag/Box', _bagbox, ((widget.dropdownOptions['bagbox'] as List?) ?? []).cast<String>(), (v) => setState(() {
                      _bagbox = v!;
                      _updateKgs();
                    }))),
                  ],
                ),

              if (isMobile) ...[
                _buildField('No.', _noController, isNumeric: true),
                _buildField('Kgs', _kgsController, isNumeric: true, readOnly: true),
              ] else
                Row(
                  children: [
                    Expanded(child: _buildField('No.', _noController, isNumeric: true)),
                    const SizedBox(width: 16),
                    Expanded(child: _buildField('Kgs', _kgsController, isNumeric: true, readOnly: true)),
                  ],
                ),

              if (isMobile) ...[
                _buildField('Price', _priceController, isNumeric: true),
                _buildDropdown('Brand', _brand, ((widget.dropdownOptions['brand'] as List?) ?? []).cast<String>(), (v) => setState(() => _brand = v!)),
              ] else
                Row(
                  children: [
                    Expanded(child: _buildField('Price', _priceController, isNumeric: true)),
                    const SizedBox(width: 16),
                    Expanded(child: _buildDropdown('Brand', _brand, ((widget.dropdownOptions['brand'] as List?) ?? []).cast<String>(), (v) => setState(() => _brand = v!))),
                  ],
                ),

              _buildDropdown('Status', _status, ['Pending', 'On Progress', 'Billed'], (v) => setState(() => _status = v!)),
              
              _buildField('Notes', _notesController, maxLines: 3),

              if (widget.isBilledOrder) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Packed Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _packedDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) setState(() => _packedDate = picked);
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                            color: Colors.white,
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.calendar_month_rounded, size: 18, color: Color(0xFF64748B)),
                              const SizedBox(width: 8),
                              Text(DateFormat('dd/MM/yy').format(_packedDate), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                              const Spacer(),
                              const Icon(Icons.arrow_drop_down, color: Color(0xFF94A3B8)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              SizedBox(height: isMobile ? 16 : 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B)))),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: () {
                      final updated = {
                        'orderDate': widget.row[0],
                        'billingFrom': widget.row[1],
                        'client': widget.row[2],
                        'lot': _lotController.text,
                        'grade': _grade,
                        'bagbox': _bagbox,
                        'no': double.tryParse(_noController.text) ?? 0,
                        'kgs': double.tryParse(_kgsController.text) ?? 0,
                        'price': double.tryParse(_priceController.text) ?? 0,
                        'brand': _brand,
                        'status': _status,
                        'notes': _notesController.text,
                        if (widget.isBilledOrder) 'packedDate': DateFormat('dd/MM/yy').format(_packedDate),
                      };
                      Navigator.pop(context, updated);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isAdmin ? const Color(0xFF3B82F6) : const Color(0xFFF59E0B),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: isMobile ? 20 : 32, vertical: isMobile ? 12 : 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                    child: Text(
                      widget.isAdmin ? 'Save Changes' : 'Submit for Approval',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: isMobile ? 13 : 14),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(String label, TextEditingController controller, {bool isNumeric = false, bool readOnly = false, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            keyboardType: isNumeric ? TextInputType.number : TextInputType.text,
            readOnly: readOnly,
            maxLines: maxLines,
            decoration: InputDecoration(
              filled: true,
              fillColor: readOnly ? const Color(0xFFF1F5F9) : Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown(String label, String value, List<String> items, Function(String?) onChanged) {
    if (!items.contains(value)) items = [value, ...items];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: value,
            borderRadius: BorderRadius.circular(20),
            items: items.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 14)))).toList(),
            onChanged: onChanged,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGradeGroupedDropdown(String label, String value, List<String> items, Function(String?) onChanged) {
    if (!items.contains(value)) items = [value, ...items];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
          const SizedBox(height: 6),
          GradeGroupedDropdown(
            value: value,
            grades: items,
            onChanged: onChanged,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
            ),
          ),
        ],
      ),
    );
  }
}

