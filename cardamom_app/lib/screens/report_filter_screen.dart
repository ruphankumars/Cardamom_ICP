import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../services/report_service.dart';
import '../services/api_service.dart';
import 'reports_screen.dart';

/// Dynamic filter form for report generation.
/// Shows different fields based on the selected report type.
class ReportFilterScreen extends StatefulWidget {
  final ReportType reportType;

  const ReportFilterScreen({super.key, required this.reportType});

  @override
  State<ReportFilterScreen> createState() => _ReportFilterScreenState();
}

class _ReportFilterScreenState extends State<ReportFilterScreen> {
  final ReportService _reportService = ReportService();
  final ApiService _apiService = ApiService();

  bool _isGenerating = false;
  String _selectedFormat = 'pdf';

  // Invoice fields
  final TextEditingController _clientController = TextEditingController();
  bool _includeGst = true;
  final TextEditingController _gstRateController = TextEditingController(text: '5');

  // Date fields
  DateTime _selectedDate = DateTime.now();
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _endDate = DateTime.now();

  // Month field
  DateTime _selectedMonth = DateTime.now();

  // Expense type
  String _expenseType = 'daily';

  // Client statement bulk toggle
  bool _bulkExport = false;

  // Dropdown data
  List<String> _clients = [];
  String _billingFrom = '';
  String _statusFilter = 'all';
  String _teamFilter = '';
  String _stockType = '';

  // #74: Persistent controller instead of creating on every build
  final TextEditingController _teamController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedFormat = widget.reportType.supportedFormats.first;
    _loadDropdownData();
  }

  Future<void> _loadDropdownData() async {
    try {
      // Load clients from orders
      final response = await _apiService.getOrders();
      if (response.data is List) {
        final orders = response.data as List;
        final clientSet = <String>{};
        for (final order in orders) {
          final client = order['client']?.toString() ?? '';
          if (client.isNotEmpty) clientSet.add(client);
        }
        if (mounted) {
          setState(() {
            _clients = clientSet.toList()..sort();
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to load dropdown data: $e');
    }
  }

  @override
  void dispose() {
    _clientController.dispose();
    _gstRateController.dispose();
    _teamController.dispose();
    super.dispose();
  }

  Future<void> _generateReport() async {
    setState(() => _isGenerating = true);

    try {
      final params = _buildParams();
      final reportType = _getEndpointName();
      final ext = ReportService.extensionForFormat(_selectedFormat);
      final filename = '${widget.reportType.id}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.$ext';

      final filePath = await _reportService.downloadReport(
        reportType: reportType,
        params: params,
        filename: filename,
      );

      if (!mounted) return;

      // Show success and offer to share
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Report downloaded: $filename'),
          backgroundColor: AppTheme.success,
          action: SnackBarAction(
            label: 'SHARE',
            textColor: Colors.white,
            onPressed: () => _reportService.shareReport(filePath, filename),
          ),
          duration: const Duration(seconds: 5),
        ),
      );

      // Auto-open share sheet
      await _reportService.shareReport(filePath, filename);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: AppTheme.danger,
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  String _getEndpointName() {
    if (widget.reportType.id == 'client-statement' && _bulkExport) {
      return 'client-statement/bulk';
    }
    return widget.reportType.id;
  }

  Map<String, dynamic> _buildParams() {
    final params = <String, dynamic>{};
    final id = widget.reportType.id;

    switch (id) {
      case 'invoice':
        params['client'] = _clientController.text;
        params['orderIds'] = <String>[]; // User would select specific orders
        params['includeGst'] = _includeGst;
        params['gstRate'] = int.tryParse(_gstRateController.text) ?? 5;
        params['format'] = 'pdf';
        break;

      case 'dispatch-summary':
        params['date'] = DateFormat('yyyy-MM-dd').format(_selectedDate);
        params['format'] = 'pdf';
        break;

      case 'stock-position':
        params['format'] = _selectedFormat;
        break;

      case 'stock-movement':
        params['startDate'] = DateFormat('yyyy-MM-dd').format(_startDate);
        params['endDate'] = DateFormat('yyyy-MM-dd').format(_endDate);
        if (_stockType.isNotEmpty) params['type'] = _stockType;
        params['format'] = 'excel';
        break;

      case 'client-statement':
        params['startDate'] = DateFormat('yyyy-MM-dd').format(_startDate);
        params['endDate'] = DateFormat('yyyy-MM-dd').format(_endDate);
        if (!_bulkExport) {
          params['client'] = _clientController.text;
        }
        params['format'] = _bulkExport ? 'zip' : 'pdf';
        break;

      case 'sales-summary':
        params['startDate'] = DateFormat('yyyy-MM-dd').format(_startDate);
        params['endDate'] = DateFormat('yyyy-MM-dd').format(_endDate);
        if (_billingFrom.isNotEmpty) params['billingFrom'] = _billingFrom;
        if (_clientController.text.isNotEmpty) params['client'] = _clientController.text;
        if (_statusFilter != 'all') params['status'] = _statusFilter;
        params['format'] = _selectedFormat;
        break;

      case 'attendance':
        params['month'] = DateFormat('yyyy-MM').format(_selectedMonth);
        if (_teamFilter.isNotEmpty) params['team'] = _teamFilter;
        params['format'] = 'excel';
        break;

      case 'expenses':
        params['type'] = _expenseType;
        if (_expenseType == 'daily') {
          params['date'] = DateFormat('yyyy-MM-dd').format(_selectedDate);
        } else {
          params['month'] = DateFormat('yyyy-MM').format(_selectedMonth);
        }
        params['format'] = _expenseType == 'daily' ? 'pdf' : 'excel';
        break;
    }

    return params;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.titaniumLight,
      appBar: AppBar(
        title: Text(widget.reportType.title),
        backgroundColor: Colors.white,
        foregroundColor: AppTheme.title,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Report info card
              _buildInfoCard(),
              const SizedBox(height: 16),

              // Dynamic filter fields
              _buildFilterCard(),
              const SizedBox(height: 16),

              // Format selector (if multiple formats)
              if (widget.reportType.supportedFormats.length > 1)
                _buildFormatSelector(),
              if (widget.reportType.supportedFormats.length > 1)
                const SizedBox(height: 16),

              // Generate button
              _buildGenerateButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Icon(widget.reportType.icon, color: AppTheme.steelBlue, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.reportType.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.title)),
                const SizedBox(height: 2),
                Text(widget.reportType.subtitle, style: const TextStyle(fontSize: 12, color: AppTheme.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Filters', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.title)),
          const SizedBox(height: 12),
          ..._buildFieldsForReportType(),
        ],
      ),
    );
  }

  List<Widget> _buildFieldsForReportType() {
    switch (widget.reportType.id) {
      case 'invoice':
        return _buildInvoiceFields();
      case 'dispatch-summary':
        return _buildDispatchFields();
      case 'stock-position':
        return []; // No filters needed
      case 'stock-movement':
        return _buildStockMovementFields();
      case 'client-statement':
        return _buildClientStatementFields();
      case 'sales-summary':
        return _buildSalesSummaryFields();
      case 'attendance':
        return _buildAttendanceFields();
      case 'expenses':
        return _buildExpenseFields();
      default:
        return [];
    }
  }

  List<Widget> _buildInvoiceFields() {
    return [
      _buildClientDropdown(),
      const SizedBox(height: 12),
      SwitchListTile(
        title: const Text('Include GST', style: TextStyle(fontSize: 14)),
        value: _includeGst,
        onChanged: (v) => setState(() => _includeGst = v),
        activeColor: AppTheme.steelBlue,
        contentPadding: EdgeInsets.zero,
      ),
      if (_includeGst)
        _buildTextField(_gstRateController, 'GST Rate (%)', TextInputType.number),
    ];
  }

  List<Widget> _buildDispatchFields() {
    return [
      _buildDatePicker('Date', _selectedDate, (d) => setState(() => _selectedDate = d)),
    ];
  }

  List<Widget> _buildStockMovementFields() {
    return [
      _buildDatePicker('Start Date', _startDate, (d) => setState(() => _startDate = d)),
      const SizedBox(height: 12),
      _buildDatePicker('End Date', _endDate, (d) => setState(() => _endDate = d)),
      const SizedBox(height: 12),
      _buildDropdown('Stock Type (optional)', ['', 'Colour Bold', 'Fruit Bold', 'Rejection'], _stockType,
          (v) => setState(() => _stockType = v ?? '')),
    ];
  }

  List<Widget> _buildClientStatementFields() {
    return [
      SwitchListTile(
        title: const Text('Bulk Export (All Clients)', style: TextStyle(fontSize: 14)),
        value: _bulkExport,
        onChanged: (v) => setState(() => _bulkExport = v),
        activeColor: AppTheme.steelBlue,
        contentPadding: EdgeInsets.zero,
      ),
      if (!_bulkExport) _buildClientDropdown(),
      if (!_bulkExport) const SizedBox(height: 12),
      _buildDatePicker('Start Date', _startDate, (d) => setState(() => _startDate = d)),
      const SizedBox(height: 12),
      _buildDatePicker('End Date', _endDate, (d) => setState(() => _endDate = d)),
    ];
  }

  List<Widget> _buildSalesSummaryFields() {
    return [
      _buildDatePicker('Start Date', _startDate, (d) => setState(() => _startDate = d)),
      const SizedBox(height: 12),
      _buildDatePicker('End Date', _endDate, (d) => setState(() => _endDate = d)),
      const SizedBox(height: 12),
      _buildClientDropdown(),
      const SizedBox(height: 12),
      _buildDropdown('Status', ['all', 'pending', 'on progress', 'billed'], _statusFilter,
          (v) => setState(() => _statusFilter = v ?? 'all')),
    ];
  }

  List<Widget> _buildAttendanceFields() {
    return [
      _buildMonthPicker('Month', _selectedMonth, (d) => setState(() => _selectedMonth = d)),
      const SizedBox(height: 12),
      _buildTextField(_teamController, 'Team (optional)', TextInputType.text,
          onChanged: (v) => _teamFilter = v),
    ];
  }

  List<Widget> _buildExpenseFields() {
    return [
      _buildDropdown('Report Type', ['daily', 'monthly'], _expenseType,
          (v) => setState(() => _expenseType = v ?? 'daily')),
      const SizedBox(height: 12),
      if (_expenseType == 'daily')
        _buildDatePicker('Date', _selectedDate, (d) => setState(() => _selectedDate = d)),
      if (_expenseType == 'monthly')
        _buildMonthPicker('Month', _selectedMonth, (d) => setState(() => _selectedMonth = d)),
    ];
  }

  Widget _buildClientDropdown() {
    return Autocomplete<String>(
      optionsBuilder: (TextEditingValue textEditingValue) {
        if (textEditingValue.text.isEmpty) return _clients;
        return _clients.where((c) => c.toLowerCase().contains(textEditingValue.text.toLowerCase()));
      },
      onSelected: (String selection) => _clientController.text = selection,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        // Sync with our controller
        if (_clientController.text.isNotEmpty && controller.text.isEmpty) {
          controller.text = _clientController.text;
        }
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Client',
            hintText: 'Type to search clients...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          onChanged: (v) => _clientController.text = v,
        );
      },
    );
  }

  Widget _buildDatePicker(String label, DateTime current, ValueChanged<DateTime> onChanged) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: current,
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 1)),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          suffixIcon: const Icon(Icons.calendar_today, size: 18),
        ),
        child: Text(DateFormat('dd MMM yyyy').format(current), style: const TextStyle(fontSize: 14)),
      ),
    );
  }

  Widget _buildMonthPicker(String label, DateTime current, ValueChanged<DateTime> onChanged) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: current,
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 31)),
          initialDatePickerMode: DatePickerMode.year,
        );
        if (picked != null) {
          onChanged(DateTime(picked.year, picked.month));
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          suffixIcon: const Icon(Icons.calendar_month, size: 18),
        ),
        child: Text(DateFormat('MMMM yyyy').format(current), style: const TextStyle(fontSize: 14)),
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, String label, TextInputType type,
      {ValueChanged<String>? onChanged}) {
    return TextField(
      controller: controller,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      onChanged: onChanged,
    );
  }

  Widget _buildDropdown(String label, List<String> items, String current, ValueChanged<String?> onChanged) {
    return DropdownButtonFormField<String>(
      value: items.contains(current) ? current : items.first,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      items: items.map((item) {
        return DropdownMenuItem(
          value: item,
          child: Text(item.isEmpty ? '(All)' : item[0].toUpperCase() + item.substring(1), style: const TextStyle(fontSize: 14)),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }

  Widget _buildFormatSelector() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Format', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.title)),
          const SizedBox(height: 8),
          Row(
            children: widget.reportType.supportedFormats.map((fmt) {
              final isSelected = _selectedFormat == fmt;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _selectedFormat = fmt),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: isSelected ? AppTheme.steelBlue : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected ? AppTheme.steelBlue : Colors.grey.shade300,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          fmt == 'pdf' ? Icons.picture_as_pdf : Icons.table_chart,
                          color: isSelected ? Colors.white : Colors.grey.shade600,
                          size: 20,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fmt.toUpperCase(),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isSelected ? Colors.white : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildGenerateButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton.icon(
        onPressed: _isGenerating ? null : _generateReport,
        icon: _isGenerating
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.download),
        label: Text(_isGenerating ? 'Generating...' : 'Generate Report'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.steelBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
