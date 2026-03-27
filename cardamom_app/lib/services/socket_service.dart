import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

/// Service for real-time WebSocket communication with the backend.
/// Handles approval notifications and other real-time events.
class SocketService extends ChangeNotifier {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? _socket;
  bool _isConnected = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;
  Timer? _reconnectTimer;
  
  // Callbacks for approval events
  final List<void Function(Map<String, dynamic>)> _onApprovalCreatedCallbacks = [];
  final List<void Function(Map<String, dynamic>)> _onApprovalResolvedCallbacks = [];
  final List<void Function(Map<String, dynamic>)> _onApprovalUpdatedCallbacks = [];
  // Callbacks for transport assignment updates
  final List<void Function(Map<String, dynamic>)> _onTransportUpdatedCallbacks = [];
  
  bool get isConnected => _isConnected;
  
  // Cloud backend URL
  static const String _socketUrl = 'https://cardamom-ysgf.onrender.com';
  
  /// Connect to the WebSocket server
  void connect({required String userId, required String role}) {
    if (_socket != null) {
      debugPrint('🔌 [SocketService] Already connected or connecting');
      return;
    }
    
    debugPrint('🔌 [SocketService] Connecting to $_socketUrl as $userId ($role)');
    
    try {
      _socket = IO.io(
        _socketUrl,
        IO.OptionBuilder()
            .setTransports(['websocket', 'polling'])
            .enableAutoConnect()
            .enableReconnection()
            .setReconnectionAttempts(_maxReconnectAttempts)
            .setReconnectionDelay(2000)
            .build(),
      );
      
      _socket!.onConnect((_) {
        _isConnected = true;
        _reconnectAttempts = 0;
        debugPrint('✅ [SocketService] Connected! Registering user...');
        
        // Register with the server
        _socket!.emit('register', {'userId': userId, 'role': role});
        notifyListeners();
      });
      
      _socket!.onDisconnect((_) {
        _isConnected = false;
        debugPrint('🔌 [SocketService] Disconnected');
        notifyListeners();
      });
      
      _socket!.onConnectError((error) {
        debugPrint('❌ [SocketService] Connection error: $error');
        _handleConnectionFailure();
      });
      
      _socket!.onError((error) {
        debugPrint('❌ [SocketService] Error: $error');
      });
      
      // Listen for approval events
      _socket!.on('approval:created', (data) {
        debugPrint('📬 [SocketService] Received approval:created');
        final eventData = data is Map<String, dynamic> 
            ? data 
            : <String, dynamic>{'data': data};
        for (final callback in _onApprovalCreatedCallbacks) {
          callback(eventData);
        }
      });
      
      _socket!.on('approval:resolved', (data) {
        debugPrint('📬 [SocketService] Received approval:resolved');
        final eventData = data is Map<String, dynamic> 
            ? data 
            : <String, dynamic>{'data': data};
        for (final callback in _onApprovalResolvedCallbacks) {
          callback(eventData);
        }
      });
      
      _socket!.on('approval:updated', (data) {
        debugPrint('📬 [SocketService] Received approval:updated');
        final eventData = data is Map<String, dynamic>
            ? data
            : <String, dynamic>{'data': data};
        for (final callback in _onApprovalUpdatedCallbacks) {
          callback(eventData);
        }
      });

      // Listen for transport assignment updates
      _socket!.on('transport-assignments-updated', (data) {
        debugPrint('🚚 [SocketService] Received transport-assignments-updated');
        final eventData = data is Map<String, dynamic>
            ? data
            : <String, dynamic>{'data': data};
        for (final callback in _onTransportUpdatedCallbacks) {
          callback(eventData);
        }
      });

    } catch (e) {
      debugPrint('❌ [SocketService] Failed to create socket: $e');
      _handleConnectionFailure();
    }
  }
  
  void _handleConnectionFailure() {
    _reconnectAttempts++;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('⚠️ [SocketService] Max reconnect attempts reached. Falling back to polling.');
      // Connection failed - the NotificationService will handle fallback to polling
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
  
  /// Disconnect from the WebSocket server
  void disconnect() {
    _reconnectTimer?.cancel();
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
    _reconnectAttempts = 0;
    debugPrint('🔌 [SocketService] Disconnected and disposed');
    notifyListeners();
  }
  
  @override
  void dispose() {
    disconnect();
    clearCallbacks();
    super.dispose();
  }
}
