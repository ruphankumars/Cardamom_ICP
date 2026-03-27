import 'package:flutter/material.dart';

/// Skeleton loading widget with shimmer animation effect
class SkeletonLoader extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;
  final bool isCircle;

  const SkeletonLoader({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.borderRadius = 8.0,
    this.isCircle = false,
  });

  /// Create a circular skeleton (for avatars)
  const SkeletonLoader.circle({
    super.key,
    required double size,
  })  : width = size,
        height = size,
        borderRadius = 0,
        isCircle = true;

  /// Create a text line skeleton
  const SkeletonLoader.line({
    super.key,
    this.width = double.infinity,
    double height = 16,
  })  : height = height,
        borderRadius = 4.0,
        isCircle = false;

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();

    _animation = Tween<double>(begin: -2, end: 2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            shape: widget.isCircle ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: widget.isCircle
                ? null
                : BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              begin: Alignment(_animation.value - 1, 0),
              end: Alignment(_animation.value + 1, 0),
              colors: const [
                Color(0xFFD1D1CB), // titaniumMid
                Color(0xFFE3E3DE), // titaniumLight
                Color(0xFFD1D1CB), // titaniumMid
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// A skeleton card that mimics the stat card layout
class SkeletonCard extends StatelessWidget {
  final double height;

  const SkeletonCard({
    super.key,
    this.height = 120,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title line
          SkeletonLoader(
            width: 80,
            height: 12,
            borderRadius: 4,
          ),
          const SizedBox(height: 12),
          // Main value
          SkeletonLoader(
            width: 120,
            height: 32,
            borderRadius: 6,
          ),
          const Spacer(),
          // Subtitle
          SkeletonLoader(
            width: 100,
            height: 10,
            borderRadius: 4,
          ),
        ],
      ),
    );
  }
}

/// Skeleton for a list item (order/transaction row)
class SkeletonListItem extends StatelessWidget {
  const SkeletonListItem({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Avatar
          const SkeletonLoader.circle(size: 40),
          const SizedBox(width: 12),
          // Content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonLoader(
                  width: 140,
                  height: 14,
                  borderRadius: 4,
                ),
                const SizedBox(height: 6),
                SkeletonLoader(
                  width: 80,
                  height: 10,
                  borderRadius: 4,
                ),
              ],
            ),
          ),
          // Amount
          SkeletonLoader(
            width: 60,
            height: 16,
            borderRadius: 4,
          ),
        ],
      ),
    );
  }
}

/// A skeleton layout for the dashboard
class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Header skeleton
          SkeletonLoader(
            width: double.infinity,
            height: 80,
            borderRadius: 16,
          ),
          const SizedBox(height: 20),
          // Revenue card
          const SkeletonCard(height: 140),
          const SizedBox(height: 16),
          // Stat duo row
          Row(
            children: [
              Expanded(child: SkeletonCard(height: 100)),
              const SizedBox(width: 12),
              Expanded(child: SkeletonCard(height: 100)),
            ],
          ),
          const SizedBox(height: 16),
          // Calendar strip
          SkeletonLoader(
            width: double.infinity,
            height: 80,
            borderRadius: 16,
          ),
          const SizedBox(height: 16),
          // Transaction list
          ...List.generate(3, (_) => const SkeletonListItem()),
        ],
      ),
    );
  }
}
