import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../models/worker.dart';
import '../services/attendance_service.dart';
import '../services/navigation_service.dart';

class AttendanceCalendarScreen extends StatefulWidget {
  const AttendanceCalendarScreen({super.key});

  @override
  State<AttendanceCalendarScreen> createState() => _AttendanceCalendarScreenState();
}

class _AttendanceCalendarScreenState extends State<AttendanceCalendarScreen> with RouteAware {
  late DateTime _currentMonth;
  Map<String, CalendarEntry> _calendarData = {};
  bool _isLoading = true;
  String? _selectedDate;
  AttendanceSummary? _selectedDaySummary;

  @override
  void initState() {
    super.initState();
    _currentMonth = DateTime.now();
    _loadCalendarData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() => _loadCalendarData();

  Future<void> _loadCalendarData() async {
    setState(() => _isLoading = true);
    final service = Provider.of<AttendanceService>(context, listen: false);
    final data = await service.getCalendar(_currentMonth.year, _currentMonth.month);
    if (!mounted) return;
    setState(() {
      _calendarData = data;
      _isLoading = false;
    });
  }

  Future<void> _selectDate(String date) async {
    setState(() {
      _selectedDate = date;
      _selectedDaySummary = null;
    });

    final service = Provider.of<AttendanceService>(context, listen: false);
    final summary = await service.getAttendanceSummary(date);

    if (!mounted) return;
    setState(() {
      _selectedDaySummary = summary;
    });
  }

  void _previousMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
      _selectedDate = null;
      _selectedDaySummary = null;
    });
    _loadCalendarData();
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
      _selectedDate = null;
      _selectedDaySummary = null;
    });
    _loadCalendarData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildMonthSelector(),
              Expanded(
                child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _buildCalendarGrid(),
              ),
              if (_selectedDate != null) _buildDayDetails(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 44, height: 44,
              decoration: AppTheme.machinedDecoration,
              child: const Icon(Icons.arrow_back_rounded, color: AppTheme.primary, size: 22),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              'ATTENDANCE CALENDAR',
              style: GoogleFonts.manrope(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: AppTheme.primary,
                letterSpacing: 2.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthSelector() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.titaniumMid,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: _previousMonth,
          ),
          Text(
            DateFormat('MMMM yyyy').format(_currentMonth),
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.title,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: _nextMonth,
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid() {
    final firstDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final lastDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0);
    final startingWeekday = firstDayOfMonth.weekday % 7; // 0 = Sunday

    final days = <Widget>[];
    
    // Day labels
    const dayLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    for (final label in dayLabels) {
      days.add(Center(
        child: Text(label, style: TextStyle(
          color: AppTheme.muted,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        )),
      ));
    }

    // Empty cells for days before first of month
    for (int i = 0; i < startingWeekday; i++) {
      days.add(const SizedBox());
    }

    // Calendar days
    for (int day = 1; day <= lastDayOfMonth.day; day++) {
      final date = DateTime(_currentMonth.year, _currentMonth.month, day);
      final dateStr = DateFormat('yyyy-MM-dd').format(date);
      final entry = _calendarData[dateStr];
      final isToday = DateFormat('yyyy-MM-dd').format(DateTime.now()) == dateStr;
      final isSelected = _selectedDate == dateStr;
      final hasData = entry != null && entry.workerCount > 0;

      days.add(GestureDetector(
        onTap: () => _selectDate(dateStr),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: isSelected 
              ? AppTheme.primary 
              : hasData 
                ? AppTheme.success.withOpacity(0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: isToday ? Border.all(color: AppTheme.primary, width: 2) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$day',
                style: TextStyle(
                  color: isSelected ? Colors.white : AppTheme.title,
                  fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              if (hasData) ...[
                Text(
                  '${entry.workerCount}',
                  style: TextStyle(
                    fontSize: 10,
                    color: isSelected ? Colors.white70 : AppTheme.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ));
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: GridView.count(
        crossAxisCount: 7,
        childAspectRatio: 1,
        children: days,
      ),
    );
  }

  Widget _buildDayDetails() {
    final entry = _calendarData[_selectedDate];
    final summary = _selectedDaySummary;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      DateFormat('EEEE, MMM d').format(DateTime.parse(_selectedDate!)),
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (entry != null)
                      Text(
                        '${entry.workerCount} workers • ₹${entry.totalWages.toStringAsFixed(0)}',
                        style: TextStyle(color: AppTheme.muted),
                      ),
                  ],
                ),
              ),
              if (summary != null && summary.totalWorkers > 0)
                TextButton.icon(
                  onPressed: () {
                    Navigator.pushNamed(
                      context, 
                      '/attendance',
                      arguments: {'date': _selectedDate},
                    );
                  },
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('View'),
                ),
            ],
          ),
          if (summary != null && summary.workers.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: summary.workers.length,
                itemBuilder: (ctx, i) {
                  final worker = summary.workers[i];
                  return Container(
                    width: 100,
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.titaniumLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: _getStatusColor(worker.status),
                          child: Text(
                            worker.workerName.isNotEmpty 
                              ? worker.workerName[0].toUpperCase() 
                              : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          worker.workerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          '₹${worker.finalWage.toStringAsFixed(0)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.success,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ] else if (entry == null || entry.workerCount == 0) ...[
            const SizedBox(height: 16),
            Center(
              child: Text(
                'No attendance recorded',
                style: TextStyle(color: AppTheme.muted),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _getStatusColor(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.full:
        return AppTheme.success;
      case AttendanceStatus.halfAm:
      case AttendanceStatus.halfPm:
        return AppTheme.warning;
      case AttendanceStatus.ot:
        return AppTheme.secondary;
    }
  }
}
