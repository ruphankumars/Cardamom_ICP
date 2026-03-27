import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import '../services/analytics_service.dart';

/// Stock Forecast Card - Matte Titanium Style
/// Displays stock depletion forecasts with urgency indicators
class StockForecastCard extends StatelessWidget {
  final List<StockForecast> forecasts;
  final VoidCallback? onTap;
  final VoidCallback? onRefresh;

  const StockForecastCard({
    super.key,
    required this.forecasts,
    this.onTap,
    this.onRefresh,
  });

  Color _getUrgencyColor(String urgency) {
    switch (urgency) {
      case 'critical':
        return const Color(0xFFEF4444);
      case 'warning':
        return const Color(0xFFF59E0B);
      case 'healthy':
        return const Color(0xFF10B981);
      case 'slow':
        return const Color(0xFF5D6E7E); // Steel Blue
      default:
        return const Color(0xFF5D6E7E);
    }
  }

  IconData _getUrgencyIcon(String urgency) {
    switch (urgency) {
      case 'critical':
        return Icons.warning_rounded;
      case 'warning':
        return Icons.access_time_rounded;
      case 'healthy':
        return Icons.check_circle_rounded;
      case 'slow':
        return Icons.hourglass_empty_rounded;
      default:
        return Icons.info_rounded;
    }
  }

  String _getUrgencyLabel(String urgency, int? days) {
    switch (urgency) {
      case 'critical':
        return '${days ?? 0}d left';
      case 'warning':
        return '${days ?? 0}d left';
      case 'healthy':
        return '${days ?? 0}d+';
      case 'slow':
        return 'NO MOVEMENT';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show only critical and warning items, or top 5
    final displayItems = forecasts
        .where((f) => f.urgency == 'critical' || f.urgency == 'warning')
        .take(5)
        .toList();

    if (displayItems.isEmpty && forecasts.isNotEmpty) {
      // All healthy - show top 3 by stock level
      displayItems.addAll(forecasts.take(3));
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1), // Matte Glass - 10%
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                boxShadow: [
                  // Bevel shadow
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                    offset: const Offset(2, 2),
                  ),
                  const BoxShadow(
                    color: Colors.white70,
                    blurRadius: 4,
                    offset: Offset(-2, -2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF5D6E7E).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.trending_down_rounded,
                    color: Color(0xFF5D6E7E),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Stock Forecast',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF4A5568),
                    ),
                  ),
                ),
                if (onRefresh != null)
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onRefresh!();
                    },
                    child: Icon(
                      Icons.refresh_rounded,
                      color: const Color(0xFF64748B),
                      size: 20,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // Forecast Items
            if (displayItems.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'No forecasts available',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 13,
                    ),
                  ),
                ),
              )
            else
              ...displayItems.map((forecast) => _buildForecastItem(forecast)),
            // Summary row
            if (forecasts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildSummaryChip(
                    '🔴',
                    forecasts.where((f) => f.urgency == 'critical').length,
                  ),
                  const SizedBox(width: 16),
                  _buildSummaryChip(
                    '🟡',
                    forecasts.where((f) => f.urgency == 'warning').length,
                  ),
                  const SizedBox(width: 16),
                  _buildSummaryChip(
                    '🟢',
                    forecasts.where((f) => f.urgency == 'healthy').length,
                  ),
                ],
              ),
            ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForecastItem(StockForecast forecast) {
    final color = _getUrgencyColor(forecast.urgency);
    final icon = _getUrgencyIcon(forecast.urgency);
    final label = _getUrgencyLabel(forecast.urgency, forecast.daysUntilDepletion);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          // Titanium block icon container
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
                const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
              ],
              border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
            ),
            child: Icon(icon, color: const Color(0xFF5D6E7E), size: 22),
          ),
          const SizedBox(width: 16),
          // Grade and stock info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  forecast.grade,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF131416),
                  ),
                ),
                Text(
                  '${forecast.currentStock}kg • ${forecast.dailyRate.toStringAsFixed(1)}kg/day',
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF5D6E7E).withOpacity(0.6),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          // Titanium block badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
              ),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
                const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
              ],
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF5D6E7E).withOpacity(0.7),
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryChip(String emoji, int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 4),
        Text(
          '$count',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Color(0xFF4A5568),
          ),
        ),
      ],
    );
  }
}

/// Compact version for dashboard
class StockForecastMini extends StatelessWidget {
  final List<StockForecast> forecasts;
  final VoidCallback? onTap;

  const StockForecastMini({
    super.key,
    required this.forecasts,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final criticalCount = forecasts.where((f) => f.urgency == 'critical').length;
    final warningCount = forecasts.where((f) => f.urgency == 'warning').length;

    final hasIssues = criticalCount > 0 || warningCount > 0;
    final color = criticalCount > 0
        ? const Color(0xFFEF4444)
        : warningCount > 0
            ? const Color(0xFFF59E0B)
            : const Color(0xFF10B981);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasIssues ? Icons.warning_rounded : Icons.check_circle_rounded,
              color: color,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              hasIssues
                  ? '${criticalCount + warningCount} stock alerts'
                  : 'Stock healthy',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
