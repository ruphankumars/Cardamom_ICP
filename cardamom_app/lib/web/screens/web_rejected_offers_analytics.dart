import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../web_shell.dart';

/// Web-optimized Rejected Offers Analytics screen.
///
/// Displays summary KPIs, bar chart by grade, pie chart by client,
/// and a detailed rejections data table, all driven by a date-range picker.
class WebRejectedOffersAnalytics extends StatefulWidget {
  const WebRejectedOffersAnalytics({Key? key}) : super(key: key);

  @override
  State<WebRejectedOffersAnalytics> createState() =>
      _WebRejectedOffersAnalyticsState();
}

class _WebRejectedOffersAnalyticsState
    extends State<WebRejectedOffersAnalytics> {
  final ApiService _apiService = ApiService();

  // State
  bool _isLoading = true;
  String? _errorMessage;
  Map<String, dynamic> _analytics = {};
  List<Map<String, dynamic>> _rejectedOffers = [];

  // Date range
  late DateTimeRange _dateRange;

  // Chart palette
  static const List<Color> _chartColors = [
    Color(0xFF5D6E7E),
    Color(0xFF3B82F6),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFF10B981),
    Color(0xFF8B5CF6),
    Color(0xFFEC4899),
    Color(0xFF06B6D4),
    Color(0xFFF97316),
    Color(0xFF6366F1),
  ];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _dateRange = DateTimeRange(
      start: now.subtract(const Duration(days: 30)),
      end: now,
    );
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final dateFrom = _dateRange.start.toIso8601String();
      final dateTo = _dateRange.end.toIso8601String();

      final results = await Future.wait([
        _apiService
            .getRejectedOffersAnalytics({'dateFrom': dateFrom, 'dateTo': dateTo}),
        _apiService
            .getRejectedOffersList({'dateFrom': dateFrom, 'dateTo': dateTo, 'limit': 100}),
      ]);

      if (mounted) {
        setState(() {
          _analytics = results[0] as Map<String, dynamic>? ?? {};
          _rejectedOffers =
              List<Map<String, dynamic>>.from(results[1] as List? ?? []);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load analytics: $e';
        });
      }
      debugPrint('WebRejectedOffersAnalytics load error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Date range picker
  // ---------------------------------------------------------------------------

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _dateRange,
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF5D6E7E),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Color(0xFF1E293B),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _dateRange = picked);
      _loadData();
    }
  }

  // ---------------------------------------------------------------------------
  // Computed data helpers
  // ---------------------------------------------------------------------------

  int get _totalRejections => (_analytics['rejectionCount'] as num?)?.toInt() ?? 0;

  double get _averageGap => (_analytics['overallAvgGap'] as num?)?.toDouble() ?? 0;

  Map<String, num> get _gapByClient {
    final raw = _analytics['avgGapByClient'];
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), (v as num?) ?? 0));
    }
    return {};
  }

  Map<String, num> get _gapByGrade {
    final raw = _analytics['avgGapByGrade'];
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), (v as num?) ?? 0));
    }
    return {};
  }

  int get _byPriceCount {
    // Count offers where gap > 0 (rejected primarily due to price)
    int count = 0;
    for (final offer in _rejectedOffers) {
      final gap = offer['gapAnalysis'];
      if (gap != null && gap is Map && (gap['totalGap'] as num? ?? 0) > 0) {
        count++;
      }
    }
    return count;
  }

  String get _mostRejectedGrade {
    if (_gapByGrade.isEmpty) return '--';
    final sorted = _gapByGrade.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM yyyy');
    final rangeLabel =
        '${dateFormat.format(_dateRange.start)} - ${dateFormat.format(_dateRange.end)}';

    return WebShell(
      title: 'Rejected Offers Analytics',
      topActions: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _pickDateRange,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.calendar_today_rounded,
                      size: 16, color: Color(0xFF5D6E7E)),
                  const SizedBox(width: 8),
                  Text(
                    rangeLabel,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF374151),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more_rounded,
                      size: 18, color: Color(0xFF9CA3AF)),
                ],
              ),
            ),
          ),
        ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const SizedBox(
        height: 400,
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFF5D6E7E)),
        ),
      );
    }

    if (_errorMessage != null) {
      return _buildErrorState();
    }

    if (_totalRejections == 0 && _rejectedOffers.isEmpty) {
      return _buildEmptyState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // KPI summary cards row
        _buildKpiRow(),
        const SizedBox(height: 24),

        // Charts row
        _buildChartsRow(),
        const SizedBox(height: 24),

        // Detailed table
        _buildDetailedTable(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  Widget _buildErrorState() {
    return _card(
      child: SizedBox(
        height: 300,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 48, color: Color(0xFFEF4444)),
              const SizedBox(height: 12),
              Text(
                _errorMessage ?? 'An unknown error occurred.',
                style: GoogleFonts.inter(
                    fontSize: 14, color: const Color(0xFF6B7280)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadData,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text('Retry',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF5D6E7E),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState() {
    return _card(
      child: SizedBox(
        height: 300,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inbox_outlined,
                  size: 48, color: Color(0xFFCBD5E1)),
              const SizedBox(height: 12),
              Text(
                'No rejected offers found for this date range.',
                style: GoogleFonts.inter(
                    fontSize: 14, color: const Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 6),
              Text(
                'Try selecting a wider date range.',
                style: GoogleFonts.inter(
                    fontSize: 13, color: const Color(0xFFBCC5D0)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // KPI summary row
  // ---------------------------------------------------------------------------

  Widget _buildKpiRow() {
    return Row(
      children: [
        Expanded(
          child: _buildKpiCard(
            title: 'Total Rejected',
            value: '$_totalRejections',
            icon: Icons.block_rounded,
            iconColor: const Color(0xFFEF4444),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildKpiCard(
            title: 'By Price',
            value: '$_byPriceCount',
            icon: Icons.currency_rupee_rounded,
            iconColor: const Color(0xFFF59E0B),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildKpiCard(
            title: 'Average Margin Gap',
            value: '\u20B9${_averageGap.toStringAsFixed(0)}/kg',
            icon: Icons.trending_down_rounded,
            iconColor: const Color(0xFF3B82F6),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildKpiCard(
            title: 'Most Rejected Grade',
            value: _mostRejectedGrade,
            icon: Icons.grade_rounded,
            iconColor: const Color(0xFF8B5CF6),
          ),
        ),
      ],
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required IconData icon,
    required Color iconColor,
  }) {
    return _card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 22, color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF9CA3AF),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: GoogleFonts.manrope(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1E293B),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Charts row
  // ---------------------------------------------------------------------------

  Widget _buildChartsRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Bar chart: by grade
        Expanded(flex: 3, child: _buildGradeBarChart()),
        const SizedBox(width: 16),
        // Pie chart: by client
        Expanded(flex: 2, child: _buildClientPieChart()),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Bar chart (by grade)
  // ---------------------------------------------------------------------------

  Widget _buildGradeBarChart() {
    final gradeGaps = _gapByGrade;
    final sortedEntries = gradeGaps.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final displayEntries = sortedEntries.take(10).toList();

    return _card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Price Gap by Grade',
              style: GoogleFonts.manrope(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Average gap between admin offer and client counter per grade',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: const Color(0xFF9CA3AF),
              ),
            ),
            const SizedBox(height: 24),
            if (displayEntries.isEmpty)
              SizedBox(
                height: 300,
                child: Center(
                  child: Text(
                    'No grade data available',
                    style: GoogleFonts.inter(
                        fontSize: 13, color: const Color(0xFFBCC5D0)),
                  ),
                ),
              )
            else
              SizedBox(
                height: 320,
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: _barMaxY(displayEntries),
                    barTouchData: BarTouchData(
                      enabled: true,
                      touchTooltipData: BarTouchTooltipData(
                        tooltipRoundedRadius: 8,
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          final entry = displayEntries[group.x.toInt()];
                          return BarTooltipItem(
                            '${entry.key}\n',
                            GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            children: [
                              TextSpan(
                                text:
                                    '\u20B9${entry.value.toStringAsFixed(0)}/kg',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w400,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      show: true,
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 50,
                          getTitlesWidget: (value, meta) {
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                '\u20B9${value.toInt()}',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: const Color(0xFF9CA3AF),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 36,
                          getTitlesWidget: (value, meta) {
                            final idx = value.toInt();
                            if (idx < 0 || idx >= displayEntries.length) {
                              return const SizedBox.shrink();
                            }
                            final label = displayEntries[idx].key;
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                label.length > 8
                                    ? '${label.substring(0, 8)}...'
                                    : label,
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  color: const Color(0xFF6B7280),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            );
                          },
                        ),
                      ),
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                    ),
                    borderData: FlBorderData(show: false),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: _barInterval(displayEntries),
                      getDrawingHorizontalLine: (value) => FlLine(
                        color: const Color(0xFFF3F4F6),
                        strokeWidth: 1,
                      ),
                    ),
                    barGroups: List.generate(displayEntries.length, (i) {
                      final val = displayEntries[i].value.toDouble();
                      final color =
                          _chartColors[i % _chartColors.length];
                      return BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: val,
                            color: color,
                            width: 24,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(6),
                              topRight: Radius.circular(6),
                            ),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  double _barMaxY(List<MapEntry<String, num>> entries) {
    if (entries.isEmpty) return 100;
    final maxVal = entries.first.value.toDouble();
    return (maxVal * 1.2).ceilToDouble();
  }

  double _barInterval(List<MapEntry<String, num>> entries) {
    final maxY = _barMaxY(entries);
    if (maxY <= 0) return 50;
    final raw = maxY / 5;
    if (raw <= 0) return 50;
    return raw.ceilToDouble();
  }

  // ---------------------------------------------------------------------------
  // Pie chart (by client)
  // ---------------------------------------------------------------------------

  Widget _buildClientPieChart() {
    final clientGaps = _gapByClient;
    final sortedEntries = clientGaps.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final displayEntries = sortedEntries.take(8).toList();
    final totalGap =
        displayEntries.fold<double>(0, (sum, e) => sum + e.value.toDouble());

    return _card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Gap by Client',
              style: GoogleFonts.manrope(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Avg price gap contribution per client',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: const Color(0xFF9CA3AF),
              ),
            ),
            const SizedBox(height: 16),
            if (displayEntries.isEmpty)
              SizedBox(
                height: 300,
                child: Center(
                  child: Text(
                    'No client data available',
                    style: GoogleFonts.inter(
                        fontSize: 13, color: const Color(0xFFBCC5D0)),
                  ),
                ),
              )
            else ...[
              SizedBox(
                height: 200,
                child: PieChart(
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 40,
                    sections: List.generate(displayEntries.length, (i) {
                      final entry = displayEntries[i];
                      final pct = totalGap > 0
                          ? (entry.value.toDouble() / totalGap) * 100
                          : 0.0;
                      return PieChartSectionData(
                        value: entry.value.toDouble(),
                        color: _chartColors[i % _chartColors.length],
                        radius: 50,
                        title: '${pct.toStringAsFixed(0)}%',
                        titleStyle: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      );
                    }),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Legend
              ...List.generate(displayEntries.length, (i) {
                final entry = displayEntries[i];
                final color = _chartColors[i % _chartColors.length];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.key,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: const Color(0xFF4B5563),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '\u20B9${entry.value.toStringAsFixed(0)}',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF1E293B),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Detailed rejections table
  // ---------------------------------------------------------------------------

  Widget _buildDetailedTable() {
    return _card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Detailed Rejections',
                    style: GoogleFonts.manrope(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1E293B),
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${_rejectedOffers.length} records',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF6B7280),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_rejectedOffers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    'No rejection records to display.',
                    style: GoogleFonts.inter(
                        fontSize: 13, color: const Color(0xFFBCC5D0)),
                  ),
                ),
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(
                        const Color(0xFFF9FAFB)),
                    headingTextStyle: GoogleFonts.manrope(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF6B7280),
                    ),
                    dataTextStyle: GoogleFonts.inter(
                      fontSize: 13,
                      color: const Color(0xFF374151),
                    ),
                    columnSpacing: 32,
                    horizontalMargin: 16,
                    columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Client')),
                      DataColumn(label: Text('Grade')),
                      DataColumn(label: Text('Offered Price'), numeric: true),
                      DataColumn(label: Text('Reason')),
                    ],
                    rows: _rejectedOffers.map((offer) {
                      final dateStr = _formatDate(offer['createdAt']);
                      final clientName =
                          offer['clientName']?.toString() ?? 'Unknown';

                      // Extract grade / price info from gapAnalysis items
                      final gapItems =
                          (offer['gapAnalysis']?['items'] as List?) ?? [];
                      final gradeLabel = gapItems.isNotEmpty
                          ? gapItems
                              .map((g) => g['grade']?.toString() ?? '')
                              .where((g) => g.isNotEmpty)
                              .join(', ')
                          : '--';
                      final offeredPrice = gapItems.isNotEmpty
                          ? gapItems
                              .map((g) =>
                                  '\u20B9${(g['adminRate'] as num?)?.toStringAsFixed(0) ?? '0'}')
                              .join(', ')
                          : '--';
                      final reason =
                          (offer['rejectionReason']?.toString().isNotEmpty ==
                                  true)
                              ? offer['rejectionReason'].toString()
                              : 'Price mismatch';

                      return DataRow(
                        cells: [
                          DataCell(Text(dateStr)),
                          DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 160),
                              child: Text(clientName,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 140),
                              child: Text(gradeLabel,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          DataCell(Text(offeredPrice)),
                          DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 200),
                              child: Text(
                                reason,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: const Color(0xFF9CA3AF),
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Standard white card wrapper with 12px radius and subtle shadow.
  Widget _card({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  String _formatDate(dynamic dateValue) {
    if (dateValue == null) return '--';
    try {
      final dt = DateTime.parse(dateValue.toString());
      return DateFormat('dd MMM yyyy').format(dt);
    } catch (_) {
      final str = dateValue.toString();
      if (str.length >= 10) return str.substring(0, 10);
      return str;
    }
  }
}
