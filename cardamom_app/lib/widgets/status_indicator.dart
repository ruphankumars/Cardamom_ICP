import 'package:flutter/material.dart';

/// Status level for color-coded health indicators
enum StatusLevel {
  healthy,   // 🟢 Green - positive values, good state
  warning,   // 🟡 Yellow - low values, needs attention
  critical,  // 🔴 Red - negative values, requires action
}

/// A color-coded status indicator dot with optional pulse animation
class StatusIndicator extends StatefulWidget {
  final StatusLevel level;
  final double size;
  final bool animated;
  final String? tooltip;

  const StatusIndicator({
    super.key,
    required this.level,
    this.size = 12.0,
    this.animated = true,
    this.tooltip,
  });

  /// Factory constructor to determine status from a numeric value
  factory StatusIndicator.fromValue(
    num value, {
    num warningThreshold = 100,
    num criticalThreshold = 0,
    double size = 12.0,
    bool animated = true,
    String? tooltip,
  }) {
    StatusLevel level;
    if (value < criticalThreshold) {
      level = StatusLevel.critical;
    } else if (value < warningThreshold) {
      level = StatusLevel.warning;
    } else {
      level = StatusLevel.healthy;
    }
    return StatusIndicator(
      level: level,
      size: size,
      animated: animated,
      tooltip: tooltip,
    );
  }

  @override
  State<StatusIndicator> createState() => _StatusIndicatorState();
}

class _StatusIndicatorState extends State<StatusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    // Only animate critical status
    if (widget.animated && widget.level == StatusLevel.critical) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(StatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.level != oldWidget.level) {
      if (widget.animated && widget.level == StatusLevel.critical) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.reset();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color get _color {
    switch (widget.level) {
      case StatusLevel.healthy:
        return const Color(0xFF27AE60); // Green
      case StatusLevel.warning:
        return const Color(0xFFF39C12); // Yellow/Orange
      case StatusLevel.critical:
        return const Color(0xFFE74C3C); // Red
    }
  }

  String get _emoji {
    switch (widget.level) {
      case StatusLevel.healthy:
        return '🟢';
      case StatusLevel.warning:
        return '🟡';
      case StatusLevel.critical:
        return '🔴';
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget dot = AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: widget.level == StatusLevel.critical ? _scaleAnimation.value : 1.0,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _color,
              boxShadow: [
                BoxShadow(
                  color: _color.withOpacity(0.4),
                  blurRadius: widget.size * 0.5,
                  spreadRadius: widget.level == StatusLevel.critical ? 2 : 0,
                ),
              ],
            ),
          ),
        );
      },
    );

    if (widget.tooltip != null) {
      return Tooltip(
        message: widget.tooltip!,
        child: dot,
      );
    }

    return dot;
  }
}

/// A row showing a label with a status indicator
class StatusRow extends StatelessWidget {
  final String label;
  final num value;
  final String? valueText;
  final num warningThreshold;
  final num criticalThreshold;

  const StatusRow({
    super.key,
    required this.label,
    required this.value,
    this.valueText,
    this.warningThreshold = 100,
    this.criticalThreshold = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusIndicator.fromValue(
          value,
          warningThreshold: warningThreshold,
          criticalThreshold: criticalThreshold,
          size: 10,
        ),
        const SizedBox(width: 6),
        Text(
          valueText ?? value.toString(),
          style: TextStyle(
            color: Colors.white.withOpacity(0.9),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
