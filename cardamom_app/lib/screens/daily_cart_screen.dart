import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/cache_manager.dart';
import '../services/navigation_service.dart';
import '../services/operation_queue.dart';
import '../mixins/optimistic_action_mixin.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../services/socket_service.dart';
import '../widgets/offline_indicator.dart';

class DailyCartScreen extends StatefulWidget {
  const DailyCartScreen({super.key});

  @override
  State<DailyCartScreen> createState() => _DailyCartScreenState();
}

class _DailyCartScreenState extends State<DailyCartScreen> with RouteAware, OptimisticActionMixin {
  final ApiService _apiService = ApiService();

  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();
  bool _isLoading = true;
  String _userRole = 'user';

  bool get _isAdmin {
    final role = _userRole.toLowerCase().trim();
    return role == 'superadmin' || role == 'admin' || role == 'ops';
  }
  List<dynamic> _cartItems = [];
  List<dynamic> _pendingOrders = [];
  String _billingFilter = '';
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<int> _selectedForCancel = {};
  bool _isFromCache = false;
  String _cacheAge = '';

  // Transport assignment per client — persisted via SharedPreferences keyed by date.
  final Map<String, String> _clientTransport = {};
  final List<String> _transportRemovals = []; // Track cleared transports for server sync
  List<String> _transportList = [];

  /// SharedPreferences key for today's transport assignments.
  String get _transportPrefsKey =>
      'daily_cart_transport_${DateFormat('yyyy-MM-dd').format(DateTime.now())}';

  @override
  void initState() {
    super.initState();
    _loadCart();
    _listenForTransportUpdates();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    SocketService().removeTransportUpdatedCallback(_onTransportUpdated);
    _searchController.dispose();
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  /// Listen for transport assignment changes made by other users via Socket.IO.
  void _listenForTransportUpdates() {
    SocketService().onTransportUpdated(_onTransportUpdated);
  }

  void _onTransportUpdated(Map<String, dynamic> data) {
    // Only reload if the update is for today's date
    final updatedDate = data['date']?.toString() ?? '';
    if (updatedDate == _todayDateStr && mounted) {
      debugPrint('[DailyCart] Transport updated by ${data['updatedBy']} — reloading assignments');
      _restoreTransportAssignments().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  bool _suppressDidPopNext = false;

  @override
  void didPopNext() {
    if (_suppressDidPopNext) {
      _suppressDidPopNext = false;
      return;
    }
    _loadCart();
  }

  Future<void> _loadCart() async {
    setState(() => _isLoading = true);
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';
      final cacheManager = context.read<CacheManager>();
      final result = await cacheManager.fetchWithCache<Map<String, dynamic>>(
        apiCall: () async {
          final responses = await Future.wait([
            _apiService.getTodayCart(),
            _apiService.getPendingOrders(),
          ]);
          return {
            'cart': responses[0].data ?? [],
            'pending': responses[1].data ?? [],
          };
        },
        cache: cacheManager.dailyCartCache,
      );
      if (!mounted) return;

      // Load transport list for dropdown (non-blocking)
      try {
        final transportResp = await _apiService.getDropdownCategory('transports');
        _transportList = List<String>.from(transportResp.data['items'] ?? []);
      } catch (e) {
        debugPrint('Error loading transports: $e');
      }

      // Restore persisted transport assignments for today
      await _restoreTransportAssignments();

      if (!mounted) return;
      setState(() {
        _cartItems = List<dynamic>.from(result.data['cart'] ?? []);
        _pendingOrders = List<dynamic>.from(result.data['pending'] ?? []);
        _isFromCache = result.fromCache;
        _cacheAge = result.ageString;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading daily cart: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  /// Today's date string used for API and SharedPreferences keys.
  String get _todayDateStr => DateFormat('yyyy-MM-dd').format(DateTime.now());

  /// Persist current transport assignments to backend AND local cache.
  Future<void> _saveTransportAssignments() async {
    // Save locally first (instant, works offline)
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_clientTransport.isEmpty) {
        await prefs.remove(_transportPrefsKey);
      } else {
        await prefs.setString(_transportPrefsKey, jsonEncode(_clientTransport));
      }
    } catch (_) {}
    // Save to backend (with removals) — await so we know it synced
    try {
      final removals = List<String>.from(_transportRemovals);
      await _apiService.saveTransportAssignments(
        _todayDateStr,
        Map<String, String>.from(_clientTransport),
        removals: removals,
      );
      // Only clear removals AFTER successful API call
      _transportRemovals.clear();
    } catch (e) {
      debugPrint('Error saving transport assignments to backend: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to sync transport: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Restore transport assignments — prefer backend (shared), fall back to local cache.
  Future<void> _restoreTransportAssignments() async {
    try {
      final resp = await _apiService.getTransportAssignments(_todayDateStr);
      if (resp.data['success'] == true && resp.data['assignments'] != null) {
        final serverMap = resp.data['assignments'] as Map;
        if (serverMap.isNotEmpty) {
          _clientTransport.clear();
          serverMap.forEach((k, v) => _clientTransport[k.toString()] = v.toString());
          // Update local cache with server data
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_transportPrefsKey, jsonEncode(_clientTransport));
          return;
        }
      }
    } catch (e) {
      debugPrint('Error loading transport assignments from backend: $e');
    }
    // Fallback to local cache
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_transportPrefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _clientTransport.clear();
          decoded.forEach((k, v) => _clientTransport[k.toString()] = v.toString());
        }
      }
    } catch (_) {}
  }



  Future<void> _archiveToPackedOrders() async {
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No orders to archive'), backgroundColor: Color(0xFFF59E0B)),
      );
      return;
    }

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _buildGlassDialog(
        title: '📦 End of Day Archive',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will move all ${_cartItems.length} order(s) from today\'s cart to the packed orders archive.',
              style: const TextStyle(fontSize: 14, color: Color(0xFF334155)),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.3)),
              ),
              child: Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This action cannot be undone. Orders will be removed from the daily cart.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF22C55E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text('Archive Orders', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final today = DateFormat('dd/MM/yy').format(DateTime.now());
    final archivedCount = _cartItems.length;

    fireAndForget(
      type: 'archive',
      apiCall: () => _apiService.archiveCartToPackedOrders(targetDate: today),
      successMessage: '$archivedCount order(s) archived',
      failureMessage: 'Archive failed. Please try again.',
      onSuccess: () {
        if (mounted) _loadCart();
      },
    );
  }

  void _removeFromCart(dynamic item, {int? itemIndex}) {
    final removedItem = Map<String, dynamic>.from(item);
    final originalIndex = _cartItems.indexOf(item);

    optimistic(
      type: 'delete',
      applyLocal: () => setState(() => _cartItems.remove(item)),
      apiCall: () => _apiService.removeFromCart(removedItem['lot'], removedItem['client'], removedItem['billingFrom'], docId: removedItem['id']?.toString()),
      rollback: () => setState(() => _cartItems.insert(originalIndex.clamp(0, _cartItems.length), removedItem)),
      successMessage: 'Order cancelled: ${removedItem['lot']} - ${removedItem['client']}',
      failureMessage: 'Cancellation failed. Order restored.',
      onSuccess: () {
        // Refresh pending orders in background
        _apiService.getPendingOrders().then((resp) {
          if (mounted) {
            setState(() => _pendingOrders = resp.data ?? []);
          }
        });
      },
    );
  }

  /// Check if error is quota/rate limit related (matching HTML/JS)
  bool _isQuotaError(dynamic error) {
    final errorMsg = error.toString().toLowerCase();
    return errorMsg.contains('quota') ||
           errorMsg.contains('rate limit') ||
           errorMsg.contains('too many requests') ||
           errorMsg.contains('429') ||
           errorMsg.contains('user-rate limit') ||
           errorMsg.contains('quotaexceeded');
  }

  void _showMultiCancelModal() {
    if (_cartItems.isEmpty) return;

    // Clear previous selections when opening dialog to prevent stale index references
    _selectedForCancel.clear();

    final filteredItems = _cartItems.where((item) {
      if (_billingFilter.isNotEmpty && item['billingFrom'] != _billingFilter) return false;
      return true;
    }).toList();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final items = filteredItems;
          return _buildGlassDialog(
            title: 'Multi-Cancel',
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          setModalState(() {
                            if (_selectedForCancel.length == items.length) {
                              _selectedForCancel.clear();
                            } else {
                              for (int i = 0; i < items.length; i++) {
                                _selectedForCancel.add(i);
                              }
                            }
                          });
                        },
                        child: Text(_selectedForCancel.length == items.length ? 'Deselect All' : 'Select All', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 400),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (ctx, i) {
                          final item = items[i];
                          final isSelected = _selectedForCancel.contains(i);
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFF5D6E7E).withOpacity(0.05) : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: isSelected ? const Color(0xFF5D6E7E).withOpacity(0.2) : Colors.transparent),
                            ),
                            child: CheckboxListTile(
                              title: Text('${item['client']} - ${item['lot']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                              subtitle: Text('${item['grade']} | ${item['kgs']} kg', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                              value: isSelected,
                              activeColor: const Color(0xFF5D6E7E),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              onChanged: (val) => setModalState(() {
                                if (val == true) _selectedForCancel.add(i);
                                else _selectedForCancel.remove(i);
                              }),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _selectedForCancel.isEmpty ? null : () {
                  final itemsToCancel = _selectedForCancel.map((idx) => items[idx]).toList();
                  Navigator.pop(ctx);
                  _processMultiCancel(itemsToCancel);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text('Cancel Selected', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _processMultiCancel(List<dynamic> items) async {
    final total = items.length;
    int successCount = 0;
    int failedCount = 0;
    final List<String> failedItems = [];
    
    // Show progress modal with individual item status
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInternalState) {
          return _buildGlassDialog(
            title: 'Batch Cancelling...',
            width: 350,
            centerContent: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 20),
                const CircularProgressIndicator(strokeWidth: 3, valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFEF4444))),
                const SizedBox(height: 20),
                Text('Processing $successCount of $total...', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Using sequential retry for quota resiliency.', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
              ],
            ),
            actions: [],
          );
        },
      ),
    );

    // Process each item - continue even if some fail
    for (final item in items) {
      bool success = false;
      int retries = 3;
      int delay = 1000;

      while (!success && retries >= 0) {
        try {
          await _apiService.removeFromCart(item['lot'], item['client'], item['billingFrom'], docId: item['id']?.toString());
          success = true;
          successCount++;
        } catch (e) {
          if (_isQuotaError(e) && retries > 0) {
            await Future.delayed(Duration(milliseconds: delay));
            delay *= 2;
            retries--;
          } else {
            // Don't throw - just track the failure and continue
            debugPrint('Failed to cancel ${item['lot']}: $e');
            failedItems.add('${item['lot']} - ${item['client']}');
            failedCount++;
            break; // Exit retry loop for this item, continue to next
          }
        }
      }
      
      // Small delay between items to avoid overwhelming the API
      if (items.indexOf(item) < items.length - 1) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    
    // Close progress modal
    if (mounted) Navigator.pop(context);
    
    if (mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => _buildGlassDialog(
          title: failedCount == 0 ? '✅ Batch Cancel Complete' : '⚠️ Batch Cancel Partial',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Successfully cancelled $successCount of $total order(s).'),
              if (failedCount > 0) ...[
                const SizedBox(height: 12),
                Text('Failed: $failedCount order(s)', style: const TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ...failedItems.take(5).map((item) => Text('• $item', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)))),
                if (failedItems.length > 5) Text('... and ${failedItems.length - 5} more', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
              ],
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _loadCart();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A5568),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
    
    _selectedForCancel.clear();
  }

  // ========================================================================
  //  PRINT BATCH — Transport → Company → Client hierarchy
  // ========================================================================

  /// Group cart items into Transport → Company(BillingFrom) → Client → [orders]
  Map<String, Map<String, Map<String, List<dynamic>>>> _buildHierarchy() {
    final Map<String, Map<String, Map<String, List<dynamic>>>> hierarchy = {};
    for (var item in _cartItems) {
      final client = item['client']?.toString() ?? 'Unknown';
      if (_billingFilter.isNotEmpty && item['billingFrom'] != _billingFilter) continue;
      final transport = _clientTransport[client] ?? '❓ No Transport';
      final company = item['billingFrom']?.toString() ?? 'Unknown';
      hierarchy.putIfAbsent(transport, () => {});
      hierarchy[transport]!.putIfAbsent(company, () => {});
      hierarchy[transport]![company]!.putIfAbsent(client, () => []).add(item);
    }
    return hierarchy;
  }

  void _showPrintBatchModal() {
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No orders to print'), backgroundColor: Color(0xFFF59E0B)),
      );
      return;
    }

    // ── Validation: all clients must have a transport assigned ──
    final allClients = <String>{};
    for (var item in _cartItems) {
      final client = item['client']?.toString() ?? 'Unknown';
      if (_billingFilter.isNotEmpty && item['billingFrom'] != _billingFilter) continue;
      allClients.add(client);
    }
    final unassigned = allClients.where((c) => (_clientTransport[c] ?? '').isEmpty).toList()..sort();
    if (unassigned.isNotEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange[700], size: 28),
            const SizedBox(width: 8),
            const Text('Transport Required', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Please assign a transport to every client before printing:', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              ...unassigned.map((c) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  const Icon(Icons.person_outline, size: 16, color: Color(0xFFEF4444)),
                  const SizedBox(width: 6),
                  Text(c, style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFEF4444), fontSize: 13)),
                ]),
              )),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    final hierarchy = _buildHierarchy();
    final today = DateFormat('dd/MM/yyyy').format(DateTime.now());

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 30, offset: const Offset(0, 10)),
            ],
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: const BoxDecoration(
                  color: Color(0xFF0F172A),
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.print_rounded, color: Colors.white, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Print Batch — by Transport', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                          Text('Date: $today', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7))),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),

              // Preview
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 700),
                      child: _buildHierarchyPreview(hierarchy),
                    ),
                  ),
                ),
              ),

              // Footer
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(24), bottomRight: Radius.circular(24)),
                  border: Border(top: BorderSide(color: Colors.grey.withOpacity(0.2))),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openPrintView(hierarchy, today);
                      },
                      icon: const Icon(Icons.print, size: 18),
                      label: const Text('Print', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0F172A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  /// Build on-screen preview widget for Transport → Company → Client hierarchy
  Widget _buildHierarchyPreview(Map<String, Map<String, Map<String, List<dynamic>>>> hierarchy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: hierarchy.entries.map((transportEntry) {
        final transport = transportEntry.key;
        return Container(
          width: 700,
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Transport header ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withOpacity(0.08),
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(15), topRight: Radius.circular(15)),
                ),
                child: Row(
                  children: [
                    const Text('🚚', style: TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                    Text(transport, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1E40AF))),
                  ],
                ),
              ),
              // Companies under this transport
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: transportEntry.value.entries.map((companyEntry) {
                    final company = companyEntry.key;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Company header
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: company == 'SYGT' ? const Color(0xFF5D6E7E) : const Color(0xFF22C55E),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(company, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                            ),
                          ),
                          // Clients under this company
                          ...companyEntry.value.entries.map((clientEntry) {
                            final client = clientEntry.key;
                            final items = clientEntry.value;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 12, left: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(children: [
                                      const Icon(Icons.person, size: 14, color: Color(0xFF64748B)),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(client.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF334155))),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF3B82F6).withValues(alpha: 0.08),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.25)),
                                        ),
                                        child: Text('🚚 $transport', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF1E40AF))),
                                      ),
                                    ]),
                                  ),
                                  // Order rows
                                  ...items.map((item) => Container(
                                    margin: const EdgeInsets.only(bottom: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(8)),
                                    child: Row(children: [
                                      SizedBox(width: 45, child: Text(item['lot']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                                      SizedBox(width: 130, child: Text(item['grade']?.toString() ?? '', style: const TextStyle(fontSize: 12))),
                                      SizedBox(width: 100, child: Text(item['brand']?.toString() ?? '', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)))),
                                      SizedBox(width: 80, child: Text(item['notes']?.toString() ?? '', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontStyle: FontStyle.italic))),
                                      SizedBox(width: 70, child: Text('${item['no'] ?? '0'} ${item['bagbox'] ?? ''}', style: const TextStyle(fontSize: 12))),
                                      SizedBox(width: 70, child: Text('${item['kgs'] ?? '0'} kg', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                                      SizedBox(width: 70, child: Text('₹${item['price'] ?? '0'}', style: const TextStyle(fontSize: 12))),
                                    ]),
                                  )),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  /// Build the printable content widget — Transport → Company → Client
  Widget _buildPrintableContent(Map<String, Map<String, Map<String, List<dynamic>>>> hierarchy, String date) {
    return Container(
      width: 700,
      color: Colors.white,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text('Despatch Details — ${date.replaceAll('/', '.')}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
          ),
          const SizedBox(height: 16),
          _buildHierarchyPreview(hierarchy),
        ],
      ),
    );
  }

  /// Generate native PDF — Transport → Company → Client hierarchy
  Future<Uint8List> _generatePdf(Map<String, Map<String, Map<String, List<dynamic>>>> hierarchy, String date) async {
    final pdfDoc = pw.Document();
    final dotDate = date.replaceAll('/', '.');

    final font = await PdfGoogleFonts.notoSansRegular();
    final fontBold = await PdfGoogleFonts.notoSansBold();

    const esplColor = PdfColor.fromInt(0xFF22C55E);
    const sygtColor = PdfColor.fromInt(0xFF5D6E7E);
    const transportBlue = PdfColor.fromInt(0xFF1E40AF);
    const transportBg = PdfColor.fromInt(0xFFEFF6FF);
    const rowBg = PdfColor.fromInt(0xFFF8FAFC);
    const textDark = PdfColor.fromInt(0xFF0F172A);
    const textMuted = PdfColor.fromInt(0xFF64748B);
    const textSlate = PdfColor.fromInt(0xFF334155);
    const borderColor = PdfColor.fromInt(0xFFE2E8F0);

    final List<pw.Widget> allWidgets = [];

    for (final transportEntry in hierarchy.entries) {
      final transport = transportEntry.key;

      // Transport header
      allWidgets.add(
        pw.Container(
          margin: const pw.EdgeInsets.only(top: 10, bottom: 4),
          padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: pw.BoxDecoration(
            color: transportBg,
            borderRadius: pw.BorderRadius.circular(6),
            border: pw.Border.all(color: borderColor),
          ),
          child: pw.Text('\u{1F69A} $transport', style: pw.TextStyle(font: fontBold, fontWeight: pw.FontWeight.bold, fontSize: 13, color: transportBlue)),
        ),
      );

      for (final companyEntry in transportEntry.value.entries) {
        final company = companyEntry.key;
        final companyColor = company == 'SYGT' ? sygtColor : esplColor;

        // Company sub-header
        allWidgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 8, top: 6, bottom: 2),
            child: pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: pw.BoxDecoration(color: companyColor, borderRadius: pw.BorderRadius.circular(4)),
              child: pw.Text(company, style: pw.TextStyle(font: fontBold, color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 11)),
            ),
          ),
        );

        // Clients under this company
        for (final clientEntry in companyEntry.value.entries) {
          final clientRows = <pw.Widget>[
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4, top: 6),
              child: pw.Row(children: [
                pw.Expanded(
                  child: pw.Text(clientEntry.key.toUpperCase(), style: pw.TextStyle(font: fontBold, fontWeight: pw.FontWeight.bold, fontSize: 11, color: textSlate)),
                ),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: pw.BoxDecoration(
                    borderRadius: pw.BorderRadius.circular(6),
                    border: pw.Border.all(color: transportBlue, width: 0.5),
                    color: transportBg,
                  ),
                  child: pw.Text('\u{1F69A} $transport', style: pw.TextStyle(font: font, fontSize: 8, color: transportBlue)),
                ),
              ]),
            ),
          ];

          for (final item in clientEntry.value) {
            clientRows.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 3),
                padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: const pw.BoxDecoration(color: rowBg, borderRadius: pw.BorderRadius.all(pw.Radius.circular(4))),
                child: pw.Row(children: [
                  pw.SizedBox(width: 35, child: pw.Text(item['lot']?.toString() ?? '', style: pw.TextStyle(font: fontBold, fontWeight: pw.FontWeight.bold, fontSize: 10))),
                  pw.SizedBox(width: 120, child: pw.Text(item['grade']?.toString() ?? '', style: pw.TextStyle(font: font, fontSize: 10))),
                  pw.SizedBox(width: 80, child: pw.Text(item['brand']?.toString() ?? '', style: pw.TextStyle(font: font, fontSize: 9, color: textMuted))),
                  pw.SizedBox(width: 70, child: pw.Text(item['notes']?.toString() ?? '', style: pw.TextStyle(font: font, fontSize: 9, color: textMuted))),
                  pw.SizedBox(width: 60, child: pw.Text('${item['no'] ?? '0'} ${item['bagbox'] ?? ''}', style: pw.TextStyle(font: font, fontSize: 10))),
                  pw.SizedBox(width: 55, child: pw.Text('${item['kgs'] ?? '0'} kg', style: pw.TextStyle(font: fontBold, fontSize: 10, fontWeight: pw.FontWeight.bold))),
                  pw.SizedBox(width: 55, child: pw.Text('\u20B9${item['price'] ?? '0'}', style: pw.TextStyle(font: font, fontSize: 10))),
                ]),
              ),
            );
          }

          allWidgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 16, bottom: 6),
              child: pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  borderRadius: pw.BorderRadius.circular(8),
                  border: pw.Border.all(color: borderColor),
                ),
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: clientRows),
              ),
            ),
          );
        }
      }

      allWidgets.add(pw.SizedBox(height: 12));
    }

    pdfDoc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context ctx) => [
          pw.Center(
            child: pw.Text(
              'Despatch Details \u2014 $dotDate',
              style: pw.TextStyle(font: fontBold, fontSize: 18, fontWeight: pw.FontWeight.bold, color: textDark),
            ),
          ),
          pw.SizedBox(height: 12),
          ...allWidgets,
        ],
      ),
    );

    return pdfDoc.save();
  }

  /// Open print view — Transport → Company → Client hierarchy
  void _openPrintView(Map<String, Map<String, Map<String, List<dynamic>>>> hierarchy, String date) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 30, offset: const Offset(0, 10)),
            ],
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: const BoxDecoration(
                  color: Color(0xFF0F172A),
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.print_rounded, color: Colors.white, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Print Batch — by Transport', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                          Text('Date: $date', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7))),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),

              // Content preview
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: _buildPrintableContent(hierarchy, date),
                  ),
                ),
              ),

              // Footer with Close + Share + Print buttons
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(24), bottomRight: Radius.circular(24)),
                  border: Border(top: BorderSide(color: Colors.grey.withOpacity(0.2))),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final pdfBytes = await _generatePdf(hierarchy, date);
                        final fileDate = date.replaceAll('/', '');
                        await Printing.sharePdf(bytes: pdfBytes, filename: 'Despatch_$fileDate.pdf');
                      },
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Share PDF', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final pdfBytes = await _generatePdf(hierarchy, date);
                        final fileDate = date.replaceAll('/', '');
                        await Printing.layoutPdf(
                          onLayout: (_) async => pdfBytes,
                          name: 'Despatch_$fileDate',
                        );
                      },
                      icon: const Icon(Icons.print, size: 18),
                      label: const Text('Print', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0F172A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  void _showPendingOrdersModal(String client) {
    final clientPending = _pendingOrders.where((p) {
        if (p['client'] != client) return false;
        if (_billingFilter.isNotEmpty && p['billingFrom'] != _billingFilter) return false;
        return true;
    }).toList();

    final Set<int> selectedIndices = {};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return _buildGlassDialog(
            title: 'Pending orders for $client',
            content: SizedBox(
               width: 500,
               child: Column(
                 mainAxisSize: MainAxisSize.min,
                 children: [
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 400),
                        child: ListView.builder(
                           shrinkWrap: true,
                           itemCount: clientPending.length,
                           itemBuilder: (ctx, i) {
                             final p = clientPending[i];
                             final isSelected = selectedIndices.contains(i);
                             return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFF5D6E7E).withOpacity(0.05) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: isSelected ? const Color(0xFF5D6E7E).withOpacity(0.2) : Colors.transparent),
                                ),
                                child: CheckboxListTile(
                                  title: Text('${p['client']} - ${p['lot']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                  subtitle: Text('${p['grade']} kg | ₹${p['price']}', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                                  value: isSelected,
                                  activeColor: const Color(0xFF5D6E7E),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  onChanged: (val) => setModalState(() {
                                     if (val == true) selectedIndices.add(i);
                                     else selectedIndices.remove(i);
                                  }),
                                ),
                             );
                           },
                         ),
                      ),
                    ),
                 ],
               ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: selectedIndices.isEmpty ? null : () {
                  final ordersToAdd = selectedIndices.map((idx) {
                    final p = clientPending[idx];
                    return {
                        'orderDate': p['orderDate'],
                        'billingFrom': p['billingFrom'],
                        'client': p['client'],
                        'lot': p['lot'],
                        'grade': p['grade'],
                        'bagbox': p['bagbox'],
                        'no': p['no'],
                        'kgs': p['kgs'],
                        'price': p['price'],
                        'brand': p['brand'],
                        'status': p['status'],
                        'notes': p['notes'],
                        'index': p['index']
                    };
                  }).toList();

                  Navigator.pop(ctx);

                  fireAndForget(
                    type: 'create',
                    apiCall: () => _apiService.addToCart(ordersToAdd),
                    successMessage: '${ordersToAdd.length} order(s) added to cart',
                    failureMessage: 'Failed to add orders to cart',
                    onSuccess: () {
                      if (mounted) _loadCart();
                    },
                  );
                },
                style: ElevatedButton.styleFrom(
                   backgroundColor: const Color(0xFF5D6E7E),
                   foregroundColor: Colors.white,
                   shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                   padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text('Add Selected', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: '📅 Daily Cart',
      subtitle: 'Review and print today\'s packed orders.',
      disableInternalScrolling: true,
      topActions: [
        _buildNavBtn(label: 'Dashboard', onPressed: () { if (Navigator.canPop(context)) Navigator.pop(context); else Navigator.pushReplacementNamed(context, '/'); }, color: const Color(0xFF5D6E7E)),
        const SizedBox(width: 8),
        _buildNavBtn(label: 'View Orders', onPressed: () => Navigator.pushNamed(context, '/view_orders'), color: const Color(0xFF22C55E)),
      ],
      content: RefreshIndicator(
        onRefresh: _loadCart,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                children: [
                  if (_isFromCache)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: CachedDataChip(ageString: _cacheAge),
                    ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        decoration: AppTheme.glassDecoration,
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            const Text(
                              '📅 Today\'s Packed Orders',
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF0F172A), letterSpacing: -0.5),
                            ),
                            const SizedBox(height: 32),
                            _buildFilters(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Client search bar
                  Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFF5D6E7E).withOpacity(0.06),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFF5D6E7E).withOpacity(0.18)),
                    ),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (val) => setState(() => _searchQuery = val),
                      decoration: InputDecoration(
                        hintText: 'Search by client name...',
                        hintStyle: const TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
                        prefixIcon: const Icon(Icons.search, color: Color(0xFF5D6E7E), size: 20),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close, color: Color(0xFF5D6E7E), size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      style: const TextStyle(fontSize: 14, color: Color(0xFF0F172A)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _isLoading
                      ? const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
                      : _buildCartGroups(),
                ],
              ),
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


  Widget _buildFilters() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        return Column(
          children: [
            // Billing dropdown
            Container(
              height: 48,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF5D6E7E).withOpacity(0.08),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF5D6E7E).withOpacity(0.2)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _billingFilter.isEmpty ? null : _billingFilter,
                  isExpanded: true,
                  hint: Text(isMobile ? 'Billing' : 'All Billing', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E))),
                  icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF5D6E7E)),
                  borderRadius: BorderRadius.circular(24),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('All Billing')),
                    ...['SYGT', 'ESPL'].map((e) => DropdownMenuItem(value: e, child: Text(e))),
                  ],
                  onChanged: (val) => setState(() => _billingFilter = val ?? ''),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Action buttons in a grid
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: isMobile ? 2 : 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: isMobile ? 3.0 : 4.0,
              padding: EdgeInsets.zero,
              children: [
                _buildActionButton('🖨️ Batch', const Color(0xFF64748B), _showPrintBatchModal, isMobile: isMobile),
                _buildActionButton('✖ Cancel', const Color(0xFFEF4444), _showMultiCancelModal, isMobile: isMobile),
                _buildActionButton('📦 End Day', const Color(0xFF22C55E), _archiveToPackedOrders, isMobile: isMobile),
                _buildActionButton('🧺 Add', const Color(0xFF5D6E7E), () => Navigator.pushNamed(context, '/add_to_cart'), isMobile: isMobile),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildActionButton(String label, Color color, VoidCallback onPressed, {bool isMobile = false}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withOpacity(0.08),
        foregroundColor: color,
        elevation: 0,
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(isMobile ? 12 : 20), side: BorderSide(color: color.withOpacity(0.2))),
      ),
      child: Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: isMobile ? 11 : 12), textAlign: TextAlign.center),
    );
  }

  Widget _buildGlassDialog({required String title, required Widget content, required List<Widget> actions, double width = 550, bool centerContent = false}) {
    return Center(
      child: Container(
        width: width,
        margin: const EdgeInsets.all(24),
        decoration: AppTheme.glassDecoration.copyWith(
          borderRadius: BorderRadius.circular(20),
          color: Colors.white.withOpacity(0.95),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: centerContent ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)), textAlign: centerContent ? TextAlign.center : TextAlign.start),
                    const SizedBox(height: 24),
                    content,
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 32),
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
      fillColor: Colors.white.withOpacity(0.8),
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }


  Widget _buildCartGroups() {
    if (_cartItems.isEmpty) return const Center(child: Text('No orders in cart today.'));

    final Map<String, List<dynamic>> grouped = {};
    final query = _searchQuery.trim().toLowerCase();
    for (var item in _cartItems) {
      final client = item['client'] ?? 'Unknown';
      if (_billingFilter.isNotEmpty && item['billingFrom'] != _billingFilter) continue;
      if (query.isNotEmpty && !client.toString().toLowerCase().contains(query)) continue;
      grouped.putIfAbsent(client, () => []).add(item);
    }

    if (grouped.isEmpty) return const Center(child: Text('No matching orders found.'));

    return Column(
      children: grouped.entries.map((e) => _buildClientGroup(e.key, e.value)).toList(),
    );
  }

  void _showTransportPicker(BuildContext ctx, String client) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        final current = _clientTransport[client] ?? '';
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    const Text('🚚', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: 8),
                    Text('Select Transport', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: const Color(0xFF0F172A))),
                  ],
                ),
              ),
              const Divider(height: 1),
              // "None" option to clear
              ListTile(
                dense: true,
                leading: Icon(Icons.close_rounded, size: 20, color: Colors.grey[400]),
                title: Text('None', style: TextStyle(fontSize: 14, color: Colors.grey[500])),
                trailing: current.isEmpty ? const Icon(Icons.check_circle, size: 20, color: Color(0xFF3B82F6)) : null,
                onTap: () {
                  _suppressDidPopNext = true;
                  Navigator.pop(sheetCtx);
                  setState(() {
                    _clientTransport.remove(client);
                    _transportRemovals.add(client);
                  });
                  _saveTransportAssignments();
                },
              ),
              // Transport options
              ...(_transportList.map((t) => ListTile(
                dense: true,
                leading: const Text('🚚', style: TextStyle(fontSize: 16)),
                title: Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                trailing: current == t ? const Icon(Icons.check_circle, size: 20, color: Color(0xFF3B82F6)) : null,
                onTap: () {
                  _suppressDidPopNext = true;
                  Navigator.pop(sheetCtx);
                  setState(() => _clientTransport[client] = t);
                  _saveTransportAssignments();
                },
              ))),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildClientGroup(String client, List<dynamic> items) {
    // Attempt to get date from first item
    String dateStr = '';
    if (items.isNotEmpty && items.first['orderDate'] != null) {
       dateStr = items.first['orderDate'].toString();
    } else {
      dateStr = DateFormat('dd/MM/yy').format(DateTime.now());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Date Header
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9), 
                  borderRadius: BorderRadius.circular(6)
                ),
                child: const Icon(Icons.calendar_today, size: 16, color: Color(0xFF64748B)),
              ),
              const SizedBox(width: 8),
              Text(dateStr, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
            ],
          ),
        ),

        // Client Header + Transport dropdown
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 16),
          child: Row(
            children: [
              Container(
                margin: const EdgeInsets.only(right: 8),
                child: const Icon(Icons.person, size: 24, color: Color(0xFF475569)),
              ),
              Expanded(
                child: Text(
                  client.toUpperCase(),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A), letterSpacing: 0.5),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              // Transport chip — tap to pick/change via bottom sheet
              if (_transportList.isNotEmpty)
                Builder(
                  builder: (context) {
                    final selected = _clientTransport[client];
                    final hasSelection = selected != null && selected.isNotEmpty;
                    return GestureDetector(
                      onTap: () => _showTransportPicker(context, client),
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: hasSelection
                              ? const Color(0xFF3B82F6).withValues(alpha: 0.08)
                              : const Color(0xFF3B82F6).withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(
                            color: hasSelection
                                ? const Color(0xFF3B82F6).withValues(alpha: 0.3)
                                : const Color(0xFF3B82F6).withValues(alpha: 0.15),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(hasSelection ? '🚚' : '🚚', style: const TextStyle(fontSize: 14)),
                            const SizedBox(width: 5),
                            Text(
                              hasSelection ? selected : 'Transport',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: hasSelection ? FontWeight.w700 : FontWeight.w500,
                                color: hasSelection ? const Color(0xFF1E40AF) : const Color(0xFF3B82F6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),

        // Items List
        ...items.map((item) => _buildOrderLine(item)).toList(),
        
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildOrderLine(dynamic item) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final String lot = item['lot']?.toString() ?? '';
        final String grade = item['grade']?.toString() ?? '';
        final String no = item['no']?.toString() ?? '0';
        final String bagbox = item['bagbox']?.toString() ?? '';
        final String kgs = item['kgs']?.toString() ?? '0';
        final String price = item['price']?.toString() ?? '0';
        final String brand = item['brand']?.toString() ?? '';
        final String billing = item['billingFrom']?.toString() ?? '';
        final String notes = item['notes']?.toString() ?? '';

        final String mainText = '$lot: $grade - $no $bagbox - $kgs kgs x ₹$price - $brand';

        return Container(
          margin: const EdgeInsets.only(bottom: 8), 
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 18, vertical: isMobile ? 10 : 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.9),
            borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
            border: Border.all(color: const Color(0xFFDDDDDD)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                offset: const Offset(0, 4),
                blurRadius: 10,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Main Text
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(fontSize: isMobile ? 13 : 14, color: const Color(0xFF0F172A), height: 1.3),
                        children: [
                          TextSpan(
                            text: mainText, 
                            style: const TextStyle(fontWeight: FontWeight.w600)
                          ),
                          if (billing.isNotEmpty) ...[
                            const WidgetSpan(child: SizedBox(width: 8)),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF22C55E),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  billing,
                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Delete Action (tappable icon)
                  IconButton(
                    onPressed: () => _removeFromCart(item),
                    icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                    iconSize: isMobile ? 18 : 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              // Notes (Optional, compact)
              if (notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.notes, size: 12, color: Color(0xFF64748B)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          notes,
                          style: TextStyle(fontSize: isMobile ? 11 : 12, color: const Color(0xFF64748B), fontStyle: FontStyle.italic),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF94A3B8), letterSpacing: 0.5)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF334155))),
      ],
    );
  }

  Widget _buildPendingLink(String client) {
    final pendingCount = _pendingOrders.where((p) {
        if (p['client'] != client) return false;
        if (_billingFilter.isNotEmpty && p['billingFrom'] != _billingFilter) return false;
        return true;
    }).length;

    if (pendingCount == 0) return const SizedBox.shrink();

    return InkWell(
      onTap: () => _showPendingOrdersModal(client),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF185A9D).withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF185A9D).withOpacity(0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add_circle_outline, size: 12, color: Color(0xFF185A9D)),
            const SizedBox(width: 6),
            Text('$pendingCount Available', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF185A9D))),
          ],
        ),
      ),
    );
  }
}
