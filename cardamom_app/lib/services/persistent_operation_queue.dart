import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'connectivity_service.dart';

/// A single pending operation that can be serialized to disk.
///
/// Unlike [Operation] in operation_queue.dart which stores closures,
/// this stores serializable data (endpoint, method, payload) so it
/// survives app kill and restart.
class PendingOperation {
  final String id;
  final String type; // 'create_order', 'update_order', 'delete_order', etc.
  final String method; // 'POST', 'PUT', 'PATCH', 'DELETE'
  final String endpoint; // '/orders/batch', '/orders/123', etc.
  final Map<String, dynamic>? payload;
  final DateTime createdAt;
  int retryCount;
  String? errorMessage;

  PendingOperation({
    required this.id,
    required this.type,
    required this.method,
    required this.endpoint,
    this.payload,
    DateTime? createdAt,
    this.retryCount = 0,
    this.errorMessage,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'method': method,
        'endpoint': endpoint,
        'payload': payload,
        'createdAt': createdAt.toIso8601String(),
        'retryCount': retryCount,
        'errorMessage': errorMessage,
      };

  factory PendingOperation.fromJson(Map<String, dynamic> json) =>
      PendingOperation(
        id: json['id'] as String,
        type: json['type'] as String,
        method: json['method'] as String,
        endpoint: json['endpoint'] as String,
        payload: json['payload'] != null
            ? Map<String, dynamic>.from(json['payload'] as Map)
            : null,
        createdAt: DateTime.parse(json['createdAt'] as String),
        retryCount: json['retryCount'] as int? ?? 0,
        errorMessage: json['errorMessage'] as String?,
      );

  /// Human-readable label for UI.
  String get label {
    switch (type) {
      case 'create_order':
        return 'New order';
      case 'create_orders':
        return 'New orders (batch)';
      case 'update_order':
        return 'Update order';
      case 'delete_order':
        return 'Delete order';
      case 'add_to_cart':
        return 'Add to cart';
      case 'dispatch':
        return 'Dispatch';
      default:
        return type.replaceAll('_', ' ');
    }
  }
}

/// Disk-persisted operation queue for offline-first writes.
///
/// Stores pending API operations in SharedPreferences as JSON.
/// On app launch or connectivity restore, replays operations FIFO.
/// Survives app kill — operations are never lost.
///
/// Max 5 retries per operation with exponential backoff.
/// Failed ops move to [failedOps] (visible in UI, manually retryable).
class PersistentOperationQueue extends ChangeNotifier {
  static const String _storageKey = 'persistent_op_queue';
  static const String _failedKey = 'persistent_op_failed';
  static const int _maxRetries = 5;

  List<PendingOperation> _pending = [];
  List<PendingOperation> _failed = [];
  bool _isProcessing = false;
  ConnectivityService? _connectivity;

  /// Stream of successfully completed operations (for UI feedback).
  final StreamController<PendingOperation> _completedController =
      StreamController<PendingOperation>.broadcast();
  Stream<PendingOperation> get completedOps => _completedController.stream;

  /// All pending operations (FIFO order).
  List<PendingOperation> get pending => List.unmodifiable(_pending);

  /// Operations that failed after max retries.
  List<PendingOperation> get failedOps => List.unmodifiable(_failed);

  /// Total number of pending operations.
  int get pendingCount => _pending.length;

  /// Number of failed operations.
  int get failedCount => _failed.length;

  /// Whether the queue is currently processing.
  bool get isProcessing => _isProcessing;

  /// Whether there are any pending or failed operations.
  bool get hasPending => _pending.isNotEmpty || _failed.isNotEmpty;

  // ── Initialization ──────────────────────────────────────────────────

  /// Load persisted queue from disk. Call once on app startup.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final pendingJson = prefs.getString(_storageKey);
      if (pendingJson != null) {
        final list = jsonDecode(pendingJson) as List;
        _pending = list
            .map((e) => PendingOperation.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      final failedJson = prefs.getString(_failedKey);
      if (failedJson != null) {
        final list = jsonDecode(failedJson) as List;
        _failed = list
            .map((e) => PendingOperation.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      debugPrint(
          '[PersistentQueue] Loaded ${_pending.length} pending, ${_failed.length} failed ops');
      notifyListeners();
    } catch (e) {
      debugPrint('[PersistentQueue] Initialize error: $e');
    }
  }

  // ── Enqueue ─────────────────────────────────────────────────────────

  /// Add an operation to the queue and persist to disk.
  Future<void> enqueue(PendingOperation op) async {
    _pending.add(op);
    await _persist();
    notifyListeners();
  }

  /// Set the connectivity service for connectivity-aware processing.
  void setConnectivity(ConnectivityService connectivity) {
    _connectivity = connectivity;
  }

  // ── Process Queue ───────────────────────────────────────────────────

  /// Replay all pending operations FIFO against the API.
  /// Call when connectivity is restored or on app launch.
  Future<void> processQueue(ApiService api) async {
    if (_isProcessing || _pending.isEmpty) return;

    _isProcessing = true;
    notifyListeners();

    try {
      while (_pending.isNotEmpty) {
        // ── Connectivity gate: stop processing if we went offline ──
        if (_connectivity != null && !_connectivity!.isOnline) {
          debugPrint('[PersistentQueue] Gone offline mid-processing — pausing queue');
          break;
        }

        final op = _pending.first;

        bool success = false;
        try {
          await _executeOperation(api, op);
          success = true;
        } catch (e) {
          op.retryCount++;
          op.errorMessage = e.toString();
          debugPrint(
              '[PersistentQueue] ${op.type} attempt ${op.retryCount}/$_maxRetries failed: $e');

          if (op.retryCount >= _maxRetries) {
            // Move to failed list
            _pending.removeAt(0);
            _failed.add(op);
            await _persist();
            notifyListeners();
            continue;
          }

          // Exponential backoff: 1s, 2s, 4s, 8s, 16s
          await Future.delayed(Duration(seconds: 1 << (op.retryCount - 1)));
          await _persist();
          continue; // Retry same op
        }

        if (success) {
          _pending.removeAt(0);
          _completedController.add(op);  // Broadcast completion
          await _persist();
          notifyListeners();
        }
      }
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  /// Execute a single operation against the API.
  Future<void> _executeOperation(ApiService api, PendingOperation op) async {
    // Endpoints that expect a raw array body (PendingOperation.payload is always Map,
    // so the array gets wrapped as {'orders': [...]}). Unwrap for these endpoints.
    final dynamic data;
    if (op.type == 'create_orders' && op.payload?['orders'] is List) {
      data = op.payload!['orders'];
    } else {
      data = op.payload;
    }

    switch (op.method.toUpperCase()) {
      case 'POST':
        await api.dio.post(op.endpoint, data: data);
        break;
      case 'PUT':
        await api.dio.put(op.endpoint, data: op.payload);
        break;
      case 'PATCH':
        await api.dio.patch(op.endpoint, data: op.payload);
        break;
      case 'DELETE':
        await api.dio.delete(op.endpoint, data: op.payload);
        break;
      default:
        throw Exception('Unsupported method: ${op.method}');
    }
  }

  // ── Manual retry of failed ops ──────────────────────────────────────

  /// Move a failed operation back to the pending queue for retry.
  Future<void> retryFailed(String operationId) async {
    final idx = _failed.indexWhere((op) => op.id == operationId);
    if (idx == -1) return;

    final op = _failed.removeAt(idx);
    op.retryCount = 0;
    op.errorMessage = null;
    _pending.add(op);
    await _persist();
    notifyListeners();
  }

  /// Retry all failed operations.
  Future<void> retryAllFailed() async {
    for (final op in _failed) {
      op.retryCount = 0;
      op.errorMessage = null;
    }
    _pending.addAll(_failed);
    _failed.clear();
    await _persist();
    notifyListeners();
  }

  /// Discard a failed operation permanently.
  Future<void> discardFailed(String operationId) async {
    _failed.removeWhere((op) => op.id == operationId);
    await _persist();
    notifyListeners();
  }

  /// Clear all pending operations (use with caution).
  Future<void> clearAll() async {
    _pending.clear();
    _failed.clear();
    await _persist();
    notifyListeners();
  }

  @override
  void dispose() {
    _completedController.close();
    super.dispose();
  }

  // ── Persistence ─────────────────────────────────────────────────────

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storageKey,
        jsonEncode(_pending.map((e) => e.toJson()).toList()),
      );
      await prefs.setString(
        _failedKey,
        jsonEncode(_failed.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[PersistentQueue] Persist error: $e');
    }
  }
}
