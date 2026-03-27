import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/analytics_service.dart';

/// Insight Card - Phase 3.3
/// Displays proactive insights with action buttons
class InsightCard extends StatelessWidget {
  final Insight insight;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  const InsightCard({
    super.key,
    required this.insight,
    this.onAction,
    this.onDismiss,
  });

  List<Color> _getGradientColors(String priority) {
    switch (priority) {
      case 'critical':
        return [const Color(0xFFEF4444), const Color(0xFFDC2626)];
      case 'high':
        return [const Color(0xFF4A5568), const Color(0xFF2D3748)]; // Titanium dark
      case 'medium':
        return [const Color(0xFF4A5568), const Color(0xFF2D3748)]; // Titanium dark
      case 'low':
        return [const Color(0xFF64748B), const Color(0xFF475569)];
      default:
        return [const Color(0xFF5D6E7E), const Color(0xFF4A5568)]; // Steel blue to titanium
    }
  }

  String _getActionLabel(String? action) {
    switch (action) {
      case 'add_to_cart':
        return 'Dispatch Now';
      case 'stock_calculator':
        return 'Check Stock';
      case 'view_orders':
        return 'View Orders';
      case 'view_stock':
        return 'View Stock';
      default:
        return 'View';
    }
  }

  @override
  Widget build(BuildContext context) {
    final gradientColors = _getGradientColors(insight.priority);
    final actionLabel = _getActionLabel(insight.action);

    return Container(
      width: 280,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: gradientColors[0].withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              Text(
                insight.icon,
                style: const TextStyle(fontSize: 24),
              ),
              const Spacer(),
              if (onDismiss != null)
                GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onDismiss!();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Title
          Text(
            insight.title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          // Description
          Text(
            insight.description,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.85),
              height: 1.4,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // Substitutions (if any)
          if (insight.substitutions != null &&
              insight.substitutions!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: insight.substitutions!
                  .take(2)
                  .map((sub) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Try: $sub',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 12),
          // Action button
          if (insight.action != null)
            GestureDetector(
              onTap: () {
                HapticFeedback.mediumImpact();
                onAction?.call();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  actionLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: gradientColors[0],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Horizontally scrollable list of insight cards
class InsightsCarousel extends StatelessWidget {
  final List<Insight> insights;
  final Function(Insight insight)? onInsightAction;
  final VoidCallback? onSeeAll;

  const InsightsCarousel({
    super.key,
    required this.insights,
    this.onInsightAction,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Text(
                    '💡',
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Insights',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5D6E7E).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${insights.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF5D6E7E),
                      ),
                    ),
                  ),
                ],
              ),
              if (onSeeAll != null)
                GestureDetector(
                  onTap: onSeeAll,
                  child: const Text(
                    'See All',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF5D6E7E),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Carousel
        SizedBox(
          height: 195,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: insights.length,
            itemBuilder: (context, index) {
              final insight = insights[index];
              return InsightCard(
                insight: insight,
                onAction: () => onInsightAction?.call(insight),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Client Score Card - Phase 3.2
class ClientScoreCard extends StatelessWidget {
  final ClientScore client;
  final VoidCallback? onTap;

  const ClientScoreCard({
    super.key,
    required this.client,
    this.onTap,
  });

  Color _getChurnColor(String risk) {
    switch (risk) {
      case 'high':
        return const Color(0xFFEF4444);
      case 'medium':
        return const Color(0xFFF59E0B);
      case 'low':
        return const Color(0xFF10B981);
      default:
        return const Color(0xFF64748B);
    }
  }

  @override
  Widget build(BuildContext context) {
    final churnColor = _getChurnColor(client.churnRisk);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            // Velocity Score Circle
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF5D6E7E),
                    const Color(0xFF4A5568),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '${client.velocityScore}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Client Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    client.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${client.orderCount} orders • ₹${(client.totalValue / 100000).toStringAsFixed(1)}L',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
            // Churn Risk Indicator
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: churnColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    client.churnRisk == 'high'
                        ? '⚠️ At risk'
                        : client.daysSinceLastOrder < 999
                            ? '${client.daysSinceLastOrder}d ago'
                            : 'New',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: churnColor,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
