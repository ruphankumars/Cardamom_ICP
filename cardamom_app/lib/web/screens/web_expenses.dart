import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/expense_sheet.dart';
import '../../services/expense_service.dart';
import '../../services/auth_provider.dart';
import '../../services/api_service.dart';

/// Web-optimized Daily Expense Sheet.
/// Date picker, expense items table, add form, daily total.
class WebExpenses extends StatefulWidget {
  final String? initialDate;

  const WebExpenses({super.key, this.initialDate});

  @override
  State<WebExpenses> createState() => _WebExpensesState();
}

class _WebExpensesState extends State<WebExpenses> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _headerBg = Color(0xFFF1F5F9);
  static const _cardRadius = 12.0;

  late String _selectedDate;
  bool _isLoading = true;
  String? _error;
  String _userRole = 'user';
  final ApiService _apiService = ApiService();

  bool get _isAdmin {
    final role = _userRole.toLowerCase().trim();
    return role == 'superadmin' || role == 'admin' || role == 'ops';
  }

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';
      final service = Provider.of<ExpenseService>(context, listen: false);
      await service.loadExpenseSheet(_selectedDate);
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_selectedDate) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) {
      setState(() => _selectedDate = DateFormat('yyyy-MM-dd').format(picked));
      _loadData();
    }
  }

  void _showAddExpenseDialog({ExpenseItem? existing}) {
    ExpenseCategory selectedCategory = existing?.category ?? ExpenseCategory.stitching;
    LoadingType? selectedSubCategory = existing?.subCategory;
    final qtyCtrl = TextEditingController(text: existing?.quantity?.toString() ?? '');
    final rateCtrl = TextEditingController(text: existing?.rate?.toStringAsFixed(0) ?? '');
    final amountCtrl = TextEditingController(text: existing?.amount.toStringAsFixed(0) ?? '');
    final noteCtrl = TextEditingController(text: existing?.note ?? '');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          void calcAmount() {
            final qty = int.tryParse(qtyCtrl.text) ?? 0;
            final rate = double.tryParse(rateCtrl.text) ?? 0;
            if (qty > 0 && rate > 0) {
              amountCtrl.text = (qty * rate).toStringAsFixed(0);
            }
          }

          return AlertDialog(
            title: Text(
              existing != null ? 'Edit Expense' : 'Add Expense',
              style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: _primary),
            ),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Category', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                    const SizedBox(height: 4),
                    DropdownButtonFormField<ExpenseCategory>(
                      value: selectedCategory,
                      decoration: _fieldDecoration(),
                      items: ExpenseCategory.values
                          .where((c) => c != ExpenseCategory.workerWages)
                          .map((c) => DropdownMenuItem(
                                value: c,
                                child: Text(c.displayName, style: GoogleFonts.inter(fontSize: 14)),
                              ))
                          .toList(),
                      onChanged: (v) => setDialogState(() => selectedCategory = v ?? selectedCategory),
                    ),
                    if (selectedCategory == ExpenseCategory.loading) ...[
                      const SizedBox(height: 12),
                      Text('Sub-Category', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<LoadingType>(
                        value: selectedSubCategory,
                        decoration: _fieldDecoration(),
                        items: LoadingType.values
                            .map((l) => DropdownMenuItem(value: l, child: Text(l.displayName, style: GoogleFonts.inter(fontSize: 14))))
                            .toList(),
                        onChanged: (v) => setDialogState(() => selectedSubCategory = v),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Quantity', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                              const SizedBox(height: 4),
                              TextField(
                                controller: qtyCtrl,
                                keyboardType: TextInputType.number,
                                style: GoogleFonts.inter(fontSize: 14),
                                decoration: _fieldDecoration(),
                                onChanged: (_) => calcAmount(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Rate', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                              const SizedBox(height: 4),
                              TextField(
                                controller: rateCtrl,
                                keyboardType: TextInputType.number,
                                style: GoogleFonts.inter(fontSize: 14),
                                decoration: _fieldDecoration(),
                                onChanged: (_) => calcAmount(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Amount (Rs)', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: amountCtrl,
                      keyboardType: TextInputType.number,
                      style: GoogleFonts.inter(fontSize: 14),
                      decoration: _fieldDecoration(),
                    ),
                    const SizedBox(height: 12),
                    Text('Note', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: noteCtrl,
                      style: GoogleFonts.inter(fontSize: 14),
                      decoration: _fieldDecoration(),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: GoogleFonts.inter(color: _primary)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _primary),
                onPressed: () async {
                  final amount = double.tryParse(amountCtrl.text) ?? 0;
                  if (amount <= 0) return;
                  final service = Provider.of<ExpenseService>(context, listen: false);
                  await service.addExpenseItem(
                    date: _selectedDate,
                    category: selectedCategory,
                    subCategory: selectedSubCategory,
                    quantity: int.tryParse(qtyCtrl.text),
                    rate: double.tryParse(rateCtrl.text),
                    amount: amount,
                    note: noteCtrl.text.trim().isNotEmpty ? noteCtrl.text.trim() : null,
                  );
                  if (mounted) Navigator.pop(ctx);
                },
                child: Text('Save', style: GoogleFonts.inter()),
              ),
            ],
          );
        },
      ),
    );
  }

  InputDecoration _fieldDecoration() {
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _primary.withOpacity(0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _primary.withOpacity(0.2)),
      ),
    );
  }

  Future<void> _submitSheet() async {
    final service = Provider.of<ExpenseService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final sheet = service.currentSheet;
    if (sheet?.id == null) return;

    try {
      await _apiService.submitExpenseSheet(sheet!.id!, auth.username ?? 'web');
      await service.loadExpenseSheet(_selectedDate);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Submitted for approval'), backgroundColor: const Color(0xFF10B981)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _approveSheet() async {
    final service = Provider.of<ExpenseService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final sheet = service.currentSheet;
    if (sheet?.id == null) return;

    try {
      await _apiService.approveExpenseSheet(sheet!.id!, auth.username ?? 'admin');
      await service.loadExpenseSheet(_selectedDate);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Expense sheet approved'), backgroundColor: const Color(0xFF10B981)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildErrorState()
                    : Consumer<ExpenseService>(
                        builder: (context, service, _) {
                          final sheet = service.currentSheet;
                          return SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildSummaryRow(sheet),
                                const SizedBox(height: 24),
                                _buildFixedCosts(sheet),
                                const SizedBox(height: 24),
                                _buildVariableCosts(sheet),
                                const SizedBox(height: 24),
                                _buildMiscCosts(sheet),
                                const SizedBox(height: 24),
                                _buildTotalRow(sheet),
                                const SizedBox(height: 24),
                                _buildActions(sheet),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final date = DateTime.tryParse(_selectedDate) ?? DateTime.now();
    final dayName = DateFormat('EEEE').format(date);
    final formattedDate = DateFormat('MMM d, yyyy').format(date);

    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Daily Expenses',
                    style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.calendar_today, size: 14, color: const Color(0xFF6B7280)),
                    const SizedBox(width: 6),
                    Text('$dayName, $formattedDate',
                        style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
                  ],
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _primary,
              side: BorderSide(color: _primary.withOpacity(0.3)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_month, size: 18),
            label: Text('Change Date', style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
          ),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.refresh, color: _primary), onPressed: _loadData),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(ExpenseSheet? sheet) {
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [
        _statCard('Worker Wages', 'Rs ${(sheet?.workerWages ?? 0).toStringAsFixed(0)}', Icons.people, const Color(0xFF3B82F6)),
        _statCard('Variable Costs', 'Rs ${(sheet?.totalVariable ?? 0).toStringAsFixed(0)}', Icons.receipt_long, const Color(0xFFF59E0B)),
        _statCard('Miscellaneous', 'Rs ${(sheet?.totalMisc ?? 0).toStringAsFixed(0)}', Icons.more_horiz, const Color(0xFF8B5CF6)),
        _statCard('Grand Total', 'Rs ${(sheet?.grandTotal ?? 0).toStringAsFixed(0)}', Icons.account_balance_wallet, const Color(0xFF10B981)),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Container(
      width: 210,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
                Text(label, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF6B7280))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon, {VoidCallback? onAdd}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: _primary),
          const SizedBox(width: 8),
          Text(title, style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700, color: _primary)),
          const Spacer(),
          if (onAdd != null)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onAdd,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add, size: 14, color: _primary),
                    const SizedBox(width: 4),
                    Text('Add', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _primary)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFixedCosts(ExpenseSheet? sheet) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('FIXED COSTS', Icons.lock),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_cardRadius),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Row(
            children: [
              const Icon(Icons.people, size: 20, color: Color(0xFF3B82F6)),
              const SizedBox(width: 12),
              Text('Worker Wages', style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF374151))),
              const Spacer(),
              Text('Rs ${(sheet?.workerWages ?? 0).toStringAsFixed(0)}',
                  style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w700, color: const Color(0xFF111827))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVariableCosts(ExpenseSheet? sheet) {
    final items = sheet?.variableItems ?? [];
    final canEdit = sheet?.canEdit ?? true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('VARIABLE COSTS', Icons.edit, onAdd: canEdit ? _showAddExpenseDialog : null),
        if (items.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(_cardRadius),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Center(
              child: Text('No variable expenses yet',
                  style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF))),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(_cardRadius),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_cardRadius),
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(_headerBg),
                headingTextStyle: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: _primary, letterSpacing: 0.5),
                dataTextStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
                columnSpacing: 20,
                horizontalMargin: 16,
                columns: const [
                  DataColumn(label: Text('CATEGORY')),
                  DataColumn(label: Text('QTY')),
                  DataColumn(label: Text('RATE')),
                  DataColumn(label: Text('AMOUNT'), numeric: true),
                  DataColumn(label: Text('NOTE')),
                ],
                rows: items.map((item) {
                  return DataRow(cells: [
                    DataCell(Text(item.category.displayName)),
                    DataCell(Text(item.quantity?.toString() ?? '-')),
                    DataCell(Text(item.rate != null ? 'Rs ${item.rate!.toStringAsFixed(0)}' : '-')),
                    DataCell(Text('Rs ${item.amount.toStringAsFixed(0)}',
                        style: GoogleFonts.manrope(fontWeight: FontWeight.w600))),
                    DataCell(Text(item.note ?? '-',
                        style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF9CA3AF)))),
                  ]);
                }).toList(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMiscCosts(ExpenseSheet? sheet) {
    final items = sheet?.miscItems ?? [];
    final canEdit = sheet?.canEdit ?? true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          'MISCELLANEOUS${sheet != null ? ' (${sheet.miscPercentage.toStringAsFixed(1)}%)' : ''}',
          Icons.more_horiz,
          onAdd: canEdit ? _showAddExpenseDialog : null,
        ),
        if (items.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(_cardRadius),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Center(
              child: Text('No miscellaneous expenses',
                  style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF))),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(_cardRadius),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_cardRadius),
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(_headerBg),
                headingTextStyle: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: _primary, letterSpacing: 0.5),
                dataTextStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
                columns: const [
                  DataColumn(label: Text('NOTE')),
                  DataColumn(label: Text('AMOUNT'), numeric: true),
                ],
                rows: items.map((item) {
                  return DataRow(cells: [
                    DataCell(Text(item.note ?? 'Misc')),
                    DataCell(Text('Rs ${item.amount.toStringAsFixed(0)}',
                        style: GoogleFonts.manrope(fontWeight: FontWeight.w600))),
                  ]);
                }).toList(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTotalRow(ExpenseSheet? sheet) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: _primary.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          Text('DAILY TOTAL', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: _primary, letterSpacing: 1)),
          const Spacer(),
          Text('Rs ${(sheet?.grandTotal ?? 0).toStringAsFixed(0)}',
              style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
        ],
      ),
    );
  }

  Widget _buildActions(ExpenseSheet? sheet) {
    if (sheet == null) return const SizedBox.shrink();

    return Row(
      children: [
        if (sheet.status != ExpenseStatus.draft)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _statusColor(sheet.status).withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              sheet.status.displayName,
              style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _statusColor(sheet.status)),
            ),
          ),
        const Spacer(),
        if (sheet.canSubmit)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _primary,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _submitSheet,
            icon: const Icon(Icons.send, size: 16),
            label: Text('Submit for Approval', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          ),
        if (sheet.canApprove && _isAdmin) ...[
          const SizedBox(width: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _approveSheet,
            icon: const Icon(Icons.check, size: 16),
            label: Text('Approve', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          ),
        ],
      ],
    );
  }

  Color _statusColor(ExpenseStatus status) {
    switch (status) {
      case ExpenseStatus.draft:
        return const Color(0xFF9CA3AF);
      case ExpenseStatus.pending:
        return const Color(0xFFF59E0B);
      case ExpenseStatus.approved:
        return const Color(0xFF10B981);
      case ExpenseStatus.rejected:
        return const Color(0xFFEF4444);
    }
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 56, color: Colors.red.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text('Failed to load expenses', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
          const SizedBox(height: 8),
          Text(_error ?? '', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _primary),
            onPressed: _loadData,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Retry', style: GoogleFonts.inter()),
          ),
        ],
      ),
    );
  }
}
