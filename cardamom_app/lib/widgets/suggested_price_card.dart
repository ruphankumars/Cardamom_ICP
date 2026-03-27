import 'package:flutter/material.dart';
import '../services/analytics_service.dart';

/// Suggested Price Card - Phase 4.2
/// Helps admins decide on a price for a specific grade
class SuggestedPriceCard extends StatelessWidget {
  final SuggestedPrice suggestion;
  final VoidCallback? onApply;

  const SuggestedPriceCard({
    super.key,
    required this.suggestion,
    this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final bool isIncrease = suggestion.adjustmentPercent > 0;
    final bool isDecrease = suggestion.adjustmentPercent < 0;
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Pricing Intelligence',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF64748B),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (isIncrease ? const Color(0xFF10B981) : (isDecrease ? const Color(0xFFEF4444) : const Color(0xFF64748B))).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${suggestion.adjustmentPercent > 0 ? '+' : ''}${suggestion.adjustmentPercent}%',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isIncrease ? const Color(0xFF10B981) : (isDecrease ? const Color(0xFFEF4444) : const Color(0xFF64748B)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '₹${suggestion.suggestedPrice}',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const Text(
                    'Suggested per kg',
                    style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                  ),
                ],
              ),
              if (onApply != null)
                ElevatedButton(
                  onPressed: onApply,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5D6E7E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  child: const Text('Apply', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          ...suggestion.reasons.map((reason) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 12, color: Color(0xFF64748B)),
                const SizedBox(width: 8),
                Text(
                  reason,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF4A5568)),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}
