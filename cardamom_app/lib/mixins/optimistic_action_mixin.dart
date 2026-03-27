import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/operation_queue.dart';

/// Mixin that provides optimistic UI update helpers for any screen.
///
/// Usage:
/// ```dart
/// class _MyScreenState extends State<MyScreen> with OptimisticActionMixin {
///   @override
///   OperationQueue get operationQueue => context.read<OperationQueue>();
///
///   void _deleteItem(String id) {
///     final removed = items.firstWhere((e) => e.id == id);
///     final index = items.indexOf(removed);
///     optimistic(
///       type: 'delete',
///       applyLocal: () => setState(() => items.removeWhere((e) => e.id == id)),
///       apiCall: () => apiService.delete(id),
///       rollback: () => setState(() => items.insert(index, removed)),
///       successMessage: 'Item deleted',
///     );
///   }
/// }
/// ```
mixin OptimisticActionMixin<T extends StatefulWidget> on State<T> {
  OperationQueue get operationQueue;

  int _opCounter = 0;

  /// Execute an operation optimistically:
  /// 1. Apply local change immediately (instant UI)
  /// 2. Enqueue API call for background execution
  /// 3. On failure, rollback local change and show error toast
  void optimistic({
    required String type,
    required VoidCallback applyLocal,
    required Future<dynamic> Function() apiCall,
    VoidCallback? rollback,
    String? successMessage,
    String? failureMessage,
    VoidCallback? onSuccess,
    int maxRetries = 3,
  }) {
    // 1. Instant local update
    applyLocal();

    // 2. Enqueue background API call
    _opCounter++;
    operationQueue.enqueue(Operation(
      id: '${T.toString()}_${_opCounter}_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      execute: apiCall,
      onSuccess: onSuccess,
      onRollback: () {
        if (mounted) rollback?.call();
      },
      successMessage: successMessage,
      failureMessage: failureMessage,
      maxRetries: maxRetries,
    ));
  }

  /// Fire-and-forget: no local state change, just background API call with toast feedback.
  /// Use this when there's no meaningful local state to update (e.g., sending a message).
  void fireAndForget({
    required String type,
    required Future<dynamic> Function() apiCall,
    String? successMessage,
    String? failureMessage,
    VoidCallback? onSuccess,
    int maxRetries = 3,
  }) {
    _opCounter++;
    operationQueue.enqueue(Operation(
      id: '${T.toString()}_${_opCounter}_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      execute: apiCall,
      onSuccess: () {
        if (mounted) onSuccess?.call();
      },
      successMessage: successMessage,
      failureMessage: failureMessage,
      maxRetries: maxRetries,
    ));
  }
}
