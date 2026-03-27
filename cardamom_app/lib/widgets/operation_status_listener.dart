import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/operation_queue.dart';

/// Wraps the app to listen for [OperationQueue] results and show
/// non-blocking snackbar toasts for success/failure.
///
/// Place this above (or wrapping) your MaterialApp's home/navigator
/// so toasts work even after navigating away from the originating screen.
class OperationStatusListener extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  const OperationStatusListener({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  @override
  State<OperationStatusListener> createState() =>
      _OperationStatusListenerState();
}

class _OperationStatusListenerState extends State<OperationStatusListener> {
  StreamSubscription<OperationResult>? _subscription;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscription?.cancel();
    final queue = context.read<OperationQueue>();
    _subscription = queue.results.listen(_onResult);
  }

  void _onResult(OperationResult result) {
    // Find the nearest ScaffoldMessenger via the navigator's overlay context
    final navContext = widget.navigatorKey.currentContext;
    if (navContext == null) return;

    final messenger = ScaffoldMessenger.maybeOf(navContext);
    if (messenger == null) return;

    final message = result.message ??
        (result.success ? 'Done' : 'Operation failed');

    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(
            result.success ? Icons.check_circle : Icons.error_outline,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
      backgroundColor: result.success
          ? const Color(0xFF22C55E)
          : const Color(0xFFEF4444),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: Duration(seconds: result.success ? 2 : 4),
      dismissDirection: DismissDirection.horizontal,
    ));
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
