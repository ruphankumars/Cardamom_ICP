import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

class WebDailyCart extends StatefulWidget {
  const WebDailyCart({super.key});

  @override
  State<WebDailyCart> createState() => _WebDailyCartState();
}

class _WebDailyCartState extends State<WebDailyCart> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;

  List<dynamic> _cartItems = [];
  List<dynamic> _pendingOrders = [];
  String _statusFilter = '';
  String _billingFilter = '';
  DateTime _selectedDate = DateTime.now();

  final Set<int> _selectedForRemoval = {};

  @override
  void initState() {
    super.initState();
    _loadCart();
  }

  Future<void> _loadCart() async {
    setState(() => _isLoading = true);
    try {
      final responses = await Future.wait([
        _apiService.getTodayCart(),
        _apiService.getPendingOrders(),
      ]);
      if (!mounted) return;
      setState(() {
        _cartItems = List<dynamic>.from(responses[0].data ?? []);
        _pendingOrders = List<dynamic>.from(responses[1].data ?? []);
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading daily cart: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<dynamic> get _filteredItems {
    var items = List.from(_cartItems);

    if (_statusFilter.isNotEmpty) {
      items = items
          .where((item) =>
              (item['status'] ?? '').toString().toLowerCase() ==
              _statusFilter.toLowerCase())
          .toList();
    }

    if (_billingFilter.isNotEmpty) {
      items = items
          .where((item) =>
              (item['billingFrom'] ?? item['billing'] ?? '')
                  .toString()
                  .toUpperCase() ==
              _billingFilter.toUpperCase())
          .toList();
    }

    return items;
  }

  double get _totalAmount {
    double total = 0;
    for (final item in _filteredItems) {
      final kgs = _parseNum(item['kgs']);
      final price = _parseNum(item['price'] ?? item['unitPrice']);
      total += kgs * price;
    }
    return total;
  }

  double get _totalKgs {
    double total = 0;
    for (final item in _filteredItems) {
      total += _parseNum(item['kgs']);
    }
    return total;
  }

  int get _totalItems => _filteredItems.length;

  double _parseNum(dynamic val) {
    if (val == null) return 0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0;
  }

  Future<void> _removeFromCart(dynamic item) async {
    final lot = (item['lot'] ?? '').toString();
    final client = (item['client'] ?? '').toString();
    final billing = (item['billingFrom'] ?? item['billing'] ?? '').toString();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Remove from Cart',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Remove $client - $lot from today\'s cart?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _apiService.removeFromCart(lot, client, billing);
        await _loadCart();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Removed from cart'),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: $e'),
              backgroundColor: const Color(0xFFEF4444),
            ),
          );
        }
      }
    }
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (date != null) {
      setState(() => _selectedDate = date);
      _loadCart();
    }
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
            const SizedBox(height: 12),
            _buildTotalsSummary(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Text(
          'Daily Cart',
          style: GoogleFonts.manrope(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF1E293B),
          ),
        ),
        const SizedBox(width: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF5D6E7E).withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$_totalItems items',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF5D6E7E),
            ),
          ),
        ),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: _loadCart,
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
          // Date picker
          InkWell(
            onTap: _pickDate,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_outlined,
                      size: 16, color: Color(0xFF64748B)),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('dd MMM yyyy').format(_selectedDate),
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF1E293B),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Status filter
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _statusFilter.isEmpty ? null : _statusFilter,
                  hint: Text('All Statuses',
                      style: GoogleFonts.inter(
                          fontSize: 13, color: const Color(0xFF94A3B8))),
                  isExpanded: true,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  style: GoogleFonts.inter(
                      fontSize: 13, color: const Color(0xFF1E293B)),
                  items: [
                    DropdownMenuItem<String>(
                      value: null,
                      child: Text('All Statuses',
                          style: GoogleFonts.inter(
                              fontSize: 13, color: const Color(0xFF94A3B8))),
                    ),
                    ...['Pending', 'On Progress', 'Billed'].map(
                      (s) => DropdownMenuItem(value: s, child: Text(s)),
                    ),
                  ],
                  onChanged: (v) => setState(() => _statusFilter = v ?? ''),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Billing filter
          Expanded(
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
                  onChanged: (v) => setState(() => _billingFilter = v ?? ''),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          TextButton.icon(
            onPressed: () {
              setState(() {
                _statusFilter = '';
                _billingFilter = '';
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

    final items = _filteredItems;
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shopping_cart_outlined,
                size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'Cart is empty',
              style: GoogleFonts.manrope(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add orders to the daily cart to see them here.',
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
                DataColumn(label: Text('Status', style: _headerStyle())),
                DataColumn(label: Text('Actions', style: _headerStyle())),
              ],
              rows: items.asMap().entries.map((entry) {
                final item = entry.value;
                final client = (item['client'] ?? '').toString();
                final lot = (item['lot'] ?? '').toString();
                final grade = (item['grade'] ?? '').toString();
                final kgs = _parseNum(item['kgs']);
                final price = _parseNum(item['price'] ?? item['unitPrice']);
                final amount = kgs * price;
                final billing =
                    (item['billingFrom'] ?? item['billing'] ?? '').toString();
                final status = (item['status'] ?? '').toString();

                return DataRow(
                  cells: [
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
                    DataCell(
                        Text(_formatNumber(kgs), style: _cellStyle())),
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
                    DataCell(_buildStatusBadge(status)),
                    DataCell(
                      InkWell(
                        onTap: () => _removeFromCart(item),
                        borderRadius: BorderRadius.circular(8),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(Icons.remove_circle_outline,
                              size: 18, color: Color(0xFFEF4444)),
                        ),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTotalsSummary() {
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          _summaryItem('Total Items', '$_totalItems'),
          const SizedBox(width: 32),
          _summaryItem('Total Qty', '${_formatNumber(_totalKgs)} kg'),
          const SizedBox(width: 32),
          _summaryItem('Total Amount', _formatCurrency(_totalAmount)),
          const Spacer(),
          if (_pendingOrders.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${_pendingOrders.length} pending orders',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFFF59E0B),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _summaryItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: GoogleFonts.manrope(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF1E293B),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(String status) {
    final Map<String, Color> colors = {
      'Pending': const Color(0xFF3B82F6),
      'On Progress': const Color(0xFFF97316),
      'Billed': const Color(0xFF10B981),
      'Cancelled': const Color(0xFFEF4444),
    };
    final color = colors[status] ?? const Color(0xFF6B7280);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
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
