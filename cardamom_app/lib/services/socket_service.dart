import 'dart:async';
import 'package:flutter/foundation.dart';
import 'api_service.dart';

/// Service for real-time communication with the ICP backend via HTTP polling.
///
/// Replaces Socket.IO WebSockets (not supported on ICP) with periodic
/// polling of the /api/notifications/poll endpoint.
class SocketService extends ChangeNotifier {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  Timer? _pollTimer;
  bool _isConnected = false;
  String? _lastPollTimestamp;

  // Callbacks for approval events
  final List<void Function(Map<String, dynamic>)> _onApprovalCreatedCallbacks = [];
  final List<void Function(Map<String, dynamic>)> _onApprovalResolvedCallbacks = [];
  final List<void Function(Map<String, dynamic>)> _onApprovalUpdatedCallbacks = [];
  // Callbacks for transport assignment updates
  final List<void Function(Map<String, dynamic>)> _onTransportUpdatedCallbacks = [];

  bool get isConnected => _isConnected;

  /// Connect — starts HTTP polling (replaces WebSocket connection).
  void connect({required String userId, required String role}) {
    if (_pollTimer != null) {
      debugPrint('[SocketService] Already polling');
      return;
    }

    debugPrint('[SocketService] Starting HTTP polling as $userId ($role)');
    _isConnected = true;
    _lastPollTimestamp = DateTime.now().toIso8601String();
    notifyListeners();

    // Poll every 15 seconds for real-time-ish updates
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final api = ApiService();
      final since = _lastPollTimestamp ?? DateTime.now().subtract(const Duration(seconds: 30)).toIso8601String();
      final response = await api.dio.get('/notifications/poll', queryParameters: {'since': since});
      final data = response.data;

      if (data is Map && data['success'] == true) {
        final notifications = (data['notifications'] as List?) ?? [];
        _lastPollTimestamp = DateTime.now().toIso8601String();

        for (final notif in notifications) {
          final n = notif as Map<String, dynamic>;
          final type = n['type']?.toString() ?? '';

          if (type == 'approval_request' || type == 'approval_created') {
            for (final cb in _onApprovalCreatedCallbacks) {
              cb(n);
            }
          } else if (type == 'approval_resolved') {
            for (final cb in _onApprovalResolvedCallbacks) {
              cb(n);
            }
          } else if (type == 'approval_updated') {
            for (final cb in _onApprovalUpdatedCallbacks) {
              cb(n);
            }
          } else if (type == 'transport_update' || type == 'transport-assignments-updated') {
            for (final cb in _onTransportUpdatedCallbacks) {
              cb(n);
            }
          }
        }
      }

      if (!_isConnected) {
        _isConnected = true;
        notifyListeners();
      }
    } catch (e) {
      if (_isConnected) {
        _isConnected = false;
        notifyListeners();
      }
    }
  }

  /// Add callback for when a new approval request is created (for admins)
  void onApprovalCreated(void Function(Map<String, dynamic>) callback) {
    _onApprovalCreatedCallbacks.add(callback);
  }

  /// Remove a specific approval created callback
  void removeApprovalCreatedCallback(void Function(Map<String, dynamic>) callback) {
    _onApprovalCreatedCallbacks.remove(callback);
  }

  /// Add callback for when an approval request is resolved (for requesters)
  void onApprovalResolved(void Function(Map<String, dynamic>) callback) {
    _onApprovalResolvedCallbacks.add(callback);
  }

  /// Remove a specific approval resolved callback
  void removeApprovalResolvedCallback(void Function(Map<String, dynamic>) callback) {
    _onApprovalResolvedCallbacks.remove(callback);
  }

  /// Add callback for when approval list should be refreshed (for admins)
  void onApprovalUpdated(void Function(Map<String, dynamic>) callback) {
    _onApprovalUpdatedCallbacks.add(callback);
  }

  /// Remove a specific approval updated callback
  void removeApprovalUpdatedCallback(void Function(Map<String, dynamic>) callback) {
    _onApprovalUpdatedCallbacks.remove(callback);
  }

  /// Add callback for transport assignment updates
  void onTransportUpdated(void Function(Map<String, dynamic>) callback) {
    _onTransportUpdatedCallbacks.add(callback);
  }

  /// Remove a specific transport updated callback
  void removeTransportUpdatedCallback(void Function(Map<String, dynamic>) callback) {
    _onTransportUpdatedCallbacks.remove(callback);
  }

  /// Remove all callbacks
  void clearCallbacks() {
    _onApprovalCreatedCallbacks.clear();
    _onApprovalResolvedCallbacks.clear();
    _onApprovalUpdatedCallbacks.clear();
    _onTransportUpdatedCallbacks.clear();
  }

  /// Disconnect — stops HTTP polling.
  void disconnect() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isConnected = false;
    debugPrint('[SocketService] Polling stopped');
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    clearCallbacks();
    super.dispose();
  }
}
