import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// A horizontal scrollable calendar strip for selecting dates
/// with navigation arrows to move forward/backward through weeks
/// and date-tap functionality to show day activities
class CalendarStrip extends StatefulWidget {
  final DateTime? selectedDate;
  final ValueChanged<DateTime>? onDateSelected;
  final int daysToShow;
  final Color? accentColor;
  /// Callback to get activities/orders for a specific date
  final Future<List<Map<String, dynamic>>> Function(DateTime)? getActivitiesForDate;
  /// Callback to get summary stats {orders, packed, revenue} for a date
  final Map<String, dynamic> Function(DateTime)? getDateStats;

  const CalendarStrip({
    super.key,
    this.selectedDate,
    this.onDateSelected,
    this.daysToShow = 7,
    this.accentColor,
    this.getActivitiesForDate,
    this.getDateStats,
  });

  @override
  State<CalendarStrip> createState() => _CalendarStripState();
}

class _CalendarStripState extends State<CalendarStrip> {
  late DateTime _selectedDate;
  late DateTime _weekStart;
  late List<DateTime> _dates;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.selectedDate ?? DateTime.now();
    _weekStart = _getWeekStart(_selectedDate);
    _generateDates();
  }

  DateTime _getWeekStart(DateTime date) {
    return date.subtract(Duration(days: widget.daysToShow ~/ 2));
  }

  void _generateDates() {
    _dates = List.generate(
      widget.daysToShow,
      (index) => _weekStart.add(Duration(days: index)),
    );
  }

  void _navigateWeek(int direction) {
    HapticFeedback.lightImpact();
    setState(() {
      _weekStart = _weekStart.add(Duration(days: direction * widget.daysToShow));
      _generateDates();
    });
  }

  void _goToToday() {
    HapticFeedback.mediumImpact();
    setState(() {
      _selectedDate = DateTime.now();
      _weekStart = _getWeekStart(_selectedDate);
      _generateDates();
    });
    widget.onDateSelected?.call(_selectedDate);
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isToday(DateTime date) {
    return _isSameDay(date, DateTime.now());
  }

  bool _isTodayInView() {
    final today = DateTime.now();
    return _dates.any((d) => _isSameDay(d, today));
  }

  void _onDateTapped(DateTime date) {
    HapticFeedback.selectionClick();
    setState(() {
      _selectedDate = date;
    });
    widget.onDateSelected?.call(date);
    
    // Show the date details popup
    _showDateDetailsPopup(date);
  }

  void _showDateDetailsPopup(DateTime date) {
    final isToday = _isToday(date);
    final isFuture = date.isAfter(DateTime.now());
    final formattedDate = DateFormat('EEEE, MMM d, yyyy').format(date);
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4A5568), Color(0xFF2D3748)],
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[700], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isToday 
                        ? const Color(0xFF5D6E7E).withOpacity(0.2)
                        : isFuture
                            ? const Color(0xFF10B981).withOpacity(0.2)
                            : const Color(0xFF64748B).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    isToday ? Icons.today_rounded : isFuture ? Icons.event_rounded : Icons.history_rounded,
                    color: isToday 
                        ? const Color(0xFF5D6E7E)
                        : isFuture
                            ? const Color(0xFF10B981)
                            : const Color(0xFF64748B),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formattedDate,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isToday ? "📍 Today" : isFuture ? "🔮 Upcoming" : "📜 Past",
                        style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Quick Actions for the day
            Row(
              children: [
                Expanded(child: _buildDayAction('📦 Pack', 'Start packing for this date', const Color(0xFF5D6E7E), () {
                  Navigator.pop(context);
                  // Navigate to pack screen with date
                })),
                const SizedBox(width: 12),
                Expanded(child: _buildDayAction('📋 Orders', 'View orders for this date', const Color(0xFF10B981), () {
                  Navigator.pop(context);
                  // Navigate to orders with date filter
                })),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _buildDayAction('📊 Stats', 'View day statistics', const Color(0xFFF59E0B), () {
                  Navigator.pop(context);
                  _showDayStats(date);
                })),
                const SizedBox(width: 12),
                Expanded(child: _buildDayAction('📝 Note', 'Add reminder note', const Color(0xFFEF4444), () {
                  Navigator.pop(context);
                  _showAddNoteDialog(date);
                })),
              ],
            ),
            const SizedBox(height: 20),
            // Summary info
            Builder(builder: (_) {
              final stats = widget.getDateStats?.call(date);
              final ordersVal = stats?['orders']?.toString() ?? '--';
              final packedVal = stats?['packed']?.toString() ?? '--';
              final revenueVal = stats?['revenue']?.toString() ?? '--';
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildDateStat('Orders', ordersVal, const Color(0xFF5D6E7E)),
                    Container(width: 1, height: 30, color: Colors.white.withOpacity(0.1)),
                    _buildDateStat('Packed', packedVal, const Color(0xFF10B981)),
                    Container(width: 1, height: 30, color: Colors.white.withOpacity(0.1)),
                    _buildDateStat('Revenue', revenueVal, const Color(0xFFF59E0B)),
                  ],
                ),
              );
            }),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildDayAction(String title, String subtitle, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 9, color: color.withOpacity(0.7)), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _buildDateStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.5))),
      ],
    );
  }

  void _showDayStats(DateTime date) {
    final formattedDate = DateFormat('MMM d, yyyy').format(date);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('📊 Stats for $formattedDate', style: const TextStyle(fontSize: 16, color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Day statistics will be displayed here once you have data for this date.', 
              style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.7))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Color(0xFF5D6E7E))),
          ),
        ],
      ),
    );
  }

  void _showAddNoteDialog(DateTime date) {
    final formattedDate = DateFormat('MMM d').format(date);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('📝 Note for $formattedDate', style: const TextStyle(fontSize: 16, color: Colors.white)),
        content: TextField(
          maxLines: 3,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Enter your reminder...',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Note saved for $formattedDate'), backgroundColor: const Color(0xFF10B981)),
              );
            },
            child: const Text('Save', style: TextStyle(color: Color(0xFF5D6E7E), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFF5D6E7E); // Steel Blue
    final showTodayButton = !_isTodayInView();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        // Outer titanium-block
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
        ),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
          const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Navigation header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Left arrow - titanium-block button
                GestureDetector(
                  onTap: () => _navigateWeek(-1),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 3, offset: const Offset(2, 2)),
                        const BoxShadow(color: Colors.white70, blurRadius: 3, offset: Offset(-1, -1)),
                      ],
                    ),
                    child: Icon(Icons.chevron_left_rounded, color: accent, size: 24),
                  ),
                ),
                // Month/Year label
                Row(
                  children: [
                    Text(
                      DateFormat('MMMM yyyy').format(_dates.isNotEmpty ? _dates[_dates.length ~/ 2] : DateTime.now()).toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: accent,
                        letterSpacing: 3,
                      ),
                    ),
                    if (showTodayButton) ...[
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: _goToToday,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text('TODAY', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5)),
                        ),
                      ),
                    ],
                  ],
                ),
                // Right arrow - titanium-block button
                GestureDetector(
                  onTap: () => _navigateWeek(1),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 3, offset: const Offset(2, 2)),
                        const BoxShadow(color: Colors.white70, blurRadius: 3, offset: Offset(-1, -1)),
                      ],
                    ),
                    child: Icon(Icons.chevron_right_rounded, color: accent, size: 24),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Inner titanium-well for dates
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF9A9A94), // Titanium-well color
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                // Strong inset shadows
                BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(5, 5)),
                BoxShadow(color: Colors.white.withOpacity(0.2), blurRadius: 5, offset: const Offset(-2, -2)),
              ],
            ),
            child: Row(
              children: _dates.map((date) {
                final isSelected = _isSameDay(date, _selectedDate);
                final isToday = _isToday(date);

                return Expanded(
                  child: GestureDetector(
                    onTap: () => _onDateTapped(date),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: EdgeInsets.symmetric(vertical: isSelected ? 14 : 10),
                      decoration: BoxDecoration(
                        color: isSelected ? accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        border: isSelected ? Border.all(color: Colors.white.withOpacity(0.2), width: 1) : null,
                        boxShadow: isSelected
                            ? [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))]
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            DateFormat('EEE').format(date).toUpperCase().substring(0, 3),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: isSelected ? Colors.white : Colors.white.withOpacity(0.4),
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            date.day.toString(),
                            style: TextStyle(
                              fontSize: isSelected ? 18 : 16,
                              fontWeight: FontWeight.w900,
                              color: isSelected ? Colors.white : Colors.white.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          // Bottom indicator line
          Container(
            width: 48,
            height: 4,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}
