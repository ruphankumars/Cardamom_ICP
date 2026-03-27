/// Titanium-styled hero card widgets for the admin dashboard.
///
/// Contains both the mobile TitaniumHeroCard (gradient background with stats)
/// and the desktop HeroCard (LiquidGlass glassmorphic card) extracted from
/// the monolithic admin_dashboard.dart.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import '../../../theme/app_theme.dart';

/// Mobile titanium hero card with gradient background and stat grid.
class TitaniumHeroCard extends StatelessWidget {
  final String greeting;
  final num totalStock;
  final num pendingQty;
  final Map<String, dynamic>? dashboardData;
  final Widget Function(String label, String value, String trend, {bool isNegative})? buildHeaderStat;

  const TitaniumHeroCard({
    super.key,
    required this.greeting,
    required this.totalStock,
    required this.pendingQty,
    this.dashboardData,
    this.buildHeaderStat,
  });

  Widget _defaultHeaderStat(String label, String value, String trend, {bool isNegative = false, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: AppTheme.machinedDecoration.copyWith(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.primary, letterSpacing: 1)),
            const SizedBox(height: 4),
            Text(value, style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w900, color: AppTheme.title)),
            Text(trend, style: GoogleFonts.manrope(fontSize: 11, color: isNegative ? Colors.redAccent : const Color(0xFF10B981))),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: AppTheme.titaniumGradient,
      child: Stack(
        children: [
          // Decorative Sheen
          Positioned(
            top: -100, left: -100,
            child: Transform.rotate(
              angle: 0.2,
              child: Container(
                width: 400, height: 400,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.white.withOpacity(0.1), Colors.transparent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'STATUS: HIGH EFFICIENCY',
                  style: GoogleFonts.manrope(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  greeting,
                  style: GoogleFonts.manrope(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.title,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: _defaultHeaderStat('PACKED', '${dashboardData?['todayPackedKgs'] ?? 0}', '+12%', isNegative: false, onTap: () => Navigator.pushNamed(context, '/daily_cart'))),
                    const SizedBox(width: 12),
                    Expanded(child: _defaultHeaderStat('STOCK', '${(totalStock/1000).toStringAsFixed(1)}k', '+5%', isNegative: false, onTap: () => Navigator.pushNamed(context, '/stock_tools'))),
                    const SizedBox(width: 12),
                    Expanded(child: _defaultHeaderStat('PENDING', '${(pendingQty/1000).toStringAsFixed(1)}k', '-2%', isNegative: true, onTap: () => Navigator.pushNamed(context, '/sales_summary'))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Desktop hero card with LiquidGlass glassmorphic styling.
class HeroCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;
  final Color color;
  final double width;
  final String? statusBadge;

  const HeroCard({
    super.key,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.color,
    required this.width,
    this.statusBadge,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final cardPadding = isMobile ? 16.0 : 20.0;
    final valueFontSize = isMobile ? 32.0 : 40.0;
    final titleFontSize = isMobile ? 12.0 : 13.0;
    final subtitleFontSize = isMobile ? 11.0 : 12.0;
    final borderRadius = isMobile ? 24.0 : 32.0;

    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A5568).withOpacity(0.12),
              blurRadius: 44,
              offset: const Offset(0, 16),
              spreadRadius: -4,
            ),
            BoxShadow(
              color: Colors.white.withOpacity(0.15),
              blurRadius: 0,
              offset: const Offset(0, -1),
              spreadRadius: 0,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
              borderRadius: BorderRadius.circular(borderRadius),
            ),
            child: LiquidGlass.withOwnLayer(
              settings: const LiquidGlassSettings(
                blur: 30,
                glassColor: Colors.white10,
                thickness: 10,
              ),
              shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
              child: Padding(
                padding: EdgeInsets.all(cardPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(color: color.withOpacity(0.5), blurRadius: 6, spreadRadius: 1),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(fontSize: titleFontSize, fontWeight: FontWeight.w700, color: const Color(0xFF4A5568)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (statusBadge != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: color.withOpacity(0.2), width: 0.5),
                            ),
                            child: Text(
                              statusBadge!,
                              style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: valueFontSize,
                        fontWeight: FontWeight.w900,
                        color: color,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: subtitleFontSize, color: const Color(0xFF64748B), fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
