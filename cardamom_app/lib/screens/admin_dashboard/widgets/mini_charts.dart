/// Custom painters for mini chart visualizations used across the admin dashboard.
///
/// Contains line chart, trend line, and progress ring painters extracted from
/// the monolithic admin_dashboard.dart.
import 'package:flutter/material.dart';

/// Mini line chart painter for sales card - draws a smooth wave pattern with gradient fill.
class MiniLineChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    // Create a smooth wave pattern
    final points = [0.3, 0.5, 0.4, 0.7, 0.6, 0.8, 0.5];
    for (var i = 0; i < points.length; i++) {
      final x = i * size.width / (points.length - 1);
      final y = size.height - (points[i] * size.height * 0.8) - size.height * 0.1;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        // Create smooth bezier curves
        final prevX = (i - 1) * size.width / (points.length - 1);
        final prevY = size.height - (points[i - 1] * size.height * 0.8) - size.height * 0.1;
        final ctrlX = (prevX + x) / 2;
        path.cubicTo(ctrlX, prevY, ctrlX, y, x, y);
      }
    }
    canvas.drawPath(path, paint);

    // Draw gradient fill under the line
    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white.withOpacity(0.3), Colors.white.withOpacity(0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Soft trend painter for subtle trend line visualizations.
class SoftTrendPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF5D6E7E).withOpacity(0.25)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final points = [0.4, 0.6, 0.5, 0.75, 0.55, 0.85, 0.6];
    for (var i = 0; i < points.length; i++) {
      final x = i * size.width / (points.length - 1);
      final y = size.height - (points[i] * size.height * 0.7) - size.height * 0.15;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        final prevX = (i - 1) * size.width / (points.length - 1);
        final prevY = size.height - (points[i - 1] * size.height * 0.7) - size.height * 0.15;
        final ctrlX = (prevX + x) / 2;
        path.cubicTo(ctrlX, prevY, ctrlX, y, x, y);
      }
    }
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Header progress painter for the multi-segment progress ring in the frosted header.
///
/// Draws three arc segments representing revenue, stock, and pending progress.
class HeaderProgressPainter extends CustomPainter {
  final double revenueProgress;
  final double stockProgress;
  final double pendingProgress;

  HeaderProgressPainter({
    required this.revenueProgress,
    required this.stockProgress,
    required this.pendingProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    const strokeWidth = 3.5;

    final basePaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    canvas.drawCircle(center, radius, basePaint);

    final rect = Rect.fromCircle(center: center, radius: radius);

    // Revenue Arcs (White)
    final revPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -1.5, (2.0 * revenueProgress).clamp(0.01, 2.0), false, revPaint);

    // Stock Segment (Greenish)
    final stockPaint = Paint()
      ..color = const Color(0xFF10B981)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0.8, (1.5 * stockProgress).clamp(0.01, 1.5), false, stockPaint);

    // Pending Segment (Amber)
    final pendingPaint = Paint()
      ..color = const Color(0xFFF59E0B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 2.5, (1.2 * pendingProgress).clamp(0.01, 1.2), false, pendingPaint);
  }

  @override
  bool shouldRepaint(covariant HeaderProgressPainter oldDelegate) {
    return oldDelegate.revenueProgress != revenueProgress ||
           oldDelegate.stockProgress != stockProgress ||
           oldDelegate.pendingProgress != pendingProgress;
  }
}
