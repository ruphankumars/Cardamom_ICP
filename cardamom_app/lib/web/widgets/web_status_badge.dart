import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class WebStatusBadge extends StatelessWidget {
  final String label;
  final Color? color;

  const WebStatusBadge({
    super.key,
    required this.label,
    this.color,
  });

  static Color getStatusColor(String status) {
    switch (status.toLowerCase().trim()) {
      case 'open':
      case 'new':
        return const Color(0xFF3B82F6);
      case 'pending':
      case 'in_progress':
      case 'in progress':
        return const Color(0xFFF59E0B);
      case 'approved':
      case 'confirmed':
      case 'completed':
      case 'success':
        return const Color(0xFF10B981);
      case 'rejected':
      case 'cancelled':
      case 'failed':
      case 'error':
        return const Color(0xFFEF4444);
      case 'draft':
        return const Color(0xFF6366F1);
      case 'sent':
      case 'submitted':
        return const Color(0xFFA855F7);
      case 'converted':
      case 'archived':
      case 'closed':
        return const Color(0xFF6B7280);
      case 'admin_sent':
      case 'admin sent':
        return const Color(0xFFF97316);
      case 'client_sent':
      case 'client sent':
        return const Color(0xFFA855F7);
      case 'client_draft':
      case 'client draft':
        return const Color(0xFFEAB308);
      case 'admin_draft':
      case 'admin draft':
        return const Color(0xFF6366F1);
      case 'billed':
        return const Color(0xFF0891B2);
      case 'delivered':
        return const Color(0xFF059669);
      case 'active':
        return const Color(0xFF22C55E);
      case 'inactive':
      case 'disabled':
        return const Color(0xFF94A3B8);
      default:
        return const Color(0xFF6B7280);
    }
  }

  @override
  Widget build(BuildContext context) {
    final badgeColor = color ?? getStatusColor(label);
    final bgColor = badgeColor.withOpacity(0.1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: badgeColor,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
