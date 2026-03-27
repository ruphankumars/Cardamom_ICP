import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A donut/ring progress chart with gradient support
class DonutChart extends StatefulWidget {
  final double progress; // 0.0 to 1.0
  final String centerText;
  final String? subtitle;
  final double size;
  final double strokeWidth;
  final Color? primaryColor;
  final Color? secondaryColor;
  final Color? backgroundColor;
  final bool animated;

  const DonutChart({
    super.key,
    required this.progress,
    required this.centerText,
    this.subtitle,
    this.size = 120,
    this.strokeWidth = 12,
    this.primaryColor,
    this.secondaryColor,
    this.backgroundColor,
    this.animated = true,
  });

  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    _animation = Tween<double>(begin: 0.0, end: widget.progress).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    if (widget.animated) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(DonutChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      _animation = Tween<double>(
        begin: _animation.value,
        end: widget.progress,
      ).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
      );
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = widget.primaryColor ?? const Color(0xFF5D6E7E);
    final secondary = widget.secondaryColor ?? const Color(0xFF4A5568);
    final bg = widget.backgroundColor ?? Colors.white.withOpacity(0.1);

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _animation,
            builder: (context, child) {
              return CustomPaint(
                size: Size(widget.size, widget.size),
                painter: _DonutPainter(
                  progress: widget.animated ? _animation.value : widget.progress,
                  strokeWidth: widget.strokeWidth,
                  primaryColor: primary,
                  secondaryColor: secondary,
                  backgroundColor: bg,
                ),
              );
            },
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.centerText,
                style: TextStyle(
                  fontSize: widget.size * 0.18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              if (widget.subtitle != null)
                Text(
                  widget.subtitle!,
                  style: TextStyle(
                    fontSize: widget.size * 0.09,
                    color: Colors.white.withOpacity(0.7),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final Color primaryColor;
  final Color secondaryColor;
  final Color backgroundColor;

  _DonutPainter({
    required this.progress,
    required this.strokeWidth,
    required this.primaryColor,
    required this.secondaryColor,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Background arc
    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    // Progress arc with gradient
    final rect = Rect.fromCircle(center: center, radius: radius);
    final gradient = SweepGradient(
      startAngle: -math.pi / 2,
      endAngle: 3 * math.pi / 2,
      colors: [primaryColor, secondaryColor, primaryColor],
      stops: const [0.0, 0.5, 1.0],
    );

    final progressPaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final sweepAngle = 2 * math.pi * progress;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweepAngle,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

/// A mini donut for compact displays
class MiniDonut extends StatelessWidget {
  final double progress;
  final Color color;
  final double size;

  const MiniDonut({
    super.key,
    required this.progress,
    required this.color,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DonutPainter(
          progress: progress.clamp(0.0, 1.0),
          strokeWidth: 3,
          primaryColor: color,
          secondaryColor: color.withOpacity(0.7),
          backgroundColor: color.withOpacity(0.15),
        ),
      ),
    );
  }
}
