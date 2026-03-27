import 'package:flutter/material.dart';

class WebLoadingShimmer extends StatefulWidget {
  final int rowCount;
  final double rowHeight;
  final double rowSpacing;
  final double borderRadius;
  final EdgeInsets padding;

  const WebLoadingShimmer({
    super.key,
    this.rowCount = 5,
    this.rowHeight = 20,
    this.rowSpacing = 16,
    this.borderRadius = 8,
    this.padding = const EdgeInsets.all(24),
  });

  @override
  State<WebLoadingShimmer> createState() => _WebLoadingShimmerState();
}

class _WebLoadingShimmerState extends State<WebLoadingShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _animation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: AnimatedBuilder(
        listenable: _animation,
        builder: (context, child) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: List.generate(widget.rowCount, (index) {
              final widthFactor = _getWidthFactor(index);
              return Padding(
                padding: EdgeInsets.only(
                  bottom: index < widget.rowCount - 1 ? widget.rowSpacing : 0,
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: widthFactor,
                  child: Container(
                    height: widget.rowHeight,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(widget.borderRadius),
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: const [
                          Color(0xFFEEEEEE),
                          Color(0xFFE0E0E0),
                          Color(0xFFF5F5F5),
                          Color(0xFFE0E0E0),
                          Color(0xFFEEEEEE),
                        ],
                        stops: [
                          0.0,
                          _clamp(_animation.value - 0.3),
                          _clamp(_animation.value),
                          _clamp(_animation.value + 0.3),
                          1.0,
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  double _getWidthFactor(int index) {
    const widths = [1.0, 0.85, 0.92, 0.75, 0.88, 0.7, 0.95, 0.8, 0.65, 0.9];
    return widths[index % widths.length];
  }

  double _clamp(double value) {
    return value.clamp(0.0, 1.0);
  }
}

class AnimatedBuilder extends AnimatedWidget {
  final Widget Function(BuildContext context, Widget? child) builder;
  final Widget? child;

  const AnimatedBuilder({
    super.key,
    required super.listenable,
    required this.builder,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return builder(context, child);
  }
}
