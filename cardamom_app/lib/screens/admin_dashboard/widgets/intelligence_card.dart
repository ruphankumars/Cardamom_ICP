/// Intelligence card widget for the admin dashboard.
///
/// A titanium-well recessed card displaying AI-powered business insights
/// with recommendation, brand velocity, and lot performance sections.
import 'package:flutter/material.dart';

/// Titanium-recessed card showing anticipatory intelligence insights.
class IntelligenceCard extends StatelessWidget {
  final dynamic hint;

  const IntelligenceCard({super.key, required this.hint});

  @override
  Widget build(BuildContext context) {
    final grade = hint['grade']?.toString() ?? '';
    final qty = hint['qty']?.toString() ?? '';
    const steelBlue = Color(0xFF5D6E7E);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFD1D1CB),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(4, 4)),
          BoxShadow(color: Colors.white.withOpacity(0.4), blurRadius: 8, offset: const Offset(-4, -4)),
        ],
        border: Border.all(color: const Color(0xFFA8A8A1)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFE3E3DE),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(1, 1)),
              ],
            ),
            child: const Icon(Icons.auto_awesome, color: steelBlue, size: 18),
          ),
          const SizedBox(width: 12),
          const Text('INTELLIGENCE', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF131416))),
        ]),
        const SizedBox(height: 20),
        _buildTitaniumInsightRow('\u{1F3AF}', 'RECOMMENDATION', 'Pack $qty kg of $grade for best fulfillment.', const Color(0xFFEF4444)),
        const SizedBox(height: 16),
        Container(height: 1, color: const Color(0xFFA8A8A1).withOpacity(0.5)),
        const SizedBox(height: 16),
        _buildTitaniumInsightRow('\u{1F680}', 'BRAND VELOCITY', 'Emperor is selling 1.5x faster than Royal today.', const Color(0xFF5D6E7E)),
        const SizedBox(height: 16),
        Container(height: 1, color: const Color(0xFFA8A8A1).withOpacity(0.5)),
        const SizedBox(height: 16),
        _buildTitaniumInsightRow('\u{1F4CA}', 'LOT PERFORMANCE', 'Lot 123 has 98% quality consistency score.', const Color(0xFF10B981)),
      ]),
    );
  }

  Widget _buildTitaniumInsightRow(String emoji, String title, String desc, Color iconColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFFE3E3DE),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(1, 1)),
            ],
          ),
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 16))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: const Color(0xFF5D6E7E).withOpacity(0.7), letterSpacing: 0.5)),
            const SizedBox(height: 2),
            Text(desc, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF131416))),
          ]),
        ),
      ],
    );
  }
}
