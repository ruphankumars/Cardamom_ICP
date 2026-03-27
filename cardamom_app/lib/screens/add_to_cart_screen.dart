import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/grade_grouped_dropdown.dart';

class AddToCartScreen extends StatefulWidget {
  const AddToCartScreen({super.key});

  @override
  State<AddToCartScreen> createState() => _AddToCartScreenState();
}

class _AddToCartScreenState extends State<AddToCartScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _pendingOrders = [];
  String _billingFilter = '';
  String _gradeFilter = '';
  String _searchQuery = '';
  final Set<int> _selectedIndices = {};
  
  // Floating button position
  Offset _fabPosition = const Offset(20, 500);

  // Get unique grade options from orders (sorted by GradeHelper)
  List<String> get _gradeOptions {
    final grades = _pendingOrders
        .map((o) => o['grade']?.toString() ?? '')
        .where((g) => g.isNotEmpty)
        .toSet()
        .toList();
    return GradeHelper.sorted(grades);
  }

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getPendingOrders();
      setState(() {
        _pendingOrders = response.data ?? [];
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading pending orders: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _submitToCart() async {
    final selectedIndices = _selectedIndices.toList();
    if (selectedIndices.isEmpty) return;

    final selectedOrders = selectedIndices.map((idx) => _pendingOrders[idx]).toList();
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
                  Text(
                    '${selectedOrders.length} order(s) selected',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 16),

                  // Today option
                  GestureDetector(
                    onTap: () {
                      setDialogState(() { isTodaySelected = true; selectedDate = null; });
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isTodaySelected ? const Color(0xFF10B981).withValues(alpha: 0.08) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isTodaySelected ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
                          width: isTodaySelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(isTodaySelected ? Icons.radio_button_checked : Icons.radio_button_off,
                            color: isTodaySelected ? const Color(0xFF10B981) : const Color(0xFF94A3B8), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('Today', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
                              Text(todayStr, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                            ]),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: const Color(0xFF8B5CF6).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
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
                        color: !isTodaySelected ? const Color(0xFF3B82F6).withValues(alpha: 0.08) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: !isTodaySelected ? const Color(0xFF3B82F6) : const Color(0xFFE2E8F0),
                          width: !isTodaySelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(!isTodaySelected ? Icons.radio_button_checked : Icons.radio_button_off,
                            color: !isTodaySelected ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(!isTodaySelected && selectedDate != null ? displayDate : 'Select Old Date',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                                  color: !isTodaySelected ? const Color(0xFF1E293B) : const Color(0xFF94A3B8))),
                              const Text('Tap to pick a date', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                            ]),
                          ),
                          const Icon(Icons.calendar_today, size: 18, color: Color(0xFF64748B)),
                          if (!isTodaySelected) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: const Color(0xFF3B82F6).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
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

  Future<void> _executeCartSubmission(List<dynamic> selectedOrders, String cartDate, bool markBilled) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      debugPrint('Sending ${selectedOrders.length} orders to cart (date: $cartDate, billed: $markBilled)');
      await _apiService.addToCart(selectedOrders, cartDate: cartDate, markBilled: markBilled);

      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      final addedIds = selectedOrders.map((e) => e['index'] ?? e['id']).toSet();
      setState(() {
        _pendingOrders.removeWhere((o) => addedIds.contains(o['index'] ?? o['id']));
        _selectedIndices.clear();
      });

      _showAddToCartSuccessModal(selectedOrders.length);
      _loadOrders();
    } catch (e) {
      debugPrint('Add to cart failed: $e');
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding to cart: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  void _showPartialModal(int idx) {
    final item = _pendingOrders[idx];
    final totalKgs = (num.tryParse(item['kgs'].toString()) ?? 0).toDouble();
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => _buildGlassDialog(
        title: '✂️ Partial Dispatch',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Enter quantity to dispatch (Total: $totalKgs kg)', style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
            const SizedBox(height: 20),
            TextField(
              controller: controller,
              decoration: _inputDecoration('Enter Kgs'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () async {
              final qty = double.tryParse(controller.text) ?? 0;
              if (qty <= 0 || qty >= totalKgs) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid quantity')));
                return;
              }
              Navigator.pop(ctx);
              
              // Show progress popup
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (loadingCtx) => _buildConstrainedDialog(
                  maxHeight: 180,
                  child: Material(
                    color: Colors.transparent,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF5D6E7E)),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Dispatching...',
                          style: TextStyle(color: Color(0xFF4A5568), fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              );

              try {
                final orderObj = {
                  'orderDate': item['orderDate'],
                  'billingFrom': item['billingFrom'],
                  'client': item['client'],
                  'lot': item['lot'],
                  'grade': item['grade'],
                  'bagbox': item['bagbox'],
                  'no': item['no'],
                  'kgs': item['kgs'],
                  'price': item['price'],
                  'brand': item['brand'],
                  'status': item['status'],
                  'notes': item['notes'],
                  'index': item['index']
                };
                await _apiService.partialDispatch(orderObj, qty);
                Navigator.pop(context); // Close progress popup
                _showSuccessModal();
              } catch (e) {
                Navigator.pop(context); // Close progress popup
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5D6E7E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text('Dispatch', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showSuccessModal() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: IntrinsicHeight(
          child: Container(
            width: 320,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 24, offset: const Offset(0, 12)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_circle_rounded, color: Color(0xFF22C55E), size: 36),
                ),
                const SizedBox(height: 20),
                const Text('Dispatch Complete', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                const SizedBox(height: 6),
                const Text('Order was successfully dispatched.', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _loadOrders();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A5568),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                    ),
                    child: const Text('Done', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAddToCartSuccessModal(int orderCount) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 300,
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 10)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_circle_rounded, color: Color(0xFF22C55E), size: 28),
                ),
                const SizedBox(height: 12),
                const Text('Added to Cart!', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                const SizedBox(height: 4),
                Text('$orderCount order(s) added.', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.pushNamed(context, '/daily_cart');
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF22C55E),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: const Text('📅 View Daily Cart', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Continue Adding', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNewOrderStyleButton({required String label, required VoidCallback onPressed, bool isPrimary = false}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: isPrimary ? null : Colors.white.withOpacity(0.5),
          foregroundColor: isPrimary ? Colors.white : const Color(0xFF334155),
          padding: const EdgeInsets.symmetric(vertical: 16),
          elevation: isPrimary ? 8 : 0,
          shadowColor: isPrimary ? const Color(0xFF4A5568).withOpacity(0.4) : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        ).copyWith(
          backgroundColor: isPrimary ? MaterialStateProperty.all(const Color(0xFF4A5568)) : null,
        ),
        child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildGlassDialog({required String title, required Widget content, required List<Widget> actions}) {
    return _buildConstrainedDialog(
      maxWidth: 500,
      maxHeight: 450,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
              const SizedBox(height: 24),
              content,
              const SizedBox(height: 32),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
      fillColor: Colors.white.withOpacity(0.5),
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = MediaQuery.of(context).size.width < 600;
    final screenSize = MediaQuery.of(context).size;
    
    return AppShell(
      disableInternalScrolling: true,
      title: '🧺 Add To Cart',
      subtitle: 'Select pending orders and push them into the packing cart.',
      topActions: [
        _buildNavBtn(label: 'Dashboard', onPressed: () { if (Navigator.canPop(context)) Navigator.pop(context); else Navigator.pushReplacementNamed(context, '/'); }, color: const Color(0xFF5D6E7E)),
        const SizedBox(width: 8),
        _buildNavBtn(label: 'Add Selected', onPressed: _submitToCart, color: const Color(0xFF22C55E)),
      ],
      // Use floatingActionButton to ensure it stays fixed on screen
      floatingActionButton: isMobile ? GestureDetector(
        onTap: _selectedIndices.isEmpty ? null : _submitToCart,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _selectedIndices.isNotEmpty 
                  ? [const Color(0xFF22C55E), const Color(0xFF16A34A)]
                  : [Colors.grey.shade400, Colors.grey.shade500],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _selectedIndices.isNotEmpty 
                    ? const Color(0xFF22C55E).withOpacity(0.4)
                    : Colors.grey.withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add_shopping_cart_rounded, color: Colors.white, size: 24),
                if (_selectedIndices.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_selectedIndices.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ) : null,
      content: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      decoration: AppTheme.glassDecoration,
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        children: [
                          const Text(
                            '🧺 Select Orders for Packing',
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF4A5568), letterSpacing: -0.5),
                          ),
                          const SizedBox(height: 32),
                          _buildFilters(),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildOrdersList(),
                // Add bottom padding for floating button clearance on mobile
                if (isMobile) const SizedBox(height: 100),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: color.withOpacity(0.3))),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }


  Widget _buildFilters() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        return Container(
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 0 : 20),
          child: Column(
            children: [
              if (isMobile) ...[
                DropdownButtonFormField<String>(
                  value: _billingFilter.isEmpty ? null : _billingFilter,
                  decoration: InputDecoration(
                    hintText: 'Billing',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
                  ),
                  borderRadius: BorderRadius.circular(20),
                  items: ['SYGT', 'ESPL'].map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: (val) => setState(() { _billingFilter = val ?? ''; _selectedIndices.clear(); }),
                ),
                const SizedBox(height: 12),
                GradeGroupedDropdown(
                  value: _gradeFilter.isEmpty ? null : _gradeFilter,
                  grades: _gradeOptions,
                  decoration: InputDecoration(
                    hintText: 'All Grades',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
                  ),
                  menuMaxHeight: 350,
                  onChanged: (val) => setState(() { _gradeFilter = val ?? ''; _selectedIndices.clear(); }),
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        value: _billingFilter.isEmpty ? null : _billingFilter,
                        decoration: InputDecoration(
                          hintText: 'Billing',
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
                        ),
                        borderRadius: BorderRadius.circular(20),
                        items: ['SYGT', 'ESPL'].map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 13)))).toList(),
                        onChanged: (val) => setState(() { _billingFilter = val ?? ''; _selectedIndices.clear(); }),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: GradeGroupedDropdown(
                        value: _gradeFilter.isEmpty ? null : _gradeFilter,
                        grades: _gradeOptions,
                        decoration: InputDecoration(
                          hintText: 'All Grades',
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
                        ),
                        menuMaxHeight: 350,
                        onChanged: (val) => setState(() { _gradeFilter = val ?? ''; _selectedIndices.clear(); }),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  hintText: isMobile ? 'Search...' : 'Search by Client or Grade...',
                  hintStyle: TextStyle(fontSize: isMobile ? 13 : 14),
                  filled: true,
                  fillColor: Colors.white,
                  prefixIcon: const Icon(Icons.search, color: Color(0xFF666666), size: 20),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
                  suffixIcon: (_billingFilter.isNotEmpty || _gradeFilter.isNotEmpty || _searchQuery.isNotEmpty)
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setState(() {
                            _billingFilter = '';
                            _gradeFilter = '';
                            _searchQuery = '';
                            _selectedIndices.clear();
                          }),
                        )
                      : null,
                ),
                onChanged: (val) => setState(() { _searchQuery = val; _selectedIndices.clear(); }),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOrdersList() {
    if (_pendingOrders.isEmpty) return const Center(child: Text('No pending orders.'));

    final Map<String, Map<String, List<int>>> grouped = {};
    for (int i = 0; i < _pendingOrders.length; i++) {
      final item = _pendingOrders[i];
      
      // Apply billing filter
      if (_billingFilter.isNotEmpty && item['billingFrom'] != _billingFilter) continue;
      
      // Apply grade filter
      final itemGrade = item['grade']?.toString().toLowerCase() ?? '';
      if (_gradeFilter.isNotEmpty && itemGrade != _gradeFilter.toLowerCase()) continue;
      
      // Apply search filter
      if (_searchQuery.isNotEmpty) {
        final client = item['client']?.toString().toLowerCase() ?? '';
        final grade = item['grade']?.toString().toLowerCase() ?? '';
        final brand = item['brand']?.toString().toLowerCase() ?? '';
        final searchLower = _searchQuery.toLowerCase();
        if (!client.contains(searchLower) && !grade.contains(searchLower) && !brand.contains(searchLower)) continue;
      }
      
      final date = item['orderDate'] ?? 'No Date';
      final client = item['client'] ?? 'Unknown';
      
      grouped.putIfAbsent(date, () => {});
      grouped[date]!.putIfAbsent(client, () => []).add(i);
    }

    if (grouped.isEmpty) return const Center(child: Text('No matching orders found.'));

    final sortedDates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      children: sortedDates.expand((date) {
        final clients = grouped[date]!;
        final sortedClients = clients.keys.toList()..sort();
        return [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.calendar_today, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text('📅 $date', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
          ),
          ...sortedClients.expand((client) {
            final indices = clients[client]!;
            return [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.person, size: 16, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('👤 $client', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14), overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
              ...indices.map((idx) => _buildOrderLine(idx)),
            ];
          })
        ];
      }).toList(),
    );
  }

  Widget _buildOrderLine(int idx) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final item = _pendingOrders[idx];
        final isSelected = _selectedIndices.contains(idx);
        final statusText = item['status']?.toString() ?? 'Pending';
        final isPending = statusText.toLowerCase() == 'pending';
        final hasNotes = item['notes'] != null && item['notes'].toString().trim().isNotEmpty;
        final brand = item['brand']?.toString() ?? '';

        return Container(
          margin: EdgeInsets.symmetric(vertical: 6, horizontal: isMobile ? 4 : 30),
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 4 : 18, vertical: isMobile ? 8 : 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(isSelected ? 0.95 : 0.9),
            borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
            border: Border.all(color: isSelected ? const Color(0xFF5D6E7E).withOpacity(0.5) : const Color(0xFFDDDDDD)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                offset: const Offset(0, 4),
                blurRadius: 10,
              ),
            ],
          ),
          child: InkWell(
            onTap: () {
              setState(() {
                if (isSelected) _selectedIndices.remove(idx);
                else _selectedIndices.add(idx);
              });
            },
            borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Line 1: Lot + Grade + Packaging + Kgs x Price
                          Text(
                            '${item['lot']}: ${item['grade']} - ${item['no']} ${item['bagbox']} - ${item['kgs']} kgs x ₹${item['price']}',
                            style: TextStyle(fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.w900, color: const Color(0xFF1E293B)),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          // Line 2: Brand + Notes + Status
                          Row(
                            children: [
                              if (brand.isNotEmpty) ...[
                                Text(
                                  '- $brand',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primary),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (hasNotes) ...[
                                const Icon(Icons.notes_rounded, size: 14, color: Color(0xFF94A3B8)),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    item['notes'].toString(),
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontStyle: FontStyle.italic, fontWeight: FontWeight.w500),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ] else
                                const Spacer(),
                              
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isPending ? const Color(0xFFF59E0B).withOpacity(0.15) : const Color(0xFF10B981).withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: isPending ? const Color(0xFFF59E0B).withOpacity(0.3) : const Color(0xFF10B981).withOpacity(0.3)),
                                ),
                                child: Text(
                                  statusText.toUpperCase(),
                                  style: TextStyle(
                                    color: isPending ? const Color(0xFFD97706) : const Color(0xFF059669),
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Action buttons
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(Icons.content_cut, color: const Color(0xFFF59E0B), size: isMobile ? 16 : 18),
                          onPressed: () => _showPartialModal(idx),
                          tooltip: 'Partial Dispatch',
                        ),
                        if (!isMobile) const SizedBox(width: 8) else const SizedBox(width: 4),
                        Container(
                          width: isMobile ? 18 : 24,
                          height: isMobile ? 18 : 24,
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF5D6E7E) : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: isSelected ? const Color(0xFF5D6E7E) : const Color(0xFFCBD5E1), width: 1.5),
                          ),
                          child: isSelected ? Icon(Icons.check, size: isMobile ? 12 : 16, color: Colors.white) : null,
                        ),
                      ],
                    ),
                  ],
                ),
                if (hasNotes)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.notes, size: 12, color: Color(0xFF64748B)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${item['notes']}',
                            style: TextStyle(fontSize: isMobile ? 12 : 13, color: const Color(0xFF64748B), fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildConstrainedDialog({
    required Widget child,
    double maxWidth = 320,
    double maxHeight = 280,
  }) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.92),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withOpacity(0.5),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

