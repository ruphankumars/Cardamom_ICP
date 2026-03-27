import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

class WebViewOrders extends StatefulWidget {
  const WebViewOrders({super.key});

  @override
  State<WebViewOrders> createState() => _WebViewOrdersState();
}

class _WebViewOrdersState extends State<WebViewOrders> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  Map<String, dynamic> _ordersData = {};
  Map<String, dynamic> _dropdownOptions = {
    'grade': [],
    'bagbox': [],
    'brand': [],
  };

  String _statusFilter = 'Pending';
  String _billingFilter = '';
  String _gradeFilter = '';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  int _currentPage = 1;
  final int _rowsPerPage = 25;

  String _sortColumn = 'date';
  bool _sortAscending = false;

  String _userRole = 'user';

  // Flattened order rows for table display
  List<Map<String, dynamic>> _flatOrders = [];

  static const List<String> _statusTabs = [
    'All',
    'Pending',
    'On Progress',
    'Billed',
    'Cancelled',
  ];

  static const Map<String, Color> _statusColors = {
    'Pending': Color(0xFF3B82F6),
    'On Progress': Color(0xFFF97316),
    'Admin Sent': Color(0xFFF97316),
    'Client Draft': Color(0xFFEAB308),
    'Client Sent': Color(0xFFA855F7),
    'Confirmed': Color(0xFF10B981),
    'Billed': Color(0xFF10B981),
    'Cancelled': Color(0xFFEF4444),
  };

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';
      await Future.wait([
        _loadOrders(),
        _loadDropdowns(),
      ]);
    } catch (e) {
      debugPrint('Error loading initial data: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadOrders() async {
    try {
      final response = await _apiService.getOrders();
      if (!mounted) return;
      var rawData = response.data;
      if (rawData is Map &&
          rawData.containsKey('data') &&
          rawData.containsKey('pagination')) {
        rawData = rawData['data'];
      }
      if (rawData is Map) {
        _ordersData = Map<String, dynamic>.from(rawData);
      } else {
        _ordersData = {};
      }
      _flattenOrders();
    } catch (e) {
      debugPrint('Error loading orders: $e');
    }
  }

  Future<void> _loadDropdowns() async {
    try {
      final response = await _apiService.getDropdownOptions();
      if (!mounted) return;
      _dropdownOptions = Map<String, dynamic>.from(response.data);
    } catch (e) {
      debugPrint('Error loading dropdowns: $e');
    }
  }

  void _flattenOrders() {
    final List<Map<String, dynamic>> flat = [];
    _ordersData.forEach((date, clients) {
      if (clients is Map) {
        clients.forEach((clientName, rows) {
          if (rows is List) {
            for (var row in rows) {
              if (row is List && row.length >= 11) {
                final rawId = row.length > 12
                    ? row[row.length - 1].toString()
                    : '';
                final docId =
                    rawId.startsWith('-') ? rawId.substring(1) : rawId;
                flat.add({
                  'date': row[0]?.toString() ?? '',
                  'billing': row[1]?.toString() ?? '',
                  'client': row[2]?.toString() ?? clientName.toString(),
                  'lot': row[3]?.toString() ?? '',
                  'grade': row[4]?.toString() ?? '',
                  'bagbox': row[5]?.toString() ?? '',
                  'no': _parseNum(row[6]),
                  'kgs': _parseNum(row[7]),
                  'price': _parseNum(row[8]),
                  'brand': row[9]?.toString() ?? '',
                  'status': row[10]?.toString() ?? '',
                  'notes': row.length > 11 ? (row[11]?.toString() ?? '') : '',
                  'docId': docId,
                  'rawRow': row,
                });
              }
            }
          }
        });
      }
    });
    _flatOrders = flat;
  }

  double _parseNum(dynamic val) {
    if (val == null) return 0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0;
  }

  List<Map<String, dynamic>> get _filteredOrders {
    var orders = List<Map<String, dynamic>>.from(_flatOrders);

    // Status filter
    if (_statusFilter.isNotEmpty && _statusFilter != 'All') {
      orders = orders.where((o) {
        final s = o['status'].toString().toLowerCase();
        final filter = _statusFilter.toLowerCase();
        if (filter == 'pending') return s == 'pending';
        if (filter == 'on progress') {
          return s == 'on progress' ||
              s == 'admin sent' ||
              s == 'client draft' ||
              s == 'client sent' ||
              s == 'confirmed';
        }
        if (filter == 'billed') return s == 'billed';
        if (filter == 'cancelled') return s == 'cancelled';
        return true;
      }).toList();
    }

    // Billing filter
    if (_billingFilter.isNotEmpty) {
      orders = orders
          .where((o) =>
              o['billing'].toString().toUpperCase() ==
              _billingFilter.toUpperCase())
          .toList();
    }

    // Grade filter
    if (_gradeFilter.isNotEmpty) {
      orders = orders
          .where((o) =>
              o['grade'].toString().toLowerCase() ==
              _gradeFilter.toLowerCase())
          .toList();
    }

    // Search
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      orders = orders.where((o) {
        return o['client'].toString().toLowerCase().contains(q) ||
            o['lot'].toString().toLowerCase().contains(q) ||
            o['grade'].toString().toLowerCase().contains(q) ||
            o['brand'].toString().toLowerCase().contains(q) ||
            o['notes'].toString().toLowerCase().contains(q);
      }).toList();
    }

    // Sorting
    orders.sort((a, b) {
      dynamic valA;
      dynamic valB;
      switch (_sortColumn) {
        case 'date':
          valA = a['date'];
          valB = b['date'];
          break;
        case 'client':
          valA = a['client'];
          valB = b['client'];
          break;
        case 'grade':
          valA = a['grade'];
          valB = b['grade'];
          break;
        case 'qty':
          valA = a['kgs'];
          valB = b['kgs'];
          break;
        case 'price':
          valA = a['price'];
          valB = b['price'];
          break;
        case 'amount':
          valA = (a['kgs'] as double) * (a['price'] as double);
          valB = (b['kgs'] as double) * (b['price'] as double);
          break;
        default:
          valA = a['date'];
          valB = b['date'];
      }
      int cmp;
      if (valA is num && valB is num) {
        cmp = valA.compareTo(valB);
      } else {
        cmp = valA.toString().compareTo(valB.toString());
      }
      return _sortAscending ? cmp : -cmp;
    });

    return orders;
  }

  List<Map<String, dynamic>> get _paginatedOrders {
    final filtered = _filteredOrders;
    final start = (_currentPage - 1) * _rowsPerPage;
    if (start >= filtered.length) return [];
    final end =
        (start + _rowsPerPage) > filtered.length ? filtered.length : start + _rowsPerPage;
    return filtered.sublist(start, end);
  }

  int get _totalPages =>
      (_filteredOrders.length / _rowsPerPage).ceil().clamp(1, 9999);

  void _onSort(String column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = true;
      }
    });
  }

  Future<void> _deleteOrderById(String docId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Delete Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: const Text('Are you sure? This cannot be undone.'),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await _apiService.deleteOrder(docId);
        await _refreshData();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Order deleted'),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting order: $e'),
              backgroundColor: const Color(0xFFEF4444),
            ),
          );
        }
      }
    }
  }

  Future<void> _refreshData() async {
    setState(() => _isLoading = true);
    await _loadOrders();
    if (mounted) setState(() => _isLoading = false);
  }

  Color _statusColor(String status) {
    return _statusColors[status] ?? const Color(0xFF6B7280);
  }

  Color _statusBg(String status) {
    return _statusColor(status).withOpacity(0.1);
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
            _buildStatusTabs(),
            const SizedBox(height: 16),
            _buildFilterBar(),
            const SizedBox(height: 16),
            Expanded(child: _buildBody()),
            const SizedBox(height: 12),
            _buildPagination(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Text(
          'Orders',
          style: GoogleFonts.manrope(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF1E293B),
          ),
        ),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: _refreshData,
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

  Widget _buildStatusTabs() {
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
      padding: const EdgeInsets.all(4),
      child: Row(
        children: _statusTabs.map((tab) {
          final isActive =
              (tab == 'All' && _statusFilter.isEmpty) || _statusFilter == tab;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _statusFilter = tab == 'All' ? '' : tab;
                  _currentPage = 1;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0xFF5D6E7E)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  tab,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isActive ? Colors.white : const Color(0xFF64748B),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFilterBar() {
    final grades = <String>[];
    final gradeList = _dropdownOptions['grade'];
    if (gradeList is List) {
      for (var g in gradeList) {
        final val = g is Map ? (g['value'] ?? g['name'] ?? g.toString()) : g.toString();
        if (val.toString().isNotEmpty) grades.add(val.toString());
      }
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
                  _currentPage = 1;
                });
              },
              style: GoogleFonts.inter(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search by client, lot, grade...',
                hintStyle: GoogleFonts.inter(
                  fontSize: 13,
                  color: const Color(0xFF94A3B8),
                ),
                prefixIcon:
                    const Icon(Icons.search, size: 18, color: Color(0xFF94A3B8)),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _currentPage = 1;
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

          // Billing dropdown
          Expanded(
            flex: 2,
            child: _buildDropdown(
              value: _billingFilter.isEmpty ? null : _billingFilter,
              hint: 'Billing',
              items: const ['SYGT', 'ESPL'],
              onChanged: (v) {
                setState(() {
                  _billingFilter = v ?? '';
                  _currentPage = 1;
                });
              },
            ),
          ),
          const SizedBox(width: 12),

          // Grade dropdown
          Expanded(
            flex: 2,
            child: _buildDropdown(
              value: _gradeFilter.isEmpty ? null : _gradeFilter,
              hint: 'Grade',
              items: grades,
              onChanged: (v) {
                setState(() {
                  _gradeFilter = v ?? '';
                  _currentPage = 1;
                });
              },
            ),
          ),
          const SizedBox(width: 12),

          // Clear filters
          TextButton.icon(
            onPressed: () {
              setState(() {
                _billingFilter = '';
                _gradeFilter = '';
                _searchQuery = '';
                _searchController.clear();
                _currentPage = 1;
              });
            },
            icon: const Icon(Icons.filter_alt_off, size: 16),
            label: Text(
              'Clear',
              style: GoogleFonts.inter(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String? value,
    required String hint,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(
            hint,
            style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8)),
          ),
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down, size: 18),
          style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF1E293B)),
          items: [
            DropdownMenuItem<String>(
              value: null,
              child: Text('All $hint',
                  style: GoogleFonts.inter(
                      fontSize: 13, color: const Color(0xFF94A3B8))),
            ),
            ...items.map((item) => DropdownMenuItem(
                  value: item,
                  child: Text(item),
                )),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF5D6E7E)),
      );
    }

    final orders = _paginatedOrders;
    if (_filteredOrders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'No orders found',
              style: GoogleFonts.manrope(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try adjusting your filters or search query.',
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
              columnSpacing: 20,
              horizontalMargin: 20,
              columns: [
                DataColumn(
                  label: Text('#',
                      style: _headerStyle()),
                ),
                DataColumn(
                  label: _sortableHeader('Date', 'date'),
                  onSort: (_, __) => _onSort('date'),
                ),
                DataColumn(
                  label: _sortableHeader('Client', 'client'),
                  onSort: (_, __) => _onSort('client'),
                ),
                DataColumn(
                  label: Text('Lot', style: _headerStyle()),
                ),
                DataColumn(
                  label: _sortableHeader('Grade', 'grade'),
                  onSort: (_, __) => _onSort('grade'),
                ),
                DataColumn(
                  label: _sortableHeader('Qty (kg)', 'qty'),
                  numeric: true,
                  onSort: (_, __) => _onSort('qty'),
                ),
                DataColumn(
                  label: _sortableHeader('Price', 'price'),
                  numeric: true,
                  onSort: (_, __) => _onSort('price'),
                ),
                DataColumn(
                  label: _sortableHeader('Amount', 'amount'),
                  numeric: true,
                  onSort: (_, __) => _onSort('amount'),
                ),
                DataColumn(
                  label: Text('Billing', style: _headerStyle()),
                ),
                DataColumn(
                  label: Text('Status', style: _headerStyle()),
                ),
                DataColumn(
                  label: Text('Actions', style: _headerStyle()),
                ),
              ],
              rows: List.generate(orders.length, (index) {
                final o = orders[index];
                final rowNum = (_currentPage - 1) * _rowsPerPage + index + 1;
                final amount = (o['kgs'] as double) * (o['price'] as double);
                final status = o['status']?.toString() ?? '';
                final docId = o['docId']?.toString() ?? '';

                return DataRow(
                  cells: [
                    DataCell(Text('$rowNum', style: _cellStyle())),
                    DataCell(Text(_formatDate(o['date']?.toString() ?? ''),
                        style: _cellStyle())),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          o['client']?.toString() ?? '',
                          style: _cellStyle(bold: true),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    DataCell(Text(o['lot']?.toString() ?? '',
                        style: _cellStyle())),
                    DataCell(Text(o['grade']?.toString() ?? '',
                        style: _cellStyle())),
                    DataCell(Text(
                      _formatNumber(o['kgs'] as double),
                      style: _cellStyle(),
                    )),
                    DataCell(Text(
                      _formatCurrency(o['price'] as double),
                      style: _cellStyle(),
                    )),
                    DataCell(Text(
                      _formatCurrency(amount),
                      style: _cellStyle(bold: true),
                    )),
                    DataCell(
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          o['billing']?.toString() ?? '',
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _actionIcon(
                            Icons.edit_outlined,
                            const Color(0xFF3B82F6),
                            () => _onEditOrder(o),
                          ),
                          const SizedBox(width: 4),
                          if (docId.isNotEmpty)
                            _actionIcon(
                              Icons.delete_outline,
                              const Color(0xFFEF4444),
                              () => _deleteOrderById(docId),
                            ),
                        ],
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

  Widget _sortableHeader(String text, String column) {
    final isActive = _sortColumn == column;
    return InkWell(
      onTap: () => _onSort(column),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: _headerStyle()),
          if (isActive) ...[
            const SizedBox(width: 4),
            Icon(
              _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: const Color(0xFF5D6E7E),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    final color = _statusColor(status);
    final bg = _statusBg(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
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

  Widget _actionIcon(IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }

  Widget _buildPagination() {
    final totalFiltered = _filteredOrders.length;
    final start = totalFiltered > 0
        ? ((_currentPage - 1) * _rowsPerPage + 1)
        : 0;
    final end = (_currentPage * _rowsPerPage).clamp(0, totalFiltered);

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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Text(
            'Showing $start - $end of $totalFiltered orders',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: const Color(0xFF64748B),
            ),
          ),
          const Spacer(),
          _paginationButton(
            Icons.chevron_left,
            _currentPage > 1,
            () => setState(() => _currentPage--),
          ),
          const SizedBox(width: 8),
          ..._buildPageNumbers(),
          const SizedBox(width: 8),
          _paginationButton(
            Icons.chevron_right,
            _currentPage < _totalPages,
            () => setState(() => _currentPage++),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPageNumbers() {
    final List<Widget> pages = [];
    final total = _totalPages;
    final current = _currentPage;

    List<int> pageNumbers = [];
    if (total <= 7) {
      pageNumbers = List.generate(total, (i) => i + 1);
    } else {
      pageNumbers = [1];
      if (current > 3) pageNumbers.add(-1); // ellipsis
      for (int i = (current - 1).clamp(2, total - 1);
          i <= (current + 1).clamp(2, total - 1);
          i++) {
        pageNumbers.add(i);
      }
      if (current < total - 2) pageNumbers.add(-1); // ellipsis
      pageNumbers.add(total);
    }

    for (final p in pageNumbers) {
      if (p == -1) {
        pages.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('...',
                style: GoogleFonts.inter(
                    fontSize: 13, color: const Color(0xFF94A3B8))),
          ),
        );
      } else {
        final isActive = p == current;
        pages.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              onTap: () => setState(() => _currentPage = p),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0xFF5D6E7E)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$p',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight:
                        isActive ? FontWeight.w600 : FontWeight.w400,
                    color:
                        isActive ? Colors.white : const Color(0xFF64748B),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    return pages;
  }

  Widget _paginationButton(
      IconData icon, bool enabled, VoidCallback onTap) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 20,
          color: enabled ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
        ),
      ),
    );
  }

  void _onEditOrder(Map<String, dynamic> order) {
    // Show an edit dialog for the order
    final controllers = {
      'lot': TextEditingController(text: order['lot']?.toString() ?? ''),
      'grade': TextEditingController(text: order['grade']?.toString() ?? ''),
      'kgs': TextEditingController(text: _formatNumber(order['kgs'] as double)),
      'price':
          TextEditingController(text: _formatNumber(order['price'] as double)),
      'notes': TextEditingController(text: order['notes']?.toString() ?? ''),
    };

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Edit Order',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogField('Lot', controllers['lot']!),
              const SizedBox(height: 12),
              _dialogField('Grade', controllers['grade']!),
              const SizedBox(height: 12),
              _dialogField('Qty (kgs)', controllers['kgs']!,
                  keyboardType: TextInputType.number),
              const SizedBox(height: 12),
              _dialogField('Price', controllers['price']!,
                  keyboardType: TextInputType.number),
              const SizedBox(height: 12),
              _dialogField('Notes', controllers['notes']!, maxLines: 2),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final docId = order['docId']?.toString() ?? '';
              if (docId.isEmpty) return;
              try {
                await _apiService.updateOrder(docId, {
                  'lot': controllers['lot']!.text,
                  'grade': controllers['grade']!.text,
                  'kgs': double.tryParse(controllers['kgs']!.text) ?? 0,
                  'price': double.tryParse(controllers['price']!.text) ?? 0,
                  'notes': controllers['notes']!.text,
                });
                await _refreshData();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Order updated'),
                      backgroundColor: Color(0xFF10B981),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error updating order: $e'),
                      backgroundColor: const Color(0xFFEF4444),
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5D6E7E),
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _dialogField(String label, TextEditingController controller,
      {TextInputType? keyboardType, int maxLines = 1}) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: GoogleFonts.inter(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B)),
        filled: true,
        fillColor: const Color(0xFFF8F9FA),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
          borderSide: const BorderSide(color: Color(0xFF5D6E7E), width: 1.5),
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

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('dd MMM yyyy').format(date);
    } catch (_) {
      return dateStr;
    }
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
