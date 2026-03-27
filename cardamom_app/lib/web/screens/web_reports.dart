import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';
import '../../services/report_service.dart';

/// Report type definition for web
class _WebReportType {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> supportedFormats;
  final Color color;

  const _WebReportType({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.supportedFormats,
    required this.color,
  });
}

class WebReports extends StatefulWidget {
  const WebReports({super.key});

  @override
  State<WebReports> createState() => _WebReportsState();
}

class _WebReportsState extends State<WebReports> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _cardRadius = 12.0;

  static const List<_WebReportType> _reportTypes = [
    _WebReportType(id: 'invoice', title: 'Invoice', subtitle: 'Generate client invoices', icon: Icons.receipt_long, supportedFormats: ['pdf'], color: Color(0xFF3B82F6)),
    _WebReportType(id: 'dispatch-summary', title: 'Dispatch Summary', subtitle: 'Daily packing & dispatch', icon: Icons.local_shipping, supportedFormats: ['pdf'], color: Color(0xFFF97316)),
    _WebReportType(id: 'stock-position', title: 'Stock Position', subtitle: 'Current stock snapshot', icon: Icons.inventory, supportedFormats: ['pdf', 'excel'], color: Color(0xFF10B981)),
    _WebReportType(id: 'stock-movement', title: 'Stock Movement', subtitle: 'Purchases vs dispatches', icon: Icons.swap_vert, supportedFormats: ['excel'], color: Color(0xFFA855F7)),
    _WebReportType(id: 'client-statement', title: 'Client Statement', subtitle: 'Order & balance history', icon: Icons.account_balance, supportedFormats: ['pdf'], color: Color(0xFF6366F1)),
    _WebReportType(id: 'sales-summary', title: 'Sales Summary', subtitle: 'Revenue analytics', icon: Icons.bar_chart, supportedFormats: ['pdf', 'excel'], color: Color(0xFFEAB308)),
    _WebReportType(id: 'attendance', title: 'Attendance', subtitle: 'Monthly worker attendance', icon: Icons.event_available, supportedFormats: ['excel'], color: Color(0xFFEC4899)),
    _WebReportType(id: 'expenses', title: 'Expenses', subtitle: 'Daily/monthly expenses', icon: Icons.account_balance_wallet, supportedFormats: ['pdf', 'excel'], color: Color(0xFFEF4444)),
  ];

  final ReportService _reportService = ReportService();
  final ApiService _apiService = ApiService();

  _WebReportType? _selectedReport;
  bool _isGenerating = false;
  String _selectedFormat = 'pdf';

  // Filter fields
  final TextEditingController _clientController = TextEditingController();
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _endDate = DateTime.now();
  DateTime _selectedDate = DateTime.now();
  DateTime _selectedMonth = DateTime.now();
  bool _includeGst = true;
  final TextEditingController _gstRateController = TextEditingController(text: '5');
  String _expenseType = 'daily';
  List<String> _clients = [];

  @override
  void initState() {
    super.initState();
    _loadDropdownData();
  }

  @override
  void dispose() {
    _clientController.dispose();
    _gstRateController.dispose();
    super.dispose();
  }

  Future<void> _loadDropdownData() async {
    try {
      final response = await _apiService.getOrders();
      if (response.data is List) {
        final orders = response.data as List;
        final clientSet = <String>{};
        for (final order in orders) {
          final client = order['client']?.toString() ?? '';
          if (client.isNotEmpty) clientSet.add(client);
        }
        if (mounted) setState(() => _clients = clientSet.toList()..sort());
      }
    } catch (_) {}
  }

  Future<void> _generateReport() async {
    if (_selectedReport == null) return;
    setState(() => _isGenerating = true);

    try {
      final params = _buildParams();
      final ext = ReportService.extensionForFormat(_selectedFormat);
      final filename = '${_selectedReport!.id}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.$ext';

      final filePath = await _reportService.downloadReport(
        reportType: _selectedReport!.id,
        params: params,
        filename: filename,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Report downloaded: $filename'),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'SHARE',
            textColor: Colors.white,
            onPressed: () => _reportService.shareReport(filePath, filename),
          ),
        ),
      );
      await _reportService.shareReport(filePath, filename);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Map<String, dynamic> _buildParams() {
    final params = <String, dynamic>{};
    if (_selectedReport == null) return params;
    final id = _selectedReport!.id;

    switch (id) {
      case 'invoice':
        params['client'] = _clientController.text;
        params['includeGst'] = _includeGst;
        params['gstRate'] = int.tryParse(_gstRateController.text) ?? 5;
        params['format'] = _selectedFormat;
        break;
      case 'dispatch-summary':
        params['date'] = DateFormat('yyyy-MM-dd').format(_selectedDate);
        params['format'] = _selectedFormat;
        break;
      case 'stock-position':
      case 'stock-movement':
        params['startDate'] = DateFormat('yyyy-MM-dd').format(_startDate);
        params['endDate'] = DateFormat('yyyy-MM-dd').format(_endDate);
        params['format'] = _selectedFormat;
        break;
      case 'client-statement':
        params['client'] = _clientController.text;
        params['startDate'] = DateFormat('yyyy-MM-dd').format(_startDate);
        params['endDate'] = DateFormat('yyyy-MM-dd').format(_endDate);
        params['format'] = _selectedFormat;
        break;
      case 'sales-summary':
        params['startDate'] = DateFormat('yyyy-MM-dd').format(_startDate);
        params['endDate'] = DateFormat('yyyy-MM-dd').format(_endDate);
        params['format'] = _selectedFormat;
        break;
      case 'attendance':
        params['month'] = DateFormat('yyyy-MM').format(_selectedMonth);
        params['format'] = _selectedFormat;
        break;
      case 'expenses':
        params['type'] = _expenseType;
        params['startDate'] = DateFormat('yyyy-MM-dd').format(_startDate);
        params['endDate'] = DateFormat('yyyy-MM-dd').format(_endDate);
        params['format'] = _selectedFormat;
        break;
    }
    return params;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPageHeader(),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: report type cards
                Expanded(flex: 3, child: _buildReportTypeGrid()),
                const SizedBox(width: 24),
                // Right: filter panel + generate
                Expanded(flex: 2, child: _buildFilterPanel()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Reports', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: const Color(0xFF1A1A2E))),
        const SizedBox(height: 4),
        Text(
          'Generate and download PDF or Excel reports',
          style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280)),
        ),
      ],
    );
  }

  Widget _buildReportTypeGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Select Report Type', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700, color: const Color(0xFF1A1A2E))),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.4,
          ),
          itemCount: _reportTypes.length,
          itemBuilder: (context, index) {
            final report = _reportTypes[index];
            final isSelected = _selectedReport?.id == report.id;
            return _buildReportCard(report, isSelected);
          },
        ),
      ],
    );
  }

  Widget _buildReportCard(_WebReportType report, bool isSelected) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedReport = report;
          _selectedFormat = report.supportedFormats.first;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_cardRadius),
          border: Border.all(
            color: isSelected ? report.color : const Color(0xFFE5E7EB),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: [
            if (isSelected)
              BoxShadow(color: report.color.withOpacity(0.15), blurRadius: 12, offset: const Offset(0, 4))
            else
              BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: report.color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(report.icon, color: report.color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(report.title, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: const Color(0xFF1A1A2E))),
                  const SizedBox(height: 2),
                  Text(report.subtitle, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF6B7280))),
                  const SizedBox(height: 4),
                  Row(
                    children: report.supportedFormats.map((f) {
                      return Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(f.toUpperCase(), style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280))),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: report.color, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterPanel() {
    if (_selectedReport == null) {
      return Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_cardRadius),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          children: [
            Icon(Icons.touch_app, size: 40, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('Select a report type', style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
            const SizedBox(height: 4),
            Text(
              'Choose from the left panel to configure filters',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF94A3B8)),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _selectedReport!.color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(_selectedReport!.icon, color: _selectedReport!.color, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${_selectedReport!.title} Filters',
                  style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: const Color(0xFF1A1A2E)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 16),
          // Format selector
          if (_selectedReport!.supportedFormats.length > 1) ...[
            _buildLabel('Format'),
            const SizedBox(height: 6),
            Row(
              children: _selectedReport!.supportedFormats.map((f) {
                final sel = _selectedFormat == f;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f.toUpperCase(), style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                    selected: sel,
                    selectedColor: _primary.withOpacity(0.15),
                    onSelected: (_) => setState(() => _selectedFormat = f),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
          // Dynamic fields
          ..._buildDynamicFields(),
          const SizedBox(height: 24),
          // Generate button
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              onPressed: _isGenerating ? null : _generateReport,
              icon: _isGenerating
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download, size: 18),
              label: Text(
                _isGenerating ? 'Generating...' : 'Generate Report',
                style: GoogleFonts.inter(fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _primary.withOpacity(0.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_cardRadius)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDynamicFields() {
    if (_selectedReport == null) return [];
    final id = _selectedReport!.id;

    switch (id) {
      case 'invoice':
        return [
          _buildClientDropdown(),
          const SizedBox(height: 12),
          _buildCheckbox('Include GST', _includeGst, (v) => setState(() => _includeGst = v ?? true)),
          if (_includeGst) ...[
            const SizedBox(height: 12),
            _buildTextField('GST Rate (%)', _gstRateController),
          ],
        ];
      case 'dispatch-summary':
        return [_buildDatePicker('Date', _selectedDate, (d) => setState(() => _selectedDate = d))];
      case 'stock-position':
      case 'stock-movement':
      case 'sales-summary':
        return [_buildDateRange()];
      case 'client-statement':
        return [
          _buildClientDropdown(),
          const SizedBox(height: 12),
          _buildDateRange(),
        ];
      case 'attendance':
        return [_buildMonthPicker()];
      case 'expenses':
        return [
          _buildLabel('Expense Type'),
          const SizedBox(height: 6),
          Row(
            children: ['daily', 'monthly'].map((t) {
              final sel = _expenseType == t;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(t[0].toUpperCase() + t.substring(1), style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                  selected: sel,
                  selectedColor: _primary.withOpacity(0.15),
                  onSelected: (_) => setState(() => _expenseType = t),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          _buildDateRange(),
        ];
      default:
        return [];
    }
  }

  Widget _buildLabel(String text) {
    return Text(text, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF4A5568)));
  }

  Widget _buildTextField(String label, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(label),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          style: GoogleFonts.inter(fontSize: 14),
          decoration: _inputDecoration(''),
        ),
      ],
    );
  }

  Widget _buildClientDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Client'),
        const SizedBox(height: 6),
        _clients.isEmpty
            ? TextFormField(
                controller: _clientController,
                style: GoogleFonts.inter(fontSize: 14),
                decoration: _inputDecoration('Enter client name'),
              )
            : DropdownButtonFormField<String>(
                value: _clientController.text.isNotEmpty && _clients.contains(_clientController.text) ? _clientController.text : null,
                isExpanded: true,
                decoration: _inputDecoration('Select client'),
                style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF1A1A2E)),
                items: _clients.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setState(() => _clientController.text = v ?? ''),
              ),
      ],
    );
  }

  Widget _buildCheckbox(String label, bool value, ValueChanged<bool?> onChanged) {
    return Row(
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: Checkbox(
            value: value,
            onChanged: onChanged,
            activeColor: _primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF4A5568))),
      ],
    );
  }

  Widget _buildDatePicker(String label, DateTime current, ValueChanged<DateTime> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(label),
        const SizedBox(height: 6),
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: current,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 365)),
            );
            if (picked != null) onChanged(picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFA),
              borderRadius: BorderRadius.circular(_cardRadius),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_today, size: 16, color: Color(0xFF6B7280)),
                const SizedBox(width: 8),
                Text(
                  DateFormat('dd MMM yyyy').format(current),
                  style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF1A1A2E)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDateRange() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDatePicker('Start Date', _startDate, (d) => setState(() => _startDate = d)),
        const SizedBox(height: 12),
        _buildDatePicker('End Date', _endDate, (d) => setState(() => _endDate = d)),
      ],
    );
  }

  Widget _buildMonthPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Month'),
        const SizedBox(height: 6),
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _selectedMonth,
              firstDate: DateTime(2020),
              lastDate: DateTime.now(),
            );
            if (picked != null) setState(() => _selectedMonth = DateTime(picked.year, picked.month));
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFA),
              borderRadius: BorderRadius.circular(_cardRadius),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_month, size: 16, color: Color(0xFF6B7280)),
                const SizedBox(width: 8),
                Text(
                  DateFormat('MMMM yyyy').format(_selectedMonth),
                  style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF1A1A2E)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8)),
      filled: true,
      fillColor: const Color(0xFFFAFAFA),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(_cardRadius), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(_cardRadius), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(_cardRadius), borderSide: const BorderSide(color: _primary, width: 1.5)),
    );
  }
}
