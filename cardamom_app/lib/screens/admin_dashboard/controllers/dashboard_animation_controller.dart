/// Dashboard animation controller for the admin dashboard.
///
/// Manages animation controllers for background blobs, shimmer effects,
/// pulse animations, and notification blink, extracted from
/// _AdminDashboardState to separate animation lifecycle from business logic.
import 'package:flutter/material.dart';

/// ChangeNotifier managing all dashboard animation state.
///
/// This controller must be initialized with a [TickerProvider] (vsync)
/// since it creates multiple [AnimationController]s.
class DashboardAnimationController extends ChangeNotifier {
  late AnimationController bgAnimationController;
  late AnimationController shimmerAnimationController;
  late AnimationController pulseController;
  late AnimationController notificationBlinkController;

  // Scroll controllers for sticky stock headers
  final ScrollController stockHeaderController = ScrollController();
  final ScrollController stockBodyController = ScrollController();

  bool _isInitialized = false;
  bool _isSyncing = false;

  /// Initialize all animation controllers. Must be called with a valid TickerProvider.
  void initialize(TickerProvider vsync) {
    if (_isInitialized) return;

    bgAnimationController = AnimationController(
      vsync: vsync,
      duration: const Duration(seconds: 8),
    )..repeat(reverse: true);

    shimmerAnimationController = AnimationController(
      vsync: vsync,
      duration: const Duration(seconds: 4),
    )..repeat();

    pulseController = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    notificationBlinkController = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    // Sync scroll controllers (guard prevents infinite loop)
    stockHeaderController.addListener(() {
      if (_isSyncing) return;
      _isSyncing = true;
      if (stockBodyController.hasClients &&
          stockHeaderController.offset != stockBodyController.offset) {
        stockBodyController.jumpTo(stockHeaderController.offset);
      }
      _isSyncing = false;
    });
    stockBodyController.addListener(() {
      if (_isSyncing) return;
      _isSyncing = true;
      if (stockHeaderController.hasClients &&
          stockBodyController.offset != stockHeaderController.offset) {
        stockHeaderController.jumpTo(stockBodyController.offset);
      }
      _isSyncing = false;
    });

    _isInitialized = true;
  }

  /// Dispose all animation and scroll controllers.
  @override
  void dispose() {
    if (_isInitialized) {
      bgAnimationController.dispose();
      shimmerAnimationController.dispose();
      pulseController.dispose();
      notificationBlinkController.dispose();
      stockHeaderController.dispose();
      stockBodyController.dispose();
    }
    super.dispose();
  }
}
