import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/worker.dart';
import '../../services/attendance_service.dart';
import '../../services/auth_provider.dart';

/// Web-optimized Attendance Dashboard (NO camera).
/// Date picker, summary stats, worker attendance table.
class WebAttendanceDashboard extends StatefulWidget {
  final String? initialDate;

  const WebAttendanceDashboard({super.key, this.initialDate});

  @override
  State<WebAttendanceDashboard> createState() => _WebAttendanceDashboardState();
}

class _WebAttendanceDashboardState extends State<WebAttendanceDashboard> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _headerBg = Color(0xFFF1F5F9);
  static const _cardRadius = 12.0;

  late String _selectedDate;
  bool _isLoading = true;
  String? _error;
  final TextEditingController _searchCtrl = TextEditingController();
  List<Worker> _searchResults = [];
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
    _loadData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _isToday => _selectedDate == DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final service = Provider.of<AttendanceService>(context, listen: false);
      await Future.wait([
        service.loadWorkers(),
        service.loadSummary(_selectedDate),
      ]);
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

  void _onSearch(String query) {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _showSearch = false;
      });
      return;
    }
    final service = Provider.of<AttendanceService>(context, listen: false);
    final markedIds = service.todaySummary?.workers.map((w) => w.workerId).toSet() ?? {};
    final results = service.workers
        .where((w) => !markedIds.contains(w.id) && w.name.toLowerCase().contains(query.toLowerCase()))
        .take(5)
        .toList();
    setState(() {
      _searchResults = results;
      _showSearch = true;
    });
  }

  Future<void> _addWorker(Worker worker) async {
    final service = Provider.of<AttendanceService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    await service.markAttendance(
      workerId: worker.id,
      workerName: worker.name,
      date: _selectedDate,
      status: AttendanceStatus.full,
      markedBy: auth.username ?? 'web',
    );
    await service.loadSummary(_selectedDate);
    if (mounted) {
      _searchCtrl.clear();
      setState(() => _showSearch = false);
    }
  }

  Future<void> _removeWorker(AttendanceRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove Attendance', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Remove ${record.workerName} from attendance?', style: GoogleFonts.inter()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final service = Provider.of<AttendanceService>(context, listen: false);
      await service.removeAttendance(_selectedDate, record.workerId);
      await service.loadSummary(_selectedDate);
      if (mounted) setState(() {});
    }
  }

  Future<void> _changeStatus(AttendanceRecord record, AttendanceStatus newStatus) async {
    final service = Provider.of<AttendanceService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    await service.markAttendance(
      workerId: record.workerId,
      workerName: record.workerName,
      date: _selectedDate,
      status: newStatus,
      markedBy: auth.username ?? 'web',
    );
    await service.loadSummary(_selectedDate);
    if (mounted) setState(() {});
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
                            _buildSummaryCards(),
                            const SizedBox(height: 24),
                            _buildAddWorkerSection(),
                            const SizedBox(height: 24),
                            _buildAttendanceTable(),
                          ],
                        ),
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
                Text('Attendance Dashboard',
                    style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.calendar_today, size: 14, color: const Color(0xFF6B7280)),
                    const SizedBox(width: 6),
                    Text('$dayName, $formattedDate',
                        style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
                    if (_isToday)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('Today', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF10B981))),
                        ),
                      ),
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
          IconButton(
            icon: const Icon(Icons.refresh, color: _primary),
            tooltip: 'Refresh',
            onPressed: _loadData,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    return Consumer<AttendanceService>(
      builder: (context, service, _) {
        final summary = service.todaySummary;
        return Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            _statCard('Total Workers', '${summary?.totalWorkers ?? 0}', Icons.people, _primary),
            _statCard('Full Day', '${summary?.fullDay ?? 0}', Icons.check_circle, const Color(0xFF10B981)),
            _statCard('Half AM', '${summary?.halfAm ?? 0}', Icons.wb_sunny, const Color(0xFFF59E0B)),
            _statCard('Half PM', '${summary?.halfPm ?? 0}', Icons.nightlight, const Color(0xFF8B5CF6)),
            _statCard('Overtime', '${summary?.overtime ?? 0}', Icons.timer, const Color(0xFF3B82F6)),
            _statCard('Total Wages', 'Rs ${(summary?.totalWages ?? 0).toStringAsFixed(0)}', Icons.payments, const Color(0xFFEC4899)),
          ],
        );
      },
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Container(
      width: 175,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 10),
          Text(value, style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
          const SizedBox(height: 2),
          Text(label, style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280))),
        ],
      ),
    );
  }

  Widget _buildAddWorkerSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add Worker', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700, color: _primary)),
        const SizedBox(height: 8),
        SizedBox(
          width: 400,
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onSearch,
            style: GoogleFonts.inter(fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search worker by name...',
              hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
              prefixIcon: const Icon(Icons.person_search, size: 20, color: Color(0xFF9CA3AF)),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: _primary.withOpacity(0.15)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: _primary.withOpacity(0.15)),
              ),
            ),
          ),
        ),
        if (_showSearch && _searchResults.isNotEmpty)
          Container(
            width: 400,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _searchResults.map((w) {
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: _primary.withOpacity(0.1),
                    child: Text(w.name.isNotEmpty ? w.name[0].toUpperCase() : '?',
                        style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: _primary, fontSize: 13)),
                  ),
                  title: Text(w.name, style: GoogleFonts.inter(fontSize: 14)),
                  subtitle: Text('${w.team} | Rs ${w.baseDailyWage.toStringAsFixed(0)}/day',
                      style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF))),
                  trailing: IconButton(
                    icon: const Icon(Icons.add_circle, color: Color(0xFF10B981)),
                    onPressed: () => _addWorker(w),
                  ),
                );
              }).toList(),
            ),
          ),
        if (_showSearch && _searchResults.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('No workers found', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF))),
          ),
      ],
    );
  }

  Widget _buildAttendanceTable() {
    return Consumer<AttendanceService>(
      builder: (context, service, _) {
        final summary = service.todaySummary;
        final workers = summary?.workers ?? [];

        if (workers.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(_cardRadius),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Column(
              children: [
                Icon(Icons.people_outline, size: 48, color: _primary.withOpacity(0.3)),
                const SizedBox(height: 12),
                Text('No attendance records', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
                const SizedBox(height: 4),
                Text('Search and add workers above', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
              ],
            ),
          );
        }

        return Container(
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
              columnSpacing: 24,
              horizontalMargin: 20,
              columns: const [
                DataColumn(label: Text('WORKER')),
                DataColumn(label: Text('STATUS')),
                DataColumn(label: Text('WAGE')),
                DataColumn(label: Text('OT HOURS')),
                DataColumn(label: Text('MARKED BY')),
                DataColumn(label: Text('ACTIONS')),
              ],
              rows: workers.map((record) {
                return DataRow(cells: [
                  DataCell(Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: _primary.withOpacity(0.1),
                        child: Text(
                          record.workerName.isNotEmpty ? record.workerName[0].toUpperCase() : '?',
                          style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: _primary),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(record.workerName),
                    ],
                  )),
                  DataCell(_buildStatusDropdown(record)),
                  DataCell(Text('Rs ${record.finalWage.toStringAsFixed(0)}')),
                  DataCell(Text(record.otHours > 0 ? '${record.otHours}h' : '-')),
                  DataCell(Text(record.markedBy ?? '-',
                      style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF9CA3AF)))),
                  DataCell(
                    IconButton(
                      icon: Icon(Icons.remove_circle_outline, size: 18, color: Colors.red.withOpacity(0.6)),
                      tooltip: 'Remove',
                      onPressed: () => _removeWorker(record),
                    ),
                  ),
                ]);
              }).toList(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusDropdown(AttendanceRecord record) {
    return DropdownButton<AttendanceStatus>(
      value: record.status,
      underline: const SizedBox.shrink(),
      isDense: true,
      style: GoogleFonts.inter(fontSize: 13),
      items: AttendanceStatus.values.map((s) {
        Color color;
        switch (s) {
          case AttendanceStatus.full:
            color = const Color(0xFF10B981);
            break;
          case AttendanceStatus.halfAm:
            color = const Color(0xFFF59E0B);
            break;
          case AttendanceStatus.halfPm:
            color = const Color(0xFF8B5CF6);
            break;
          case AttendanceStatus.ot:
            color = const Color(0xFF3B82F6);
            break;
        }
        return DropdownMenuItem(
          value: s,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
            child: Text(s.displayName, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ),
        );
      }).toList(),
      onChanged: (v) {
        if (v != null && v != record.status) _changeStatus(record, v);
      },
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 56, color: Colors.red.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text('Failed to load attendance', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
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
