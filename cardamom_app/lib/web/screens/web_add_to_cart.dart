import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';
import '../../widgets/grade_grouped_dropdown.dart';

class WebAddToCart extends StatefulWidget {
  const WebAddToCart({super.key});

  @override
  State<WebAddToCart> createState() => _WebAddToCartState();
}

class _WebAddToCartState extends State<WebAddToCart> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  bool _isSubmitting = false;

  List<dynamic> _pendingOrders = [];
  Map<String, dynamic> _dropdowns = {};

  String _billingFilter = '';
  String _gradeFilter = '';
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final Set<int> _selectedIndices = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final responses = await Future.wait([
        _apiService.getPendingOrders(),
        _apiService.getDropdownOptions(),
      ]);
      if (!mounted) return;
      setState(() {
        _pendingOrders = List<dynamic>.from(responses[0].data ?? []);
        _dropdowns = Map<String, dynamic>.from(responses[1].data ?? {});
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading data: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<String> get _gradeOptions {
    final grades = _pendingOrders
        .map((o) => (o['grade'] ?? '').toString())
        .where((g) => g.isNotEmpty)
        .toSet()
        .toList();
    return GradeHelper.sorted(grades);
  }

  List<dynamic> get _filteredOrders {
    var orders = List.from(_pendingOrders);

    if (_billingFilter.isNotEmpty) {
      orders = orders
          .where((o) =>
              (o['billingFrom'] ?? o['billing'] ?? '')
                  .toString()
                  .toUpperCase() ==
              _billingFilter.toUpperCase())
          .toList();
    }

    if (_gradeFilter.isNotEmpty) {
      orders = orders
          .where((o) =>
              (o['grade'] ?? '').toString().toLowerCase() ==
              _gradeFilter.toLowerCase())
          .toList();
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      orders = orders.where((o) {
        final client = (o['client'] ?? '').toString().toLowerCase();
        final grade = (o['grade'] ?? '').toString().toLowerCase();
        final lot = (o['lot'] ?? '').toString().toLowerCase();
        return client.contains(q) || grade.contains(q) || lot.contains(q);
      }).toList();
    }

    return orders;
  }

  double _parseNum(dynamic val) {
    if (val == null) return 0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0;
  }

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_selectedIndices.length == _filteredOrders.length) {
        _selectedIndices.clear();
      } else {
        _selectedIndices.clear();
        for (int i = 0; i < _filteredOrders.length; i++) {
          _selectedIndices.add(i);
        }
      }
    });
  }

  Future<void> _submitToCart() async {
    if (_selectedIndices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one order'),
          backgroundColor: Color(0xFFF59E0B),
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final filtered = _filteredOrders;
      final selectedOrders =
          _selectedIndices.map((idx) => filtered[idx]).toList();

      await _apiService.addToCart(selectedOrders);

      if (!mounted) return;

      final count = selectedOrders.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$count order(s) added to cart'),
          backgroundColor: const Color(0xFF10B981),
        ),
      );

      setState(() => _selectedIndices.clear());
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding to cart: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }

    if (mounted) setState(() => _isSubmitting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 20),
            _buildFilterBar(),
            const SizedBox(height: 16),
            Expanded(child: _buildBody()),
            if (_selectedIndices.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildSubmitBar(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Text(
          'Add to Cart',
          style: GoogleFonts.manrope(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF1E293B),
          ),
        ),
        const SizedBox(width: 16),
        if (_pendingOrders.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF3B82F6).withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${_pendingOrders.length} pending',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF3B82F6),
              ),
            ),
          ),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: _loadData,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Refresh'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF5D6E7E),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Search
          Expanded(
            flex: 3,
            child: TextField(
              controller: _searchController,
              onChanged: (v) {
                setState(() {
                  _searchQuery = v;
                  _selectedIndices.clear();
                });
              },
              style: GoogleFonts.inter(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search by client, grade, lot...',
                hintStyle: GoogleFonts.inter(
                    fontSize: 13, color: const Color(0xFF94A3B8)),
                prefixIcon: const Icon(Icons.search,
                    size: 18, color: Color(0xFF94A3B8)),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _selectedIndices.clear();
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFFF8F9FA),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF5D6E7E), width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Billing
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _billingFilter.isEmpty ? null : _billingFilter,
                  hint: Text('All Billing',
                      style: GoogleFonts.inter(
                          fontSize: 13, color: const Color(0xFF94A3B8))),
                  isExpanded: true,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  style: GoogleFonts.inter(
                      fontSize: 13, color: const Color(0xFF1E293B)),
                  items: [
                    DropdownMenuItem<String>(
                      value: null,
                      child: Text('All Billing',
                          style: GoogleFonts.inter(
                              fontSize: 13, color: const Color(0xFF94A3B8))),
                    ),
                    ...['SYGT', 'ESPL'].map(
                      (s) => DropdownMenuItem(value: s, child: Text(s)),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _billingFilter = v ?? '';
                      _selectedIndices.clear();
                    });
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Grade
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _gradeFilter.isEmpty ? null : _gradeFilter,
                  hint: Text('All Grades',
                      style: GoogleFonts.inter(
                          fontSize: 13, color: const Color(0xFF94A3B8))),
                  isExpanded: true,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  style: GoogleFonts.inter(
                      fontSize: 13, color: const Color(0xFF1E293B)),
                  items: [
                    DropdownMenuItem<String>(
                      value: null,
                      child: Text('All Grades',
                          style: GoogleFonts.inter(
                              fontSize: 13, color: const Color(0xFF94A3B8))),
                    ),
                    ..._gradeOptions.map(
                      (s) => DropdownMenuItem(value: s, child: Text(s)),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _gradeFilter = v ?? '';
                      _selectedIndices.clear();
                    });
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          TextButton.icon(
            onPressed: () {
              _searchController.clear();
              setState(() {
                _billingFilter = '';
                _gradeFilter = '';
                _searchQuery = '';
                _selectedIndices.clear();
              });
            },
            icon: const Icon(Icons.filter_alt_off, size: 16),
            label: Text('Clear', style: GoogleFonts.inter(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF5D6E7E)),
      );
    }

    final orders = _filteredOrders;
    if (orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'No pending orders',
              style: GoogleFonts.manrope(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'All orders have been added to the cart.',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: const Color(0xFFB0BEC5),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: MediaQuery.of(context).size.width - 48,
            ),
            child: DataTable(
              headingRowColor:
                  WidgetStateProperty.all(const Color(0xFFF1F5F9)),
              headingRowHeight: 48,
              dataRowMinHeight: 48,
              dataRowMaxHeight: 56,
              columnSpacing: 24,
              horizontalMargin: 20,
              columns: [
                DataColumn(
                  label: Checkbox(
                    value: _selectedIndices.length == orders.length &&
                        orders.isNotEmpty,
                    onChanged: (_) => _selectAll(),
                    activeColor: const Color(0xFF5D6E7E),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                DataColumn(label: Text('Client', style: _headerStyle())),
                DataColumn(label: Text('Lot', style: _headerStyle())),
                DataColumn(label: Text('Grade', style: _headerStyle())),
                DataColumn(
                  label: Text('Qty (kg)', style: _headerStyle()),
                  numeric: true,
                ),
                DataColumn(
                  label: Text('Price', style: _headerStyle()),
                  numeric: true,
                ),
                DataColumn(
                  label: Text('Amount', style: _headerStyle()),
                  numeric: true,
                ),
                DataColumn(label: Text('Billing', style: _headerStyle())),
                DataColumn(label: Text('Notes', style: _headerStyle())),
              ],
              rows: List.generate(orders.length, (index) {
                final o = orders[index];
                final client = (o['client'] ?? '').toString();
                final lot = (o['lot'] ?? '').toString();
                final grade = (o['grade'] ?? '').toString();
                final kgs = _parseNum(o['kgs']);
                final price = _parseNum(o['price'] ?? o['unitPrice']);
                final amount = kgs * price;
                final billing =
                    (o['billingFrom'] ?? o['billing'] ?? '').toString();
                final notes = (o['notes'] ?? '').toString();
                final isSelected = _selectedIndices.contains(index);

                return DataRow(
                  selected: isSelected,
                  onSelectChanged: (_) => _toggleSelection(index),
                  color: WidgetStateProperty.resolveWith<Color?>(
                    (states) {
                      if (states.contains(WidgetState.selected)) {
                        return const Color(0xFF5D6E7E).withOpacity(0.05);
                      }
                      return null;
                    },
                  ),
                  cells: [
                    DataCell(
                      Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggleSelection(index),
                        activeColor: const Color(0xFF5D6E7E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(client,
                            style: _cellStyle(bold: true),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    DataCell(Text(lot, style: _cellStyle())),
                    DataCell(Text(grade, style: _cellStyle())),
                    DataCell(Text(_formatNumber(kgs),
                        style: _cellStyle())),
                    DataCell(Text(_formatCurrency(price),
                        style: _cellStyle())),
                    DataCell(Text(_formatCurrency(amount),
                        style: _cellStyle(bold: true))),
                    DataCell(
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          billing,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF475569),
                          ),
                        ),
                      ),
                    ),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Text(
                          notes,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: const Color(0xFF64748B),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubmitBar() {
    final filtered = _filteredOrders;
    double selectedKgs = 0;
    double selectedAmount = 0;
    for (final idx in _selectedIndices) {
      if (idx < filtered.length) {
        final o = filtered[idx];
        final kgs = _parseNum(o['kgs']);
        final price = _parseNum(o['price'] ?? o['unitPrice']);
        selectedKgs += kgs;
        selectedAmount += kgs * price;
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF5D6E7E).withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${_selectedIndices.length} selected',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF5D6E7E),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            '${_formatNumber(selectedKgs)} kg',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: const Color(0xFF64748B),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            _formatCurrency(selectedAmount),
            style: GoogleFonts.manrope(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF1E293B),
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() => _selectedIndices.clear()),
            child: Text(
              'Clear Selection',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: const Color(0xFF64748B),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _isSubmitting ? null : _submitToCart,
            icon: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.add_shopping_cart, size: 18),
            label: Text(
              'Add to Cart',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5D6E7E),
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              disabledBackgroundColor:
                  const Color(0xFF5D6E7E).withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _headerStyle() {
    return GoogleFonts.inter(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF475569),
    );
  }

  TextStyle _cellStyle({bool bold = false}) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      color: const Color(0xFF1E293B),
    );
  }

  String _formatNumber(double val) {
    if (val == val.truncateToDouble()) return val.toInt().toString();
    return val.toStringAsFixed(2);
  }

  String _formatCurrency(double val) {
    final f = NumberFormat('#,##0.##', 'en_IN');
    return f.format(val);
  }
}
