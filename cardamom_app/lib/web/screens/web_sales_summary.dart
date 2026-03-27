import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/api_service.dart';
import '../widgets/web_metric_row.dart';

class WebSalesSummary extends StatefulWidget {
  const WebSalesSummary({super.key});

  @override
  State<WebSalesSummary> createState() => _WebSalesSummaryState();
}

class _WebSalesSummaryState extends State<WebSalesSummary> {
  final ApiService _apiService = ApiService();

  bool _isLoading = true;
  String? _error;
  Map<String, dynamic> _summaryData = {};
  List<String> _clients = [];

  // Filters
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _endDate = DateTime.now();
  String _billingFilter = '';
  String _statusFilter = '';
  String _clientFilter = '';

  // Sorting
  int _sortColumnIndex = 0;
  bool _sortAscending = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args =
          ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      if (args != null) {
        if (args['billingFrom'] != null) _billingFilter = args['billingFrom'];
        if (args['billing'] != null && _billingFilter.isEmpty) {
          _billingFilter = args['billing'];
        }
        if (args['status'] != null) _statusFilter = args['status'];
        if (args['client'] != null) _clientFilter = args['client'];
      }
      _loadData();
    });
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> filters = {};
      if (_billingFilter.isNotEmpty) filters['billingFrom'] = _billingFilter;
      if (_statusFilter.isNotEmpty) filters['status'] = _statusFilter;
      if (_clientFilter.isNotEmpty) filters['client'] = _clientFilter;
      filters['startDate'] = DateFormat('yyyy-MM-dd').format(_startDate);
      filters['endDate'] = DateFormat('yyyy-MM-dd').format(_endDate);

      final response = await _apiService.getSalesSummary(filters);
      if (!mounted) return;

      final data = response.data;
      setState(() {
        _summaryData = data['summary'] is Map
            ? Map<String, dynamic>.from(data['summary'])
            : {};
        final rawClients = (data['clients'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [];
        if (rawClients.isNotEmpty) _clients = rawClients;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading sales summary: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to load sales data. Tap to retry.';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  num _parseNum(dynamic v) => v is num ? v : (num.tryParse('$v') ?? 0);

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF8F9FA),
      child: Column(
        children: [
          _buildHeaderBar(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF5D6E7E)))
                : _error != null
                    ? _buildError()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildFilters(),
                            const SizedBox(height: 24),
                            _buildMetrics(),
                            const SizedBox(height: 24),
                            _buildDataTable(),
                            const SizedBox(height: 32),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  Widget _buildHeaderBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Text(
            'Sales Summary',
            style: GoogleFonts.manrope(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: const Color(0xFF111827),
            ),
          ),
          const Spacer(),
          _buildExportButton(),
        ],
      ),
    );
  }

  Widget _buildExportButton() {
    return ElevatedButton.icon(
      onPressed: _exportCsv,
      icon: const Icon(Icons.download_rounded, size: 16),
      label: const Text('Export CSV'),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF5D6E7E),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }

  void _exportCsv() {
    if (_summaryData.isEmpty) return;

    final buffer = StringBuffer();
    buffer.writeln('Grade,Orders,Total Kgs');

    double grandKgs = 0;
    int grandOrders = 0;

    final entries = _summaryData.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    for (final e in entries) {
      final val = e.value;
      double kgs = 0;
      int count = 0;
      if (val is Map) {
        kgs = _parseNum(val['kgs']).toDouble();
        count = _parseNum(val['count']).toInt();
      } else {
        kgs = _parseNum(val).toDouble();
      }
      grandKgs += kgs;
      grandOrders += count;
      buffer.writeln('"${e.key}",$count,${kgs.toStringAsFixed(2)}');
    }
    buffer.writeln('"TOTAL",$grandOrders,${grandKgs.toStringAsFixed(2)}');

    final csvContent = buffer.toString();

    // Copy to clipboard as a web-safe fallback
    _showCsvDialog(csvContent);
  }

  void _showCsvDialog(String csvContent) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('CSV Export', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 500,
          height: 300,
          child: SelectableText(
            csvContent,
            style: GoogleFonts.firaCode(fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Filters
  // ---------------------------------------------------------------------------

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Filters',
            style: GoogleFonts.manrope(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF374151),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _buildDateField('Start Date', _startDate, (d) {
                setState(() => _startDate = d);
              }),
              _buildDateField('End Date', _endDate, (d) {
                setState(() => _endDate = d);
              }),
              _buildDropdown(
                'Billing',
                _billingFilter,
                ['', 'SYGT', 'ESPL'],
                (v) => setState(() => _billingFilter = v ?? ''),
              ),
              _buildClientDropdown(),
              _buildDropdown(
                'Status',
                _statusFilter,
                ['', 'Pending', 'On Progress', 'Billed'],
                (v) => setState(() => _statusFilter = v ?? ''),
              ),
              SizedBox(
                height: 42,
                child: ElevatedButton.icon(
                  onPressed: _loadData,
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('Apply'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF3B82F6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 42,
                child: OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _startDate = DateTime.now().subtract(const Duration(days: 30));
                      _endDate = DateTime.now();
                      _billingFilter = '';
                      _statusFilter = '';
                      _clientFilter = '';
                    });
                    _loadData();
                  },
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Reset'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6B7280),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    side: const BorderSide(color: Color(0xFFD1D5DB)),
                    textStyle: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDateField(String label, DateTime value, ValueChanged<DateTime> onChanged) {
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 6),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: value,
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
              );
              if (picked != null) onChanged(picked);
            },
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFD1D5DB)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_rounded, size: 14, color: Color(0xFF6B7280)),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('dd MMM yyyy').format(value),
                    style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown(
    String label,
    String current,
    List<String> items,
    ValueChanged<String?> onChanged,
  ) {
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD1D5DB)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: current.isEmpty ? null : current,
                hint: Text('All', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF))),
                isExpanded: true,
                icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: Color(0xFF6B7280)),
                style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
                items: items.map((e) {
                  return DropdownMenuItem(
                    value: e.isEmpty ? null : e,
                    child: Text(e.isEmpty ? 'All' : e),
                  );
                }).toList(),
                onChanged: (v) => onChanged(v ?? ''),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClientDropdown() {
    final items = ['', ..._clients];
    return _buildDropdown('Client', _clientFilter, items, (v) {
      setState(() => _clientFilter = v ?? '');
    });
  }

  // ---------------------------------------------------------------------------
  // Metrics
  // ---------------------------------------------------------------------------

  Widget _buildMetrics() {
    double totalKgs = 0;
    int totalOrders = 0;
    final gradeCount = _summaryData.length;

    for (final e in _summaryData.values) {
      if (e is Map) {
        totalKgs += _parseNum(e['kgs']).toDouble();
        totalOrders += _parseNum(e['count']).toInt();
      } else {
        totalKgs += _parseNum(e).toDouble();
      }
    }

    final avgPrice = totalKgs > 0 && totalOrders > 0
        ? (totalKgs / totalOrders)
        : 0.0;

    return WebMetricRow(
      metrics: [
        MetricData(
          label: 'Total Sales (Kgs)',
          value: '${totalKgs.toStringAsFixed(1)} kg',
          icon: Icons.scale_rounded,
          color: const Color(0xFF3B82F6),
        ),
        MetricData(
          label: 'Total Orders',
          value: '$totalOrders',
          icon: Icons.receipt_long_rounded,
          color: const Color(0xFF10B981),
        ),
        MetricData(
          label: 'Avg Kgs / Order',
          value: '${avgPrice.toStringAsFixed(1)} kg',
          icon: Icons.analytics_rounded,
          color: const Color(0xFFF59E0B),
        ),
        MetricData(
          label: 'Grades Count',
          value: '$gradeCount',
          icon: Icons.category_rounded,
          color: const Color(0xFF8B5CF6),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Data Table
  // ---------------------------------------------------------------------------

  Widget _buildDataTable() {
    if (_summaryData.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(Icons.inbox_rounded, size: 48, color: const Color(0xFF9CA3AF).withOpacity(0.5)),
            const SizedBox(height: 12),
            Text(
              'No sales data found for the selected filters',
              style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF9CA3AF)),
            ),
          ],
        ),
      );
    }

    // Build rows
    final List<_SummaryRow> rows = [];
    double grandKgs = 0;
    int grandOrders = 0;

    for (final e in _summaryData.entries) {
      final val = e.value;
      double kgs = 0;
      int count = 0;
      if (val is Map) {
        kgs = _parseNum(val['kgs']).toDouble();
        count = _parseNum(val['count']).toInt();
      } else {
        kgs = _parseNum(val).toDouble();
      }
      grandKgs += kgs;
      grandOrders += count;
      rows.add(_SummaryRow(grade: e.key, orders: count, kgs: kgs));
    }

    // Sort
    rows.sort((a, b) {
      int cmp;
      switch (_sortColumnIndex) {
        case 0:
          cmp = a.grade.compareTo(b.grade);
          break;
        case 1:
          cmp = a.orders.compareTo(b.orders);
          break;
        case 2:
          cmp = a.kgs.compareTo(b.kgs);
          break;
        default:
          cmp = 0;
      }
      return _sortAscending ? cmp : -cmp;
    });

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                Text(
                  'Sales by Grade',
                  style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${rows.length} grades',
                  style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF9CA3AF)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              sortColumnIndex: _sortColumnIndex,
              sortAscending: _sortAscending,
              headingRowColor: WidgetStateProperty.all(const Color(0xFFF9FAFB)),
              headingTextStyle: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF6B7280),
              ),
              dataTextStyle: GoogleFonts.inter(
                fontSize: 13,
                color: const Color(0xFF374151),
              ),
              columnSpacing: 48,
              columns: [
                DataColumn(
                  label: const Text('Grade'),
                  onSort: (col, asc) => setState(() {
                    _sortColumnIndex = col;
                    _sortAscending = asc;
                  }),
                ),
                DataColumn(
                  label: const Text('Orders'),
                  numeric: true,
                  onSort: (col, asc) => setState(() {
                    _sortColumnIndex = col;
                    _sortAscending = asc;
                  }),
                ),
                DataColumn(
                  label: const Text('Total Kgs'),
                  numeric: true,
                  onSort: (col, asc) => setState(() {
                    _sortColumnIndex = col;
                    _sortAscending = asc;
                  }),
                ),
              ],
              rows: [
                ...rows.map((r) => DataRow(
                      cells: [
                        DataCell(
                          Text(
                            r.grade,
                            style: GoogleFonts.inter(fontWeight: FontWeight.w500),
                          ),
                        ),
                        DataCell(
                          Text(
                            '${r.orders}',
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF6B7280),
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            '${r.kgs.toStringAsFixed(2)} kg',
                            style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    )),
                // Grand total row
                DataRow(
                  color: WidgetStateProperty.all(const Color(0xFFF0F4FF)),
                  cells: [
                    DataCell(
                      Text(
                        'TOTAL',
                        style: GoogleFonts.manrope(
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF111827),
                        ),
                      ),
                    ),
                    DataCell(
                      Text(
                        '$grandOrders',
                        style: GoogleFonts.manrope(
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF6B7280),
                        ),
                      ),
                    ),
                    DataCell(
                      Text(
                        '${grandKgs.toStringAsFixed(2)} kg',
                        style: GoogleFonts.manrope(
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF3B82F6),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Error
  // ---------------------------------------------------------------------------

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: const Color(0xFFEF4444).withOpacity(0.6),
          ),
          const SizedBox(height: 16),
          Text(
            _error ?? 'Something went wrong',
            style: GoogleFonts.inter(fontSize: 15, color: const Color(0xFF6B7280)),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5D6E7E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data model for table rows
// ---------------------------------------------------------------------------

class _SummaryRow {
  final String grade;
  final int orders;
  final double kgs;

  const _SummaryRow({
    required this.grade,
    required this.orders,
    required this.kgs,
  });
}
