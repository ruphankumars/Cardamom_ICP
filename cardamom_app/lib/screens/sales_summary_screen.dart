import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api_service.dart';
import '../services/navigation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/grade_grouped_dropdown.dart';
import '../widgets/app_shell.dart';

class SalesSummaryScreen extends StatefulWidget {
  const SalesSummaryScreen({super.key});

  @override
  State<SalesSummaryScreen> createState() => _SalesSummaryScreenState();
}

class _SalesSummaryScreenState extends State<SalesSummaryScreen> with RouteAware {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  Map<String, dynamic> _summaryData = {};
  List<String> _clients = [];
  String _billingFilter = '';
  String _statusFilter = 'Pending';
  String _clientFilter = '';
  DateTime? _selectedDate;

  // #74: Persistent controller instead of creating on every build
  final TextEditingController _dateDisplayController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Use addPostFrameCallback to access arguments
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      if (args != null) {
        setState(() {
          if (args['billingFrom'] != null) _billingFilter = args['billingFrom'];
          else if (args['billing'] != null) _billingFilter = args['billing'];
          if (args['status'] != null) _statusFilter = args['status'];
          if (args['client'] != null) _clientFilter = args['client'];
        });
      }
      _loadData();
    });
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final Map<String, dynamic> filters = {};
      if (_billingFilter.isNotEmpty) filters['billingFrom'] = _billingFilter;
      if (_statusFilter.isNotEmpty) filters['status'] = _statusFilter;
      if (_clientFilter.isNotEmpty) filters['client'] = _clientFilter;
      if (_selectedDate != null) {
        filters['date'] = DateFormat('dd/MM/yy').format(_selectedDate!);
      }

      final response = await _apiService.getSalesSummary(filters);
      if (!mounted) return;
      setState(() {
        final data = response.data;
        _summaryData = data['summary'] ?? {};

        // Populate clients list from response or derive from orders if provided
        List<String> rawClients = (data['clients'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];

        // Fallback: If no clients list is provided but orders are (if the API were to return them),
        // we'd derive it. For now, we'll ensure we don't overwrite if we already have some.
        if (rawClients.isNotEmpty) {
           _clients = rawClients;
        } else if (_clients.isEmpty && data['orders'] != null) {
          // Hypothetical derivation if 'orders' field exists in future
          final orders = (data['orders'] as List?) ?? [];
          final Set<String> derived = orders.map((o) => o['client'].toString()).toSet();
          _clients = derived.toList()..sort();
        }

        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading sales summary: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _dateDisplayController.dispose();
    super.dispose();
  }

  @override
  void didPopNext() => _loadData();

  void _onFilterChanged() {
    _loadData();
  }

  void _shareSummary() {
    if (_summaryData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No summary data to share'), backgroundColor: Color(0xFFF59E0B)),
      );
      return;
    }

    final sortedKeys = GradeHelper.sorted(_summaryData.keys.toList());
    final entries = sortedKeys.map((k) => MapEntry(k, _summaryData[k])).toList();
    double grandTotalKgs = 0;
    int grandTotalOrders = 0;

    final buffer = StringBuffer();
    buffer.writeln('ICP Cardamom App - Sales Summary');

    // Date info
    if (_selectedDate != null) {
      buffer.writeln('Date: ${DateFormat('dd/MM/yyyy').format(_selectedDate!)}');
    } else {
      buffer.writeln('Date: All dates');
    }
    if (_billingFilter.isNotEmpty) buffer.writeln('Billing: $_billingFilter');
    if (_statusFilter.isNotEmpty) buffer.writeln('Status: $_statusFilter');
    if (_clientFilter.isNotEmpty) buffer.writeln('Client: $_clientFilter');
    buffer.writeln('────────────────────');
    buffer.writeln('Grade        | Orders | Kgs');
    buffer.writeln('────────────────────');

    for (var e in entries) {
      final val = e.value;
      double kgs = 0;
      int count = 0;
      if (val is Map) {
        kgs = (val['kgs'] is num ? (val['kgs'] as num).toDouble() : 0);
        count = (val['count'] is num ? (val['count'] as num).toInt() : 0);
      } else {
        kgs = double.tryParse(val.toString()) ?? 0;
      }
      grandTotalKgs += kgs;
      grandTotalOrders += count;

      final grade = e.key.padRight(12);
      final countStr = '$count'.padLeft(6);
      final kgsStr = '${kgs.toStringAsFixed(2)} kg'.padLeft(10);
      buffer.writeln('$grade| $countStr | $kgsStr');
    }

    buffer.writeln('────────────────────');
    buffer.writeln('Total: $grandTotalOrders orders | ${grandTotalKgs.toStringAsFixed(2)} kg');

    final text = buffer.toString();

    try {
      Share.share(text, subject: 'ICP Cardamom App - Sales Summary');
    } catch (_) {
      // Fallback to clipboard
      Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Summary copied to clipboard'), backgroundColor: Color(0xFF22C55E)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: '📈 Sales Summary',
      subtitle: 'Filter client-wise dispatch and pending totals.',
      topActions: [
        LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = MediaQuery.of(context).size.width < 600;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                _buildTopButton(
                  label: isMobile ? 'D-Board' : '📊 Dashboard',
                  onPressed: () { if (Navigator.canPop(context)) Navigator.pop(context); else Navigator.pushReplacementNamed(context, '/'); },
                  color: const Color(0xFF5D6E7E),
                  isMobile: isMobile,
                ),
                _buildTopButton(
                  label: isMobile ? 'Orders' : '📋 View Orders',
                  onPressed: () => Navigator.pushNamed(context, '/view_orders'),
                  color: const Color(0xFF22C55E),
                  isMobile: isMobile,
                ),
                _buildTopButton(
                  label: isMobile ? 'Share' : '📤 Share',
                  onPressed: _shareSummary,
                  color: const Color(0xFF2563EB),
                  isMobile: isMobile,
                ),
              ],
            );
          },
        ),
      ],
      content: Column(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isMobile = constraints.maxWidth < 600;
                  return Text(
                    isMobile ? 'Sales Summary' : '📊 Sales Order Summary',
                    style: TextStyle(fontSize: isMobile ? 18 : 22, fontWeight: FontWeight.bold, color: const Color(0xFF222222)),
                  );
                },
              ),
            ),
          ),
          _buildFilters(),
          const SizedBox(height: 24),
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final isMobile = constraints.maxWidth < 600;
                    return Center(
                      child: Container(
                        margin: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 0),
                        constraints: const BoxConstraints(maxWidth: 600),
                        decoration: AppTheme.glassDecoration,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: _buildSummaryTable(isMobile),
                        ),
                      ),
                    );
                  },
                ),
        ],
      ),
    );
  }

  Widget _buildTopButton({required String label, required VoidCallback onPressed, required Color color, bool isMobile = false}) {
    return Container(
      height: isMobile ? 36 : 40,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.4),
            offset: const Offset(0, 4),
            blurRadius: 10,
          ),
        ],
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

  Widget _buildFilters() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              if (isMobile) ...[
                _buildDropdownFilter('Billing', ['SYGT', 'ESPL'], (val) {
                  setState(() => _billingFilter = val ?? '');
                  _onFilterChanged();
                }, value: _billingFilter),
                const SizedBox(height: 12),
                _buildDropdownFilter('Status', ['All', 'Pending', 'On Progress', 'Billed'], (val) {
                  setState(() => _statusFilter = (val == 'All') ? '' : (val ?? ''));
                  _onFilterChanged();
                }, value: _statusFilter.isEmpty ? 'All' : _statusFilter),
                const SizedBox(height: 12),
                SearchableClientDropdown(
                  clients: _clients,
                  value: _clientFilter.isEmpty ? null : _clientFilter,
                  showAllOption: true,
                  hintText: 'Search client...',
                  onChanged: (val) {
                    setState(() => _clientFilter = val ?? '');
                    _onFilterChanged();
                  },
                ),
                const SizedBox(height: 12),
                _buildDateField(),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: _buildDropdownFilter('Billing', ['SYGT', 'ESPL'], (val) {
                        setState(() => _billingFilter = val ?? '');
                        _onFilterChanged();
                      }, value: _billingFilter),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildDropdownFilter('Status', ['All', 'Pending', 'On Progress', 'Billed'], (val) {
                        setState(() => _statusFilter = (val == 'All') ? '' : (val ?? ''));
                        _onFilterChanged();
                      }, value: _statusFilter.isEmpty ? 'All' : _statusFilter),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: SearchableClientDropdown(
                        clients: _clients,
                        value: _clientFilter.isEmpty ? null : _clientFilter,
                        showAllOption: true,
                        hintText: 'Search client...',
                        onChanged: (val) {
                          setState(() => _clientFilter = val ?? '');
                          _onFilterChanged();
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _buildDateField()),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildDropdownFilter(String hint, List<String> items, Function(String?) onChanged, {String? value}) {
    return SizedBox(
      height: 40,
      child: DropdownButtonFormField<String>(
        value: (value != null && value.isNotEmpty && items.contains(value)) ? value : null,
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
        ),
        borderRadius: BorderRadius.circular(12),
        hint: Text(hint),
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
        menuMaxHeight: 350,
        dropdownColor: AppTheme.bluishWhite,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildDateField() {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (date != null) {
                  _dateDisplayController.text = DateFormat('dd/MM/yy').format(date);
                  setState(() => _selectedDate = date);
                  _onFilterChanged();
                }
              },
              child: IgnorePointer(
                child: TextField(
                  controller: _dateDisplayController,
                  decoration: InputDecoration(
                    hintText: 'Select Date',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    suffixIcon: const Icon(Icons.calendar_today, size: 16, color: Color(0xFF64748B)),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                  ),
                ),
              ),
            ),
          ),
          if (_selectedDate != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 18, color: Color(0xFF64748B)),
              onPressed: () {
                _dateDisplayController.clear();
                setState(() => _selectedDate = null);
                _onFilterChanged();
              },
              tooltip: 'Clear date filter',
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryTable(bool isMobile) {
    final sortedKeys = GradeHelper.sorted(_summaryData.keys.toList());
    final entries = sortedKeys.map((k) => MapEntry(k, _summaryData[k])).toList();
    double grandTotalKgs = 0;
    int grandTotalOrders = 0;
    
    for (var e in entries) {
      final val = e.value;
      if (val is Map) {
        grandTotalKgs += (val['kgs'] is num ? (val['kgs'] as num).toDouble() : 0);
        grandTotalOrders += (val['count'] is num ? (val['count'] as num).toInt() : 0);
      } else {
        // Fallback for old data structure if needed
        grandTotalKgs += (double.tryParse(val.toString()) ?? 0);
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(2), // Grade
          1: FlexColumnWidth(1), // Orders count
          2: FlexColumnWidth(1.2), // Total kgs
        },
        children: [
          TableRow(
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF2563EB)]),
            ),
            children: [
              _buildCell('GRADE TYPE', isHeader: true, isMobile: isMobile),
              _buildCell('ORDERS', isHeader: true, alignRight: true, isMobile: isMobile),
              _buildCell('TOTAL KGS', isHeader: true, alignRight: true, isMobile: isMobile),
            ],
          ),
          ...entries.map((e) {
            final val = e.value;
            double kgs = 0;
            int count = 0;

            if (val is Map) {
              kgs = (val['kgs'] is num ? (val['kgs'] as num).toDouble() : 0);
              count = (val['count'] is num ? (val['count'] as num).toInt() : 0);
            } else {
              kgs = double.tryParse(val.toString()) ?? 0;
            }

            return TableRow(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.black.withOpacity(0.03))),
              ),
              children: [
                _buildTappableCell(e.key, isMobile: isMobile, grade: e.key),
                _buildTappableCell('$count', alignRight: true, isMobile: isMobile, isBold: true, color: const Color(0xFF64748B), grade: e.key),
                _buildTappableCell('${kgs.toStringAsFixed(2)} kg', alignRight: true, isMobile: isMobile, isBold: true, grade: e.key),
              ],
            );
          }),
          TableRow(
            decoration: BoxDecoration(color: const Color(0xFFF1F5F9).withOpacity(0.5)),
            children: [
              _buildCell('GRAND TOTAL', isHeader: false, isBold: true, isMobile: isMobile),
              _buildCell('$grandTotalOrders', isHeader: false, alignRight: true, isBold: true, isMobile: isMobile, color: const Color(0xFF64748B)),
              _buildCell('${grandTotalKgs.toStringAsFixed(2)} kg', isHeader: false, alignRight: true, isBold: true, isMobile: isMobile, color: const Color(0xFF2563EB)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCell(String text, {bool isHeader = false, bool alignRight = false, bool isBold = false, bool isMobile = false, Color? color}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 12 : 14),
      child: Text(
        text,
        textAlign: alignRight ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          color: isHeader ? Colors.white : (color ?? const Color(0xFF4A5568)),
          fontWeight: (isHeader || isBold) ? FontWeight.bold : FontWeight.w500,
          fontSize: isMobile ? (isHeader ? 10 : 13) : 14,
          letterSpacing: isHeader ? 0.5 : 0,
        ),
      ),
    );
  }

  Widget _buildTappableCell(String text, {bool alignRight = false, bool isBold = false, bool isMobile = false, Color? color, required String grade}) {
    return GestureDetector(
      onTap: () => _navigateToGradeDetail(grade),
      child: Container(
        color: Colors.transparent, // Ensures full area is tappable
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 12 : 14),
        child: Row(
          mainAxisAlignment: alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Flexible(
              child: Text(
                text,
                textAlign: alignRight ? TextAlign.right : TextAlign.left,
                style: TextStyle(
                  color: color ?? const Color(0xFF4A5568),
                  fontWeight: isBold ? FontWeight.bold : FontWeight.w500,
                  fontSize: isMobile ? 13 : 14,
                ),
              ),
            ),
            if (!alignRight) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: isMobile ? 14 : 16, color: const Color(0xFF94A3B8)),
            ],
          ],
        ),
      ),
    );
  }

  void _navigateToGradeDetail(String grade) {
    Navigator.pushNamed(context, '/grade_detail', arguments: {
      'grade': grade,
      'status': _statusFilter,
      'billingFrom': _billingFilter,
      'client': _clientFilter,
      if (_selectedDate != null) 'date': DateFormat('dd/MM/yy').format(_selectedDate!),
    });
  }
}
