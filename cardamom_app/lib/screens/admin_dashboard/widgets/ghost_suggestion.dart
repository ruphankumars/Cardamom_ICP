/// Ghost suggestion widget for the admin dashboard.
///
/// Neumorphic-styled suggestion card that appears when a grade is out of stock,
/// offering an alternative grade recommendation.
import 'package:flutter/material.dart';

/// A neumorphic card showing an out-of-stock suggestion with grade substitution.
class GhostSuggestion extends StatelessWidget {
  final String grade;
  final String suggestion;

  const GhostSuggestion({
    super.key,
    required this.grade,
    required this.suggestion,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF5D6E7E).withOpacity(0.15)),
        boxShadow: [
          BoxShadow(color: const Color(0xFFCBD5E1), blurRadius: 10, offset: const Offset(4, 4)),
          const BoxShadow(color: Colors.white, blurRadius: 10, offset: Offset(-4, -4)),
        ],
      ),
      child: Row(children: [
        const Text('\u{1F47B}', style: TextStyle(fontSize: 24)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Out of $grade', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF4A5568))),
          Text('Suggest switching to $suggestion?', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF5D6E7E), borderRadius: BorderRadius.circular(10)),
          child: const Text('Update', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
        ),
      ]),
    );
  }
}
