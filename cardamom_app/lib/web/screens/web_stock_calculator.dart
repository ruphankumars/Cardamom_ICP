import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/api_service.dart';

/// Web-optimized Stock Calculator.
/// Displays net stock data in a table, provides recalc/rebuild admin actions.
class WebStockCalculator extends StatefulWidget {
  const WebStockCalculator({super.key});

  @override
  State<WebStockCalculator> createState() => _WebStockCalculatorState();
}

class _WebStockCalculatorState extends State<WebStockCalculator> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _headerBg = Color(0xFFF1F5F9);
  static const _cardRadius = 12.0;

  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String _status = 'Ready.';
  Map<String, dynamic>? _netStock;
  String _deltaStatus = '';
  List<String> _shortages = [];
  String _userRole = 'user';
  String? _error;

  bool get _isAdmin {
    final role = _userRole.toLowerCase().trim();
    return role == 'superadmin' || role == 'admin' || role == 'ops';
  }

  final List<String> _absGrades = [
    '8 mm', '7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below'
  ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';
      await Future.wait([_loadDeltaStatus(), _refreshNetStock()]);
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

  Future<void> _loadDeltaStatus() async {
    try {
      final res = await _apiService.getDeltaStatus();
      if (mounted) setState(() => _deltaStatus = res.data?.toString() ?? '');
    } catch (e) {
      debugPrint('Error loading delta status: $e');
    }
  }

  Future<void> _refreshNetStock() async {
    try {
      final res = await _apiService.getNetStock();
      if (mounted) {
        setState(() {
          _netStock = Map<String, dynamic>.from(res.data);
        });
      }
    } catch (e) {
      debugPrint('Error loading net stock: $e');
    }
  }

  Future<void> _recalc() async {
    setState(() => _status = 'Recalculating...');
    try {
      await _apiService.recalcStock();
      if (mounted) setState(() => _status = 'Recalculation complete.');
      await _init();
    } catch (e) {
      if (mounted) setState(() => _status = 'Recalculation failed: $e');
    }
  }

  Future<void> _resetPointer() async {
    final confirmed = await _showConfirm('Reset delta pointer and clear computed stock?');
    if (confirmed != true) return;
    setState(() => _status = 'Resetting pointer...');
    try {
      await _apiService.resetPointerAdmin();
      if (mounted) setState(() => _status = 'Pointer reset complete.');
      await _init();
    } catch (e) {
      if (mounted) setState(() => _status = 'Reset failed: $e');
    }
  }

  Future<void> _rebuild() async {
    final confirmed = await _showConfirm('Rebuild from scratch using all purchases?');
    if (confirmed != true) return;
    setState(() => _status = 'Rebuilding...');
    try {
      await _apiService.rebuildAdmin();
      if (mounted) setState(() => _status = 'Rebuild complete.');
      await _init();
    } catch (e) {
      if (mounted) setState(() => _status = 'Rebuild failed: $e');
    }
  }

  Future<bool?> _showConfirm(String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirm', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: _primary)),
        content: Text(message, style: GoogleFonts.inter()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _primary),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  void _generateShortageReport() {
    if (_netStock == null) return;
    final headers = (_netStock!['headers'] as List).cast<String>();
    final rows = _netStock!['rows'] as List;
    final newShortages = <String>[];

    for (var row in rows) {
      final values = (row['values'] as List).cast<num>();
      final type = row['type'] as String;
      for (var grade in _absGrades) {
        final idx = headers.indexOf(grade);
        if (idx != -1) {
          final val = values[idx].round();
          if (val < 0) {
            newShortages.add('$type - $grade: Short by ${val.abs()} kg');
          }
        }
      }
    }

    setState(() {
      _shortages = newShortages;
      _status = newShortages.isEmpty ? 'No shortages detected.' : 'Shortage report generated.';
    });
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
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildStatusBar(),
                            const SizedBox(height: 16),
                            if (_isAdmin) _buildAdminActions(),
                            if (_isAdmin) const SizedBox(height: 24),
                            _buildStockTable(),
                            if (_shortages.isNotEmpty) ...[
                              const SizedBox(height: 24),
                              _buildShortageReport(),
                            ],
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Stock Calculator',
                    style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
                const SizedBox(height: 4),
                Text('Net stock positions across grades',
                    style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
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
            onPressed: _generateShortageReport,
            icon: const Icon(Icons.assessment, size: 18),
            label: Text('Shortage Report', style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
          ),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.refresh, color: _primary), tooltip: 'Refresh', onPressed: _init),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: _primary.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.info_outline, color: _primary, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Status: $_status', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151))),
                if (_deltaStatus.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('Delta: $_deltaStatus',
                        style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF9CA3AF))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminActions() {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _adminBtn('Recalculate', Icons.calculate, const Color(0xFF3B82F6), _recalc),
        _adminBtn('Reset Pointer', Icons.replay, const Color(0xFFF59E0B), _resetPointer),
        _adminBtn('Rebuild', Icons.build, const Color(0xFFEF4444), _rebuild),
      ],
    );
  }

  Widget _adminBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withOpacity(0.3)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: GoogleFonts.inter(fontWeight: FontWeight.w500, fontSize: 13)),
    );
  }

  Widget _buildStockTable() {
    if (_netStock == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_cardRadius),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.inventory_2_outlined, size: 48, color: _primary.withOpacity(0.3)),
              const SizedBox(height: 12),
              Text('No stock data available', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
            ],
          ),
        ),
      );
    }

    final headers = (_netStock!['headers'] as List).cast<String>();
    final rows = _netStock!['rows'] as List;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _headerBg,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(_cardRadius),
                topRight: Radius.circular(_cardRadius),
              ),
            ),
            child: Text('Net Stock Position',
                style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: _primary)),
          ),
          ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(_cardRadius),
              bottomRight: Radius.circular(_cardRadius),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(_headerBg.withOpacity(0.5)),
                headingTextStyle: GoogleFonts.manrope(
                    fontSize: 11, fontWeight: FontWeight.w700, color: _primary, letterSpacing: 0.3),
                dataTextStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
                columnSpacing: 16,
                horizontalMargin: 16,
                columns: [
                  const DataColumn(label: Text('TYPE')),
                  ...headers.map((h) => DataColumn(label: Text(h), numeric: true)),
                ],
                rows: rows.map<DataRow>((row) {
                  final type = row['type']?.toString() ?? '';
                  final values = (row['values'] as List).cast<num>();
                  return DataRow(cells: [
                    DataCell(Text(type, style: GoogleFonts.manrope(fontWeight: FontWeight.w600))),
                    ...values.asMap().entries.map((entry) {
                      final val = entry.value.round();
                      Color textColor;
                      if (val < 0) {
                        textColor = const Color(0xFFEF4444);
                      } else if (val == 0) {
                        textColor = const Color(0xFF9CA3AF);
                      } else {
                        textColor = const Color(0xFF374151);
                      }
                      return DataCell(Text(
                        '$val',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: val < 0 ? FontWeight.w600 : FontWeight.w400,
                          color: textColor,
                        ),
                      ));
                    }),
                  ]);
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortageReport() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444).withOpacity(0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(_cardRadius),
                topRight: Radius.circular(_cardRadius),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning, size: 18, color: Color(0xFFEF4444)),
                const SizedBox(width: 8),
                Text('Shortage Report (${_shortages.length} items)',
                    style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: const Color(0xFFEF4444))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: _shortages.map((s) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(s, style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)))),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 56, color: Colors.red.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text('Failed to load stock data', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
          const SizedBox(height: 8),
          Text(_error ?? '', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _primary),
            onPressed: _init,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Retry', style: GoogleFonts.inter()),
          ),
        ],
      ),
    );
  }
}
