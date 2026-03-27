import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Result of a completed background operation.
class OperationResult {
  final String id;
  final String type;
  final bool success;
  final String? message;
  final dynamic data;

  const OperationResult({
    required this.id,
    required this.type,
    required this.success,
    this.message,
    this.data,
  });
}

/// A single queued operation.
class Operation {
  final String id;
  final String type; // 'create', 'update', 'delete', 'send'
  final Future<dynamic> Function() execute;
  final VoidCallback? onSuccess;
  final VoidCallback? onRollback;
  final String? successMessage;
  final String? failureMessage;
  final int maxRetries;

  int _attempts = 0;

  Operation({
    required this.id,
    required this.type,
    required this.execute,
    this.onSuccess,
    this.onRollback,
    this.successMessage,
    this.failureMessage,
    this.maxRetries = 3,
  });

  int get attempts => _attempts;
  void incrementAttempts() => _attempts++;
}

/// Background operation queue with sequential processing and retry logic.
///
/// Enqueue API calls to process them in the background while the UI stays
/// responsive. Failed operations are retried with exponential backoff.
/// After final failure, the rollback callback is invoked.
class OperationQueue extends ChangeNotifier {
  final Queue<Operation> _pending = Queue<Operation>();
  final List<OperationResult> _recentResults = [];
  bool _isProcessing = false;

  final StreamController<OperationResult> _resultController =
      StreamController<OperationResult>.broadcast();

  /// Stream of operation results (success/failure) for UI feedback.
  Stream<OperationResult> get results => _resultController.stream;

  /// Number of pending operations.
  int get pendingCount => _pending.length;

  /// Whether the queue is currently processing.
  bool get isProcessing => _isProcessing;

  /// Recent results (last 20) for late-joining listeners.
  List<OperationResult> get recentResults =>
      List.unmodifiable(_recentResults);

  /// Enqueue an operation for background processing.
  void enqueue(Operation op) {
    _pending.add(op);
    notifyListeners();
    _processNext();
  }

  Future<void> _processNext() async {
    if (_isProcessing || _pending.isEmpty) return;
    _isProcessing = true;
    notifyListeners();

    while (_pending.isNotEmpty) {
      final op = _pending.removeFirst();
      await _executeWithRetry(op);
    }

    _isProcessing = false;
    notifyListeners();
  }

  Future<void> _executeWithRetry(Operation op) async {
    while (op.attempts < op.maxRetries) {
      op.incrementAttempts();
      try {
        final data = await op.execute();
        op.onSuccess?.call();
        _emitResult(OperationResult(
          id: op.id,
          type: op.type,
          success: true,
          message: op.successMessage,
          data: data,
        ));
        return;
      } catch (e) {
        debugPrint(
            '[OperationQueue] ${op.type} attempt ${op.attempts}/${op.maxRetries} failed: $e');
        if (op.attempts < op.maxRetries) {
          // Exponential backoff: 1s, 2s, 4s
          await Future.delayed(Duration(seconds: 1 << (op.attempts - 1)));
        }
      }
    }

    // All retries exhausted — rollback
    debugPrint('[OperationQueue] ${op.type} failed after ${op.maxRetries} attempts, rolling back');
    try {
      op.onRollback?.call();
    } catch (e) {
      debugPrint('[OperationQueue] Rollback failed: $e');
    }
    _emitResult(OperationResult(
      id: op.id,
      type: op.type,
      success: false,
      message: op.failureMessage ?? 'Operation failed. Changes reverted.',
    ));
  }

  void _emitResult(OperationResult result) {
    _recentResults.add(result);
    if (_recentResults.length > 20) _recentResults.removeAt(0);
    _resultController.add(result);
  }

  @override
  void dispose() {
    _resultController.close();
    super.dispose();
  }
}
