/// Intent detection prompt widget for the admin dashboard.
///
/// A gradient card that appears when the user has viewed pending orders
/// multiple times, suggesting they start packing.
import 'package:flutter/material.dart';

/// Prompt card triggered by intent detection (repeated pending order views).
class IntentPrompt extends StatelessWidget {
  final VoidCallback onStartNow;

  const IntentPrompt({
    super.key,
    required this.onStartNow,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF4A5568)]),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(color: const Color(0xFF5D6E7E).withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6)),
        ],
      ),
      child: Row(children: [
        const Text('\u{1F3AF}', style: TextStyle(fontSize: 24)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Ready to pack these?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
          const Text("You've checked pending orders 3 times.", style: TextStyle(color: Colors.white70, fontSize: 11)),
        ])),
        TextButton(
          onPressed: onStartNow,
          style: TextButton.styleFrom(backgroundColor: Colors.white.withOpacity(0.15), foregroundColor: Colors.white),
          child: const Text('Start Now', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }
}
