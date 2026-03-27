import 'package:flutter/material.dart';
import '../services/analytics_service.dart';

/// Demand Trends Visualization Widget - Phase 4.1
class DemandTrendsCard extends StatelessWidget {
  final List<DemandTrend> trends;
  final VoidCallback? onRefresh;

  const DemandTrendsCard({
    super.key,
    required this.trends,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (trends.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF5D6E7E).withOpacity(0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5D6E7E).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.trending_up_rounded, color: Color(0xFF5D6E7E), size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Demand Trends',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A5568)),
                  ),
                ],
              ),
              if (onRefresh != null)
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: Color(0xFF5D6E7E)),
                  onPressed: onRefresh,
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '90-day volume analysis & projected needs',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 16),
          ...trends.take(4).map((trend) => _buildTrendRow(trend)),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => Navigator.pushNamed(context, '/sales_summary'),
              child: const Text('View Full Analytics', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrendRow(DemandTrend trend) {
    final bool isRising = trend.momentum == 'rising';
    final bool isFalling = trend.momentum == 'falling';
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trend.grade,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF4A5568)),
                ),
                Text(
                  'Avg ${trend.avgWeeklyVolume} kgs/week',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isRising ? Icons.north_east_rounded : (isFalling ? Icons.south_east_rounded : Icons.trending_flat_rounded),
                      size: 14,
                      color: isRising ? const Color(0xFF10B981) : (isFalling ? const Color(0xFFEF4444) : const Color(0xFF64748B)),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${trend.percentageChange > 0 ? '+' : ''}${trend.percentageChange}%',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isRising ? const Color(0xFF10B981) : (isFalling ? const Color(0xFFEF4444) : const Color(0xFF64748B)),
                      ),
                    ),
                  ],
                ),
                Text(
                  'Next: ~${trend.projectedNextWeek}kg',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF4A5568)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
