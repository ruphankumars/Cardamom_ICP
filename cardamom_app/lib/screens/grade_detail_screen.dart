import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/operation_queue.dart';
import '../mixins/optimistic_action_mixin.dart';
import '../widgets/app_shell.dart';

class GradeDetailScreen extends StatefulWidget {
  final String grade;
  final String statusFilter;
  final String billingFilter;
  final String clientFilter;
  final String? dateFilter;

  const GradeDetailScreen({
    super.key,
    required this.grade,
    this.statusFilter = '',
    this.billingFilter = '',
    this.clientFilter = '',
    this.dateFilter,
  });

  @override
  State<GradeDetailScreen> createState() => _GradeDetailScreenState();
}

class _GradeDetailScreenState extends State<GradeDetailScreen> with OptimisticActionMixin {
  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();

  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _orders = [];
  String _userRole = 'user';

  // Add to Cart mode state
  bool _isAddToCartMode = false;
  final Set<int> _cartSelectedIndices = {};

  bool get _isAdmin =>
      _userRole.toLowerCase() == 'superadmin' ||
      _userRole.toLowerCase() == 'admin' ||
      _userRole.toLowerCase() == 'ops';

  /// Whether to sort ascending (old first) — for Pending/On Progress
  bool get _sortOldFirst {
    final s = widget.statusFilter.toLowerCase();
    return s == 'pending' || s == 'on progress';
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';

      final filters = <String, dynamic>{};
      if (widget.billingFilter.isNotEmpty) filters['billingFrom'] = widget.billingFilter;
      if (widget.statusFilter.isNotEmpty) filters['status'] = widget.statusFilter;
      if (widget.clientFilter.isNotEmpty) filters['client'] = widget.clientFilter;
      if (widget.dateFilter != null) filters['date'] = widget.dateFilter;

      final response = await _apiService.getOrdersByGrade(widget.grade, filters);
      if (!mounted) return;
      setState(() {
        _orders = (response.data is List) ? response.data : [];
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading grade detail: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  /// Categorize brand from order brand field + notes field
  String _categorizeBrand(Map<String, dynamic> order) {
    final brand = (order['brand'] ?? '').toString().trim();
    if (brand.isNotEmpty) return brand;
    final notes = (order['notes'] ?? '').toString().toLowerCase();
    if (notes.contains('pouch') ||
        notes.contains('local') ||
        notes.contains('lp') ||
        notes.contains('l.p') ||
        notes.contains('l p')) {
      return 'Local Pouch';
    }
    return 'Loose Bag';
  }

  /// Parse date string "dd/MM/yy" to DateTime for sorting
  DateTime _parseDate(String dateStr) {
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

  /// Build grouped data: Brand → Client → Orders
  /// Returns list of brand groups, each with client sub-groups
  List<_BrandGroup> _buildGroupedData() {
    if (_orders.isEmpty) return [];

    // Group orders by brand → client
    final Map<String, Map<String, List<Map<String, dynamic>>>> brandClientMap = {};

    for (var order in _orders) {
      final o = Map<String, dynamic>.from(order);
      final brand = _categorizeBrand(o);
      final client = (o['client'] ?? 'Unknown').toString();

      brandClientMap.putIfAbsent(brand, () => {});
      brandClientMap[brand]!.putIfAbsent(client, () => []);
      brandClientMap[brand]![client]!.add(o);
    }

    // Sort orders within each client group by date
    final int dateSortDir = _sortOldFirst ? 1 : -1;

    for (var brand in brandClientMap.keys) {
      for (var client in brandClientMap[brand]!.keys) {
        brandClientMap[brand]![client]!.sort((a, b) {
          final da = _parseDate((a['orderDate'] ?? '').toString());
          final db = _parseDate((b['orderDate'] ?? '').toString());
          return da.compareTo(db) * dateSortDir;
        });
      }
    }

    // For each brand, determine its representative date (oldest for pending, newest for billed)
    // Then sort brands by that representative date
    final brandGroups = <_BrandGroup>[];
    for (var brandEntry in brandClientMap.entries) {
      final brand = brandEntry.key;
      final clientsMap = brandEntry.value;

      // Collect all dates across all clients for this brand
      DateTime? repDate;
      for (var orders in clientsMap.values) {
        for (var o in orders) {
          final d = _parseDate((o['orderDate'] ?? '').toString());
          if (repDate == null) {
            repDate = d;
          } else if (_sortOldFirst) {
            if (d.isBefore(repDate)) repDate = d;
          } else {
            if (d.isAfter(repDate)) repDate = d;
          }
        }
      }

      // Sort clients within brand by their representative date
      final clientGroups = <_ClientGroup>[];
      for (var clientEntry in clientsMap.entries) {
        DateTime? clientRepDate;
        for (var o in clientEntry.value) {
          final d = _parseDate((o['orderDate'] ?? '').toString());
          if (clientRepDate == null) {
            clientRepDate = d;
          } else if (_sortOldFirst) {
            if (d.isBefore(clientRepDate)) clientRepDate = d;
          } else {
            if (d.isAfter(clientRepDate)) clientRepDate = d;
          }
        }
        clientGroups.add(_ClientGroup(
          clientName: clientEntry.key,
          orders: clientEntry.value,
          representativeDate: clientRepDate ?? DateTime(2000),
        ));
      }

      clientGroups.sort((a, b) =>
          a.representativeDate.compareTo(b.representativeDate) * dateSortDir);

      brandGroups.add(_BrandGroup(
        brandName: brand,
        clients: clientGroups,
        representativeDate: repDate ?? DateTime(2000),
      ));
    }

    brandGroups.sort((a, b) =>
        a.representativeDate.compareTo(b.representativeDate) * dateSortDir);

    return brandGroups;
  }

  /// Get flat index for an order in the _orders list (for cart selection)
  int _getOrderIndex(Map<String, dynamic> order) {
    final idx = order['index']?.toString() ?? '';
    for (var i = 0; i < _orders.length; i++) {
      if ((_orders[i]['index']?.toString() ?? '') == idx) return i;
    }
    return -1;
  }

  // ---- Add to Cart methods ----

  void _showPartialDispatchModal(Map<String, dynamic> order) {
    final totalKgs = (num.tryParse(order['kgs'].toString()) ?? 0).toDouble();
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
            Text('${order['lot']}: ${order['grade']} - ${order['kgs']} kgs',
                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            const SizedBox(height: 4),
            Text('Enter quantity to dispatch (Total: $totalKgs kg)',
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
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
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid quantity')));
                return;
              }
              Navigator.pop(ctx);
              _doPartialDispatch(order, qty);
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

  void _doPartialDispatch(Map<String, dynamic> order, double qty) {
    HapticFeedback.heavyImpact();
    fireAndForget(
      type: 'partial_dispatch',
      apiCall: () => _apiService.partialDispatch(order, qty),
      successMessage: '✂️ ${order['lot']} - ${order['grade']}: ${qty}kg dispatched!',
      failureMessage: 'Failed to dispatch ${order['lot']}. Please retry.',
      onSuccess: () {
        if (mounted) _loadData();
      },
    );
  }

  Future<void> _submitCartOrders() async {
    if (_cartSelectedIndices.isEmpty) return;
    final selectedOrders = _cartSelectedIndices
        .where((i) => i >= 0 && i < _orders.length)
        .map((i) => _orders[i])
        .toList();
    if (selectedOrders.isEmpty) return;

    // Show date picker popup before submitting
    _showCartDatePicker(selectedOrders);
  }

  void _showCartDatePicker(List<dynamic> selectedOrders) {
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
                  Text('${selectedOrders.length} order(s) selected',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500)),
                  const SizedBox(height: 16),

                  // Today option
                  GestureDetector(
                    onTap: () => setDialogState(() { isTodaySelected = true; selectedDate = null; }),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isTodaySelected ? const Color(0xFF10B981).withOpacity(0.08) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isTodaySelected ? const Color(0xFF10B981) : const Color(0xFFE2E8F0), width: isTodaySelected ? 2 : 1),
                      ),
                      child: Row(
                        children: [
                          Icon(isTodaySelected ? Icons.radio_button_checked : Icons.radio_button_off,
                              color: isTodaySelected ? const Color(0xFF10B981) : const Color(0xFF94A3B8), size: 20),
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
                            decoration: BoxDecoration(color: const Color(0xFF8B5CF6).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
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
                      final picked = await showDatePicker(context: ctx, initialDate: selectedDate ?? today.subtract(const Duration(days: 1)), firstDate: DateTime(2020), lastDate: today);
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
                        border: Border.all(color: !isTodaySelected ? const Color(0xFF3B82F6) : const Color(0xFFE2E8F0), width: !isTodaySelected ? 2 : 1),
                      ),
                      child: Row(
                        children: [
                          Icon(!isTodaySelected ? Icons.radio_button_checked : Icons.radio_button_off,
                              color: !isTodaySelected ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(!isTodaySelected && selectedDate != null ? displayDate : 'Select Old Date',
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: !isTodaySelected ? const Color(0xFF1E293B) : const Color(0xFF94A3B8))),
                                const Text('Tap to pick a date', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                              ],
                            ),
                          ),
                          const Icon(Icons.calendar_today, size: 18, color: Color(0xFF64748B)),
                          if (!isTodaySelected) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: const Color(0xFF3B82F6).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                              child: const Text('Billed', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF3B82F6))),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (isOldDate)
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, size: 16, color: Color(0xFF92400E)),
                          SizedBox(width: 8),
                          Expanded(child: Text('Old date: Orders will be marked as Billed with packed date set.',
                              style: TextStyle(fontSize: 11, color: Color(0xFF92400E), fontWeight: FontWeight.w500))),
                        ],
                      ),
                    ),

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

  Future<void> _executeCartSubmission(List<dynamic> selectedOrders, String cartDate, bool markBilled) async {
    final count = selectedOrders.length;
    final statusLabel = markBilled ? 'Billed' : 'On Progress';

    // Immediately update local state (clear cart mode)
    setState(() {
      _cartSelectedIndices.clear();
      _isAddToCartMode = false;
    });
    HapticFeedback.heavyImpact();

    try {
      await _apiService.addToCart(selectedOrders, cartDate: cartDate, markBilled: markBilled);
      await _loadData();
      if (mounted) {
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
                Text('$count order(s) pushed!',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Status: $statusLabel  •  Date: $cartDate',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[600])),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('OK')),
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error adding to cart: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // ---- Build UI ----

  @override
  Widget build(BuildContext context) {
    final isPending = widget.statusFilter.toLowerCase() == 'pending';
    final sortLabel = _sortOldFirst ? 'Oldest first' : 'Newest first';

    return AppShell(
      title: '📊 ${widget.grade}',
      subtitle: 'Brand-wise order breakdown',
      topActions: [
        if (_isAddToCartMode)
          _buildTopButton(
            label: '✖ Cancel Cart',
            onPressed: () => setState(() {
              _isAddToCartMode = false;
              _cartSelectedIndices.clear();
            }),
            color: const Color(0xFFEF4444),
            isMobile: true,
          )
        else
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF475569), size: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              switch (value) {
                case 'back':
                  Navigator.pop(context);
                  break;
                case 'add_to_cart':
                  setState(() {
                    _isAddToCartMode = true;
                    _cartSelectedIndices.clear();
                  });
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'back',
                child: Row(
                  children: [
                    Icon(Icons.arrow_back_rounded, color: Color(0xFF5D6E7E), size: 20),
                    SizedBox(width: 10),
                    Text('Back', style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              if (_isAdmin && isPending)
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
      floatingActionButton: _isAddToCartMode
          ? GestureDetector(
              onTap: _cartSelectedIndices.isNotEmpty ? _submitCartOrders : null,
              child: Container(
                width: 64,
                height: 64,
                margin: const EdgeInsets.only(bottom: 60),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _cartSelectedIndices.isNotEmpty
                        ? [const Color(0xFF10B981), const Color(0xFF059669)]
                        : [Colors.grey.shade400, Colors.grey.shade500],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _cartSelectedIndices.isNotEmpty
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
                    if (_cartSelectedIndices.isNotEmpty)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                          child: Text('${_cartSelectedIndices.length}',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ),
                  ],
                ),
              ),
            )
          : null,
      content: Column(
        children: [
          // Header info
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.grade,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _sortOldFirst ? const Color(0xFFFEF3C7) : const Color(0xFFDBEAFE),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    sortLabel,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _sortOldFirst ? const Color(0xFF92400E) : const Color(0xFF1E40AF)),
                  ),
                ),
              ],
            ),
          ),
          // Filter tags
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (widget.statusFilter.isNotEmpty) _buildFilterTag(widget.statusFilter),
                if (widget.billingFilter.isNotEmpty) _buildFilterTag(widget.billingFilter),
                if (widget.clientFilter.isNotEmpty) _buildFilterTag(widget.clientFilter),
                _buildFilterTag('${_orders.length} orders'),
              ],
            ),
          ),
          // Cart mode counter
          if (_isAddToCartMode)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
              ),
              child: Text(
                '${_cartSelectedIndices.length} order(s) selected for cart  •  Tap ✂️ for partial, ☑️ to select',
                style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          const SizedBox(height: 8),
          // Main content
          _isLoading
              ? const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _orders.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: Center(
                        child: Text('No orders found for this grade.',
                            style: TextStyle(color: Color(0xFF64748B), fontSize: 15)),
                      ),
                    )
                  : _buildGroupedList(),
        ],
      ),
    );
  }

  Widget _buildFilterTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
    );
  }

  Widget _buildTopButton({required String label, required VoidCallback onPressed, required Color color, bool isMobile = false}) {
    return Container(
      height: isMobile ? 36 : 40,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: color.withOpacity(0.4), offset: const Offset(0, 4), blurRadius: 10)],
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: Text(label, style: TextStyle(fontSize: isMobile ? 11 : 13, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildGroupedList() {
    final groups = _buildGroupedData();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: groups.map((brandGroup) => _buildBrandSection(brandGroup)).toList(),
    );
  }

  Widget _buildBrandSection(_BrandGroup brandGroup) {
    // Compute total kgs for this brand
    double brandTotalKgs = 0;
    int brandTotalOrders = 0;
    for (var cg in brandGroup.clients) {
      for (var o in cg.orders) {
        brandTotalKgs += (num.tryParse(o['kgs'].toString()) ?? 0).toDouble();
        brandTotalOrders++;
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Brand header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF475569), Color(0xFF64748B)]),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.inventory_2_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    brandGroup.brandName,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$brandTotalOrders orders • ${brandTotalKgs.toStringAsFixed(1)} kg',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          // Client sub-sections
          ...brandGroup.clients.map((clientGroup) => _buildClientSection(clientGroup)),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildClientSection(_ClientGroup clientGroup) {
    double clientKgs = 0;
    for (var o in clientGroup.orders) {
      clientKgs += (num.tryParse(o['kgs'].toString()) ?? 0).toDouble();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Client header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              const Icon(Icons.person, color: Color(0xFF64748B), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  clientGroup.clientName,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                ),
              ),
              Text(
                '${clientGroup.orders.length} • ${clientKgs.toStringAsFixed(1)} kg',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        // Order rows
        ...clientGroup.orders.map((order) => _buildOrderRow(order)),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }

  /// Show order detail popup on card tap
  void _showOrderDetailPopup(BuildContext context, Map<String, dynamic> order, Color ageColor, int ageDays) {
    final client = (order['client'] ?? '').toString();
    final lot = (order['lot'] ?? '').toString();
    final kgs = (order['kgs'] ?? '').toString();
    final price = num.tryParse(order['price'].toString()) ?? 0;
    final notes = (order['notes'] ?? '').toString().trim();
    final billing = (order['billingFrom'] ?? '').toString();
    final status = (order['status'] ?? '').toString();
    final orderDate = (order['orderDate'] ?? '').toString();
    final brand = _categorizeBrand(order);
    final bags = (order['bags'] ?? order['bagbox'] ?? '').toString();

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
                      child: Text(client,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 22),
                    ),
                  ],
                ),
                const Divider(height: 20),
                _popupRow('Date', orderDate),
                _popupRow('Lot', lot),
                _popupRow('Grade', widget.grade),
                _popupRow('Quantity', '${bags.isNotEmpty ? "$bags  •  " : ""}$kgs kgs'),
                if (price > 0) _popupRow('Price', '₹${price.toInt()} / kg'),
                if (brand.isNotEmpty) _popupRow('Brand', brand),
                if (notes.isNotEmpty) _popupRow('Notes', notes),
                _popupRow('Status', status),
                if (billing.isNotEmpty) _popupRow('Billing', billing),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: ageColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ageColor.withOpacity(0.3)),
                    ),
                    child: Text('$ageDays days old',
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

  Widget _buildOrderRow(Map<String, dynamic> order) {
    final idx = _getOrderIndex(order);
    final isSelected = _cartSelectedIndices.contains(idx);
    final isPending = (order['status'] ?? '').toString().toLowerCase() == 'pending';
    final lot = order['lot'] ?? '';
    final kgs = num.tryParse(order['kgs'].toString()) ?? 0;
    final price = num.tryParse(order['price'].toString()) ?? 0;
    final notes = (order['notes'] ?? '').toString().trim();
    final billing = (order['billingFrom'] ?? '').toString();
    final status = (order['status'] ?? '').toString();
    final orderDate = (order['orderDate'] ?? '').toString();
    final ageDays = (order['daysSinceOrder'] as num?)?.toInt() ?? 0;
    // Unified thresholds: >10 red, >=5 yellow, <5 green
    final ageColor = ageDays > 10 ? const Color(0xFFEF4444) : ageDays >= 5 ? const Color(0xFFF59E0B) : const Color(0xFF22C55E);
    final isRed = ageDays > 10;

    // Border color: selection overrides age color
    Color borderColor;
    double borderWidth;
    if (isSelected) {
      borderColor = const Color(0xFF10B981);
      borderWidth = 2.0;
    } else {
      borderColor = ageColor;
      borderWidth = 2.0;
    }

    final bags = (order['bagbox'] ?? order['bags'] ?? '').toString();
    final bagsNo = (order['no'] ?? order['bagsNo'] ?? '').toString();
    final brand = _categorizeBrand(order);

    final innerContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Row 1: Lot: Grade - Bags BagType  |  Age badge  |  Kgs x Price
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$lot: ${widget.grade} - $bagsNo $bags',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF1E293B)),
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
                    '$kgs kgs ${price > 0 ? "x ₹${price.toInt()}" : ""}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF475569)),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Row 2: Brand + Notes + Billing + Status + Cart actions
        Row(
          children: [
            if (brand.isNotEmpty && brand != 'N/A') ...[
              Text('- $brand', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E))),
              const SizedBox(width: 8),
            ],
            if (notes.isNotEmpty) ...[
              const Icon(Icons.notes_rounded, size: 12, color: Color(0xFF94A3B8)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(notes,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontStyle: FontStyle.italic, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
            ] else
              const Spacer(),
            // Billing badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(billing, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 4),
            _buildStatusBadge(status),
            // Cart mode: scissors + checkbox
            if (_isAddToCartMode && isPending) ...[
              const SizedBox(width: 8),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.content_cut, color: Color(0xFFF59E0B), size: 18),
                onPressed: () => _showPartialDispatchModal(order),
                tooltip: 'Partial Dispatch',
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  setState(() {
                    if (isSelected) {
                      _cartSelectedIndices.remove(idx);
                    } else {
                      _cartSelectedIndices.add(idx);
                    }
                  });
                },
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF10B981) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: isSelected ? const Color(0xFF10B981) : const Color(0xFFCBD5E1), width: 1.5),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : null,
                ),
              ),
            ],
          ],
        ),
      ],
    );

    final onTapHandler = _isAddToCartMode && isPending
        ? () {
            setState(() {
              if (isSelected) {
                _cartSelectedIndices.remove(idx);
              } else {
                _cartSelectedIndices.add(idx);
              }
            });
          }
        : () => _showOrderDetailPopup(context, order, ageColor, ageDays);

    // For red (old) cards: wrap with pulsing animation
    if (isRed) {
      return _PulsingOrderCard(
        ageColor: ageColor,
        onTap: onTapHandler,
        isSelected: isSelected,
        borderColor: borderColor,
        borderWidth: borderWidth,
        child: innerContent,
      );
    }

    return GestureDetector(
      onTap: onTapHandler,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF10B981).withOpacity(0.08)
              : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: borderWidth),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2)),
          ],
        ),
        child: innerContent,
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    final s = status.toLowerCase();
    Color color;
    if (s == 'pending') {
      color = const Color(0xFFF59E0B);
    } else if (s == 'billed') {
      color = const Color(0xFF3B82F6);
    } else if (s == 'on progress') {
      color = const Color(0xFF8B5CF6);
    } else {
      color = const Color(0xFF22C55E);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(status,
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

/// Animated wrapper that pulses the shadow for red (old) order cards
class _PulsingOrderCard extends StatefulWidget {
  final Color ageColor;
  final Color borderColor;
  final double borderWidth;
  final bool isSelected;
  final VoidCallback? onTap;
  final Widget child;

  const _PulsingOrderCard({
    required this.ageColor,
    required this.borderColor,
    required this.borderWidth,
    required this.isSelected,
    this.onTap,
    required this.child,
  });

  @override
  State<_PulsingOrderCard> createState() => _PulsingOrderCardState();
}

class _PulsingOrderCardState extends State<_PulsingOrderCard> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final pulseValue = _animation.value;
        return GestureDetector(
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? const Color(0xFF10B981).withOpacity(0.08)
                  : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: widget.borderColor,
                width: widget.borderWidth + pulseValue * 0.5,
              ),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2)),
              ],
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

// ---- Data models ----

class _BrandGroup {
  final String brandName;
  final List<_ClientGroup> clients;
  final DateTime representativeDate;

  _BrandGroup({required this.brandName, required this.clients, required this.representativeDate});
}

class _ClientGroup {
  final String clientName;
  final List<Map<String, dynamic>> orders;
  final DateTime representativeDate;

  _ClientGroup({required this.clientName, required this.orders, required this.representativeDate});
}
