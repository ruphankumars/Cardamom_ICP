/// Glass carousel widget for the admin dashboard.
///
/// A horizontally-scrolling PageView of machined-style insight cards
/// showing packed today stats, smart reorder alerts, demand forecasts,
/// and flow rate metrics.
import 'package:flutter/material.dart';

/// Swipeable insights carousel with machined titanium-styled cards.
class GlassCarousel extends StatelessWidget {
  final dynamic packedKgs;
  final dynamic packedCount;
  final Map<String, dynamic>? dashboardData;
  final VoidCallback onShowPackedPopup;
  final VoidCallback onShowStockPopup;

  const GlassCarousel({
    super.key,
    required this.packedKgs,
    required this.packedCount,
    this.dashboardData,
    required this.onShowPackedPopup,
    required this.onShowStockPopup,
  });

  double _getHoursElapsed() {
    final now = DateTime.now();
    final hour = now.hour;
    if (hour < 8) return 0.5;
    if (hour >= 20) return 12;
    return (hour - 8) + (now.minute / 60);
  }

  @override
  Widget build(BuildContext context) {
    final kgs = packedKgs is num ? packedKgs : (num.tryParse('$packedKgs') ?? 0);
    final count = packedCount is num ? packedCount : (num.tryParse('$packedCount') ?? 0);

    final pendingQty = dashboardData?['pendingQty'] ?? 0;
    final totalStock = dashboardData?['totalStock'] ?? 0;
    final pendingNum = pendingQty is num ? pendingQty : (num.tryParse('$pendingQty') ?? 0);
    final stockNum = totalStock is num ? totalStock : (num.tryParse('$totalStock') ?? 0);
    final needsReorder = pendingNum > (stockNum * 0.8) && pendingNum > 0;

    final hours = _getHoursElapsed();
    final ordersPerHour = count / hours;
    final forecastedOrders = (ordersPerHour * 2).ceil();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Icon(Icons.lightbulb_outline, size: 16, color: Colors.amber[600]),
          const SizedBox(width: 6),
          const Text('INSIGHTS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF5D6E7E), letterSpacing: 2)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFD1D1CB),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('0${needsReorder ? 4 : 3}', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF5D6E7E))),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 140,
        child: PageView(
          controller: PageController(viewportFraction: 0.72, initialPage: 0),
          padEnds: false,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _buildMachinedCard('Packed Today', '${kgs.toStringAsFixed(0)} kg', 'Across $count orders', Icons.inventory_2, true, onShowPackedPopup),
            ),
            if (needsReorder)
              _buildMachinedCard('Smart Reorder', 'Alert', 'Pending > 80% of Stock', Icons.warning_amber_rounded, false, onShowStockPopup),
            _buildMachinedCard('Next 2 Hours', '~$forecastedOrders Orders', 'Predicted demand', Icons.schedule, true, onShowPackedPopup),
            _buildMachinedCard('Flow Rate', '${(kgs / hours).toStringAsFixed(1)} kg/hr', 'Current throughput', Icons.speed, true, onShowStockPopup),
          ],
        ),
      ),
    ]);
  }

  Widget _buildMachinedCard(String title, String value, String subtitle, IconData icon, bool isBlue, VoidCallback onTap) {
    final gradientColors = isBlue
        ? [const Color(0xFF4A5568), const Color(0xFF2D3748)]
        : [const Color(0xFFCD7F32), const Color(0xFF8B4513)];

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradientColors,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.white.withOpacity(0.1), blurRadius: 0, offset: const Offset(1, 1)),
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 15, offset: const Offset(0, 10)),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, mainAxisSize: MainAxisSize.max, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Icon(icon, color: Colors.white.withOpacity(0.8), size: 24),
            Container(width: 24, height: 3, decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(2))),
          ]),
          const Spacer(),
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.6))),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Text(value, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.3)),
          ),
        ]),
      ),
    );
  }
}
