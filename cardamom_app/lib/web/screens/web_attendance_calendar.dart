import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/worker.dart';
import '../../services/attendance_service.dart';

/// Web-optimized Attendance Calendar.
/// Monthly grid with color-coded days. Click to see day details.
class WebAttendanceCalendar extends StatefulWidget {
  const WebAttendanceCalendar({super.key});

  @override
  State<WebAttendanceCalendar> createState() => _WebAttendanceCalendarState();
}

class _WebAttendanceCalendarState extends State<WebAttendanceCalendar> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _headerBg = Color(0xFFF1F5F9);
  static const _cardRadius = 12.0;

  late DateTime _currentMonth;
  Map<String, CalendarEntry> _calendarData = {};
  bool _isLoading = true;
  String? _error;
  String? _selectedDate;
  AttendanceSummary? _selectedDaySummary;
  bool _isLoadingDetails = false;

  @override
  void initState() {
    super.initState();
    _currentMonth = DateTime.now();
    _loadCalendar();
  }

  Future<void> _loadCalendar() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final service = Provider.of<AttendanceService>(context, listen: false);
      final data = await service.getCalendar(_currentMonth.year, _currentMonth.month);
      if (mounted) {
        setState(() {
          _calendarData = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _selectDate(String date) async {
    setState(() {
      _selectedDate = date;
      _selectedDaySummary = null;
      _isLoadingDetails = true;
    });
    try {
      final service = Provider.of<AttendanceService>(context, listen: false);
      final summary = await service.getAttendanceSummary(date);
      if (mounted) {
        setState(() {
          _selectedDaySummary = summary;
          _isLoadingDetails = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingDetails = false);
    }
  }

  void _previousMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
      _selectedDate = null;
      _selectedDaySummary = null;
    });
    _loadCalendar();
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
      _selectedDate = null;
      _selectedDaySummary = null;
    });
    _loadCalendar();
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
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: _buildCalendarGrid()),
                          if (_selectedDate != null) Expanded(flex: 2, child: _buildDayDetails()),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Attendance Calendar',
                    style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
                const SizedBox(height: 4),
                Text('Monthly overview of worker attendance',
                    style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
              ],
            ),
          ),
          _buildMonthSelector(),
        ],
      ),
    );
  }

  Widget _buildMonthSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _primary.withOpacity(0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20, color: _primary),
            onPressed: _previousMonth,
            splashRadius: 18,
          ),
          Text(
            DateFormat('MMMM yyyy').format(_currentMonth),
            style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: _primary),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20, color: _primary),
            onPressed: _nextMonth,
            splashRadius: 18,
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid() {
    final firstDay = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final daysInMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final startWeekday = firstDay.weekday % 7; // 0=Sunday

    const dayHeaders = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 12, 16, 32),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_cardRadius),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Day headers
            Row(
              children: dayHeaders.map((d) {
                return Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(d,
                          style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: _primary, letterSpacing: 0.5)),
                    ),
                  ),
                );
              }).toList(),
            ),
            // Calendar cells
            ...List.generate(((daysInMonth + startWeekday) / 7).ceil(), (week) {
              return Row(
                children: List.generate(7, (dayOfWeek) {
                  final dayIndex = week * 7 + dayOfWeek - startWeekday + 1;
                  if (dayIndex < 1 || dayIndex > daysInMonth) {
                    return const Expanded(child: SizedBox(height: 72));
                  }
                  final dateStr = DateFormat('yyyy-MM-dd')
                      .format(DateTime(_currentMonth.year, _currentMonth.month, dayIndex));
                  final entry = _calendarData[dateStr];
                  final isSelected = _selectedDate == dateStr;
                  final isToday = dateStr == DateFormat('yyyy-MM-dd').format(DateTime.now());

                  return Expanded(
                    child: GestureDetector(
                      onTap: () => _selectDate(dateStr),
                      child: Container(
                        height: 72,
                        margin: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? _primary.withOpacity(0.1)
                              : entry != null
                                  ? _getHeatColor(entry.workerCount)
                                  : _headerBg.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(8),
                          border: isToday
                              ? Border.all(color: _primary, width: 2)
                              : isSelected
                                  ? Border.all(color: _primary, width: 1.5)
                                  : null,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '$dayIndex',
                              style: GoogleFonts.manrope(
                                fontSize: 14,
                                fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                                color: isToday ? _primary : const Color(0xFF374151),
                              ),
                            ),
                            if (entry != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${entry.workerCount}',
                                style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280)),
                              ),
                              Text(
                                'Rs ${_formatCompact(entry.totalWages)}',
                                style: GoogleFonts.inter(fontSize: 9, color: const Color(0xFF9CA3AF)),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              );
            }),
            // Legend
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legendItem('No data', _headerBg.withOpacity(0.5)),
                const SizedBox(width: 16),
                _legendItem('Low', const Color(0xFF10B981).withOpacity(0.1)),
                const SizedBox(width: 16),
                _legendItem('Medium', const Color(0xFF10B981).withOpacity(0.25)),
                const SizedBox(width: 16),
                _legendItem('High', const Color(0xFF10B981).withOpacity(0.4)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _getHeatColor(int count) {
    if (count == 0) return _headerBg.withOpacity(0.5);
    if (count < 5) return const Color(0xFF10B981).withOpacity(0.1);
    if (count < 15) return const Color(0xFF10B981).withOpacity(0.25);
    return const Color(0xFF10B981).withOpacity(0.4);
  }

  String _formatCompact(double value) {
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return value.toStringAsFixed(0);
  }

  Widget _legendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 4),
        Text(label, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF6B7280))),
      ],
    );
  }

  Widget _buildDayDetails() {
    final date = DateTime.tryParse(_selectedDate ?? '');
    final formattedDate = date != null ? DateFormat('EEEE, MMM d').format(date) : '';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 12, 32, 32),
      child: Container(
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(formattedDate,
                      style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: _primary)),
                  if (_selectedDaySummary != null)
                    Text(
                      '${_selectedDaySummary!.totalWorkers} workers | Rs ${_selectedDaySummary!.totalWages.toStringAsFixed(0)}',
                      style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280)),
                    ),
                ],
              ),
            ),
            if (_isLoadingDetails)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_selectedDaySummary == null || _selectedDaySummary!.workers.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text('No attendance data', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF))),
                ),
              )
            else
              ..._selectedDaySummary!.workers.map((record) {
                Color statusColor;
                switch (record.status) {
                  case AttendanceStatus.full:
                    statusColor = const Color(0xFF10B981);
                    break;
                  case AttendanceStatus.halfAm:
                    statusColor = const Color(0xFFF59E0B);
                    break;
                  case AttendanceStatus.halfPm:
                    statusColor = const Color(0xFF8B5CF6);
                    break;
                  case AttendanceStatus.ot:
                    statusColor = const Color(0xFF3B82F6);
                    break;
                }
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 14,
                    backgroundColor: statusColor.withOpacity(0.1),
                    child: Text(
                      record.workerName.isNotEmpty ? record.workerName[0].toUpperCase() : '?',
                      style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: statusColor),
                    ),
                  ),
                  title: Text(record.workerName,
                      style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500)),
                  subtitle: Text(record.status.displayName,
                      style: GoogleFonts.inter(fontSize: 11, color: statusColor)),
                  trailing: Text('Rs ${record.finalWage.toStringAsFixed(0)}',
                      style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF374151))),
                );
              }),
          ],
        ),
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
          Text('Failed to load calendar', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
          const SizedBox(height: 8),
          Text(_error ?? '', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _primary),
            onPressed: _loadCalendar,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Retry', style: GoogleFonts.inter()),
          ),
        ],
      ),
    );
  }
}
