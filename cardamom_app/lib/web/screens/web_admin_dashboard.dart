import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../widgets/web_chart_card.dart';
import '../widgets/web_loading_shimmer.dart' as shimmer;
import '../widgets/web_metric_row.dart';

class WebAdminDashboard extends StatefulWidget {
  const WebAdminDashboard({super.key});

  @override
  State<WebAdminDashboard> createState() => _WebAdminDashboardState();
}

class _WebAdminDashboardState extends State<WebAdminDashboard> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic>? _dashboardData;
  List<dynamic> _pendingOrders = [];
  List<dynamic> _todayCart = [];
  DateTime _selectedDate = DateTime.now();

  final _currencyFormat = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '\u20B9',
    decimalDigits: 0,
  );

  @override
  void initState() {
    super.initState();
    _loadDashboard();
  }

  Future<void> _loadDashboard() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await _apiService.getDashboard();
      final pendingResponse = await _apiService.getPendingOrders();
      final cartResponse = await _apiService.getTodayCart();

      if (!mounted) return;

      final data = response.data;
      setState(() {
        _dashboardData = data is Map<String, dynamic> ? data : null;
        _pendingOrders =
            pendingResponse.data is List ? List.from(pendingResponse.data) : [];
        _todayCart =
            cartResponse.data is List ? List.from(cartResponse.data) : [];
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading dashboard: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to load dashboard. Tap to retry.';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  num _parseNum(dynamic v) =>
      v is num ? v : (num.tryParse('$v') ?? 0);

  String _fmtCurrency(dynamic v) {
    final n = _parseNum(v);
    return _currencyFormat.format(n);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _buildShimmer();
    if (_error != null) return _buildError();

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final username = auth.username ?? 'Admin';

    return Container(
      color: const Color(0xFFF8F9FA),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(username),
            const SizedBox(height: 24),
            _buildMetricCards(),
            const SizedBox(height: 24),
            _buildChartsRow(),
            const SizedBox(height: 24),
            _buildTablesRow(),
            const SizedBox(height: 24),
            _buildQuickActions(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header with date picker
  // ---------------------------------------------------------------------------

  Widget _buildHeader(String username) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Welcome back, $username',
                style: GoogleFonts.manrope(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                DateFormat('EEEE, d MMMM yyyy').format(_selectedDate),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: const Color(0xFF6B7280),
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            IconButton(
              onPressed: _loadDashboard,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh',
              style: IconButton.styleFrom(
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildDatePicker(),
          ],
        ),
      ],
    );
  }

  Widget _buildDatePicker() {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _selectedDate,
          firstDate: DateTime(2020),
          lastDate: DateTime(2030),
        );
        if (picked != null) {
          setState(() => _selectedDate = picked);
          _loadDashboard();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.calendar_today_rounded, size: 16, color: Color(0xFF5D6E7E)),
            const SizedBox(width: 8),
            Text(
              DateFormat('dd MMM yyyy').format(_selectedDate),
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF374151),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Metric Cards
  // ---------------------------------------------------------------------------

  Widget _buildMetricCards() {
    final d = _dashboardData ?? {};
    final totalSales = _parseNum(d['todaySalesVal']);
    final pendingQty = _parseNum(d['pendingQty']);
    final packedKgs = _parseNum(d['todayPackedKgs']);
    final packedCount = _parseNum(d['todayPackedCount']);
    final totalStock = _parseNum(d['totalStock']);

    return WebMetricRow(
      metrics: [
        MetricData(
          label: 'Total Orders',
          value: '${pendingQty.toInt() + packedCount.toInt()}',
          icon: Icons.receipt_long_rounded,
          color: const Color(0xFF3B82F6),
        ),
        MetricData(
          label: 'Pending Orders',
          value: '${pendingQty.toInt()}',
          icon: Icons.hourglass_bottom_rounded,
          color: const Color(0xFFF59E0B),
        ),
        MetricData(
          label: 'Packed Today',
          value: '${packedCount.toInt()}',
          icon: Icons.check_circle_outline_rounded,
          color: const Color(0xFF10B981),
        ),
        MetricData(
          label: 'Packed Kgs',
          value: '${packedKgs.toStringAsFixed(1)} kg',
          icon: Icons.scale_rounded,
          color: const Color(0xFF8B5CF6),
        ),
        MetricData(
          label: 'Revenue Today',
          value: _fmtCurrency(totalSales),
          icon: Icons.currency_rupee_rounded,
          color: const Color(0xFF10B981),
          trendLabel: 'Stock: ${totalStock.toStringAsFixed(0)} kg',
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Charts Row
  // ---------------------------------------------------------------------------

  Widget _buildChartsRow() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildOrdersTrendChart()),
              const SizedBox(width: 16),
              Expanded(child: _buildStockDonutChart()),
            ],
          );
        }
        return Column(
          children: [
            _buildOrdersTrendChart(),
            const SizedBox(height: 16),
            _buildStockDonutChart(),
          ],
        );
      },
    );
  }

  Widget _buildOrdersTrendChart() {
    // Build bar data from recent cart entries grouped by date
    final Map<String, double> dailyKgs = {};
    for (final c in _todayCart) {
      if (c is! Map) continue;
      final dateStr = (c['packedDate'] ?? '').toString();
      final kgs = _parseNum(c['kgs']).toDouble();
      dailyKgs[dateStr] = (dailyKgs[dateStr] ?? 0) + kgs;
    }

    final sortedKeys = dailyKgs.keys.toList()..sort();
    final recentKeys = sortedKeys.length > 7
        ? sortedKeys.sublist(sortedKeys.length - 7)
        : sortedKeys;

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < recentKeys.length; i++) {
      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: dailyKgs[recentKeys[i]] ?? 0,
              color: const Color(0xFF3B82F6),
              width: 20,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            ),
          ],
        ),
      );
    }

    return WebChartCard(
      title: 'Orders Trend',
      subtitle: 'Packed kgs by date',
      height: 300,
      chart: barGroups.isEmpty
          ? Center(
              child: Text(
                'No trend data available',
                style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
              ),
            )
          : BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: (dailyKgs.values.fold<double>(0, (a, b) => a > b ? a : b)) * 1.2,
                barTouchData: BarTouchData(
                  enabled: true,
                  touchTooltipData: BarTouchTooltipData(
                    tooltipRoundedRadius: 8,
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final key = groupIndex < recentKeys.length
                          ? recentKeys[groupIndex]
                          : '';
                      return BarTooltipItem(
                        '$key\n${rod.toY.toStringAsFixed(1)} kg',
                        GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= recentKeys.length) {
                          return const SizedBox.shrink();
                        }
                        final label = recentKeys[idx];
                        // Show short label
                        final short = label.length > 5
                            ? label.substring(0, 5)
                            : label;
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            short,
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              color: const Color(0xFF9CA3AF),
                            ),
                          ),
                        );
                      },
                      reservedSize: 28,
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (value, meta) {
                        return Text(
                          value.toInt().toString(),
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            color: const Color(0xFF9CA3AF),
                          ),
                        );
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: null,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: const Color(0xFFF3F4F6),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                barGroups: barGroups,
              ),
            ),
    );
  }

  Widget _buildStockDonutChart() {
    final d = _dashboardData ?? {};
    final netStock = d['netStock'] ?? {};
    final rows = List<dynamic>.from(netStock is Map ? (netStock['rows'] ?? []) : []);

    // Aggregate stock by grade
    final Map<String, double> gradeStock = {};
    for (final row in rows) {
      if (row is! Map) continue;
      final grade = (row['grade'] ?? row['Grade'] ?? 'Unknown').toString();
      final qty = _parseNum(row['total'] ?? row['Net'] ?? row['qty'] ?? 0).toDouble();
      gradeStock[grade] = (gradeStock[grade] ?? 0) + qty;
    }

    final colors = [
      const Color(0xFF3B82F6),
      const Color(0xFF10B981),
      const Color(0xFFF59E0B),
      const Color(0xFFEF4444),
      const Color(0xFF8B5CF6),
      const Color(0xFFEC4899),
      const Color(0xFF14B8A6),
      const Color(0xFFF97316),
    ];

    final entries = gradeStock.entries.toList();
    final sections = <PieChartSectionData>[];
    for (int i = 0; i < entries.length; i++) {
      sections.add(
        PieChartSectionData(
          color: colors[i % colors.length],
          value: entries[i].value,
          title: entries[i].value.toStringAsFixed(0),
          titleStyle: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
          radius: 60,
        ),
      );
    }

    return WebChartCard(
      title: 'Stock Distribution',
      subtitle: 'By grade',
      height: 300,
      chart: sections.isEmpty
          ? Center(
              child: Text(
                'No stock data available',
                style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
              ),
            )
          : Row(
              children: [
                Expanded(
                  flex: 3,
                  child: PieChart(
                    PieChartData(
                      sections: sections,
                      centerSpaceRadius: 40,
                      sectionsSpace: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: entries.asMap().entries.map((e) {
                        final idx = e.key;
                        final entry = e.value;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: colors[idx % colors.length],
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  entry.key,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    color: const Color(0xFF6B7280),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '${entry.value.toStringAsFixed(0)} kg',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF374151),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tables Row: Recent Orders + Top Clients
  // ---------------------------------------------------------------------------

  Widget _buildTablesRow() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _buildRecentOrdersTable()),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: _buildTopClientsLeaderboard()),
            ],
          );
        }
        return Column(
          children: [
            _buildRecentOrdersTable(),
            const SizedBox(height: 16),
            _buildTopClientsLeaderboard(),
          ],
        );
      },
    );
  }

  Widget _buildRecentOrdersTable() {
    // Combine pending orders and today cart for recent orders
    final List<Map<String, dynamic>> recent = [];

    for (final o in _pendingOrders) {
      if (o is Map) {
        recent.add(Map<String, dynamic>.from(o));
      }
    }
    for (final c in _todayCart) {
      if (c is Map) {
        recent.add(Map<String, dynamic>.from(c));
      }
    }

    // Sort by date descending and take 10
    recent.sort((a, b) {
      final aDate = (a['orderDate'] ?? a['packedDate'] ?? '').toString();
      final bDate = (b['orderDate'] ?? b['packedDate'] ?? '').toString();
      return bDate.compareTo(aDate);
    });
    final display = recent.take(10).toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text(
                  'Recent Orders',
                  style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => Navigator.pushNamed(context, '/view_orders'),
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: Text(
                    'View All',
                    style: GoogleFonts.inter(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (display.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'No recent orders found',
                  style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
                ),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(const Color(0xFFF9FAFB)),
                headingTextStyle: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF6B7280),
                ),
                dataTextStyle: GoogleFonts.inter(
                  fontSize: 13,
                  color: const Color(0xFF374151),
                ),
                columnSpacing: 24,
                columns: const [
                  DataColumn(label: Text('Date')),
                  DataColumn(label: Text('Client')),
                  DataColumn(label: Text('Grade')),
                  DataColumn(label: Text('Qty'), numeric: true),
                  DataColumn(label: Text('Status')),
                ],
                rows: display.map((o) {
                  final date = (o['orderDate'] ?? o['packedDate'] ?? '-').toString();
                  final client = (o['client'] ?? o['clientName'] ?? '-').toString();
                  final grade = (o['grade'] ?? o['gradeName'] ?? '-').toString();
                  final qty = _parseNum(o['kgs'] ?? o['qty'] ?? 0);
                  final status = (o['status'] ?? (o.containsKey('packedDate') ? 'Packed' : 'Pending')).toString();

                  return DataRow(
                    cells: [
                      DataCell(Text(date)),
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 140),
                          child: Text(client, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      DataCell(Text(grade)),
                      DataCell(Text('${qty.toStringAsFixed(1)} kg')),
                      DataCell(_buildStatusBadge(status)),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color bg;
    Color fg;
    final s = status.toLowerCase();
    if (s == 'packed' || s == 'done' || s == 'confirmed') {
      bg = const Color(0xFF10B981).withOpacity(0.1);
      fg = const Color(0xFF10B981);
    } else if (s == 'pending') {
      bg = const Color(0xFFF59E0B).withOpacity(0.1);
      fg = const Color(0xFFF59E0B);
    } else if (s == 'cancelled') {
      bg = const Color(0xFFEF4444).withOpacity(0.1);
      fg = const Color(0xFFEF4444);
    } else {
      bg = const Color(0xFF6B7280).withOpacity(0.1);
      fg = const Color(0xFF6B7280);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  Widget _buildTopClientsLeaderboard() {
    final d = _dashboardData ?? {};
    final leaderboard = List<dynamic>.from(d['clientLeaderboard'] ?? []);
    final top = leaderboard.take(8).toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Top Clients',
              style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          if (top.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'No client data yet',
                  style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
                ),
              ),
            )
          else
            ...top.asMap().entries.map((entry) {
              final i = entry.key;
              final c = entry.value is Map ? entry.value : <String, dynamic>{};
              final clientName = (c['client'] ?? '').toString();
              final pendingValue = _parseNum(c['pendingValue']);
              final isTopThree = i < 3;
              final medals = [
                Icons.emoji_events_rounded,
                Icons.workspace_premium_rounded,
                Icons.military_tech_rounded,
              ];
              final medalColors = [
                const Color(0xFFFFD700),
                const Color(0xFFC0C0C0),
                const Color(0xFFCD7F32),
              ];

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: const Color(0xFFF3F4F6),
                      width: i < top.length - 1 ? 1 : 0,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    if (isTopThree)
                      Icon(medals[i], size: 20, color: medalColors[i])
                    else
                      SizedBox(
                        width: 20,
                        child: Text(
                          '${i + 1}',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF9CA3AF),
                          ),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        clientName,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: isTopThree ? FontWeight.w600 : FontWeight.w500,
                          color: const Color(0xFF374151),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _fmtCurrency(pendingValue),
                      style: GoogleFonts.manrope(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF5D6E7E),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Quick Actions
  // ---------------------------------------------------------------------------

  Widget _buildQuickActions() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick Actions',
            style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _buildActionButton(
                'New Order',
                Icons.add_shopping_cart_rounded,
                const Color(0xFF3B82F6),
                () => Navigator.pushNamed(context, '/new_order'),
              ),
              _buildActionButton(
                'View Orders',
                Icons.list_alt_rounded,
                const Color(0xFF10B981),
                () => Navigator.pushNamed(context, '/view_orders'),
              ),
              _buildActionButton(
                'Daily Cart',
                Icons.shopping_cart_rounded,
                const Color(0xFFF59E0B),
                () => Navigator.pushNamed(context, '/daily_cart'),
              ),
              _buildActionButton(
                'Sales Summary',
                Icons.bar_chart_rounded,
                const Color(0xFF8B5CF6),
                () => Navigator.pushNamed(context, '/sales_summary'),
              ),
              _buildActionButton(
                'Stock Inbound',
                Icons.inventory_2_rounded,
                const Color(0xFFEC4899),
                () => Navigator.pushNamed(context, '/scan_stock'),
              ),
              _buildActionButton(
                'Reports',
                Icons.analytics_rounded,
                const Color(0xFF5D6E7E),
                () => Navigator.pushNamed(context, '/reports'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Loading Shimmer
  // ---------------------------------------------------------------------------

  Widget _buildShimmer() {
    return Container(
      color: const Color(0xFFF8F9FA),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header shimmer
            _shimmerBox(280, 32),
            const SizedBox(height: 8),
            _shimmerBox(180, 16),
            const SizedBox(height: 24),
            // Metric cards shimmer
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: List.generate(5, (_) => _shimmerBox(220, 120)),
            ),
            const SizedBox(height: 24),
            // Charts shimmer
            Row(
              children: [
                Expanded(child: _shimmerBox(double.infinity, 300)),
                const SizedBox(width: 16),
                Expanded(child: _shimmerBox(double.infinity, 300)),
              ],
            ),
            const SizedBox(height: 24),
            // Tables shimmer
            Row(
              children: [
                Expanded(flex: 3, child: _shimmerBox(double.infinity, 350)),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: _shimmerBox(double.infinity, 350)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _shimmerBox(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: const _ShimmerEffect(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Error State
  // ---------------------------------------------------------------------------

  Widget _buildError() {
    return Container(
      color: const Color(0xFFF8F9FA),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline_rounded, size: 48, color: const Color(0xFFEF4444).withOpacity(0.6)),
            const SizedBox(height: 16),
            Text(
              _error ?? 'Something went wrong',
              style: GoogleFonts.inter(fontSize: 15, color: const Color(0xFF6B7280)),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadDashboard,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5D6E7E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shimmer Animation Widget
// ---------------------------------------------------------------------------

class _ShimmerEffect extends StatefulWidget {
  const _ShimmerEffect();

  @override
  State<_ShimmerEffect> createState() => _ShimmerEffectState();
}

class _ShimmerEffectState extends State<_ShimmerEffect>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _animation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return shimmer.AnimatedBuilder(
      listenable: _animation,
      builder: (context, child) {
        final v = _animation.value.clamp(0.0, 1.0);
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [
                Color(0xFFF3F4F6),
                Color(0xFFE5E7EB),
                Color(0xFFF5F5F5),
                Color(0xFFE5E7EB),
                Color(0xFFF3F4F6),
              ],
              stops: [
                0.0,
                (v - 0.3).clamp(0.0, 1.0),
                v,
                (v + 0.3).clamp(0.0, 1.0),
                1.0,
              ],
            ),
          ),
        );
      },
    );
  }
}
