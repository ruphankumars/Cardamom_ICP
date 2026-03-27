import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/gate_pass.dart';

/// Offline cache and sync service for gate passes
class GatePassCache extends ChangeNotifier {
  static const String _cacheKey = 'gate_passes_cache';
  static const String _queueKey = 'gate_passes_queue';

  List<GatePass> _cachedPasses = [];
  List<Map<String, dynamic>> _pendingOperations = [];
  bool _isOffline = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // Getters
  List<GatePass> get cachedPasses => List.unmodifiable(_cachedPasses);
  List<Map<String, dynamic>> get pendingOperations => List.unmodifiable(_pendingOperations);
  bool get isOffline => _isOffline;
  bool get hasPendingOperations => _pendingOperations.isNotEmpty;
  int get pendingCount => _pendingOperations.length;

  /// Initialize cache and check connectivity
  Future<void> initialize() async {
    await _loadCache();
    await _loadQueue();
    await _checkConnectivity();

    // Listen for connectivity changes (store subscription for cleanup)
    try {
      _connectivitySubscription?.cancel();
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
        _handleConnectivityChange(results.isNotEmpty ? results.first : ConnectivityResult.none);
      });
    } catch (e) {
      debugPrint('[GatePassCache] Connectivity listener not available: $e');
    }
  }

  /// Check current connectivity
  Future<void> _checkConnectivity() async {
    try {
      final results = await Connectivity().checkConnectivity();
      final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
      _isOffline = result == ConnectivityResult.none;
    } catch (e) {
      // Plugin not available (e.g., during hot restart) - assume online
      debugPrint('[GatePassCache] Connectivity check failed: $e - assuming online');
      _isOffline = false;
    }
    notifyListeners();
  }

  /// Handle connectivity change
  void _handleConnectivityChange(ConnectivityResult result) {
    final wasOffline = _isOffline;
    _isOffline = result == ConnectivityResult.none;

    if (wasOffline && !_isOffline && _pendingOperations.isNotEmpty) {
      // Back online - trigger sync
      debugPrint('[GatePassCache] Back online, triggering sync');
      // Sync will be triggered by GatePassService when it notices connection restored
    }

    notifyListeners();
  }

  /// Load cached passes from storage
  Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_cacheKey);
      if (json != null) {
        final list = jsonDecode(json) as List;
        _cachedPasses = list.map((e) => GatePass.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('[GatePassCache] Error loading cache: $e');
    }
  }

  /// Load pending operations queue
  Future<void> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_queueKey);
      if (json != null) {
        _pendingOperations = List<Map<String, dynamic>>.from(jsonDecode(json));
      }
    } catch (e) {
      debugPrint('[GatePassCache] Error loading queue: $e');
    }
  }

  /// Save passes to cache
  Future<void> cachePasses(List<GatePass> passes) async {
    _cachedPasses = passes;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(passes.map((p) => p.toJson()).toList()));
    } catch (e) {
      debugPrint('[GatePassCache] Error saving cache: $e');
    }
    notifyListeners();
  }

  /// Add a pass to cache
  void addToCache(GatePass pass) {
    _cachedPasses = [pass, ..._cachedPasses];
    _saveCache();
  }

  /// Update pass in cache
  void updateInCache(GatePass pass) {
    final index = _cachedPasses.indexWhere((p) => p.id == pass.id);
    if (index >= 0) {
      _cachedPasses[index] = pass;
      _saveCache();
    }
  }

  /// Queue an operation for later sync
  Future<void> queueOperation(String operation, Map<String, dynamic> data) async {
    _pendingOperations.add({
      'operation': operation,
      'data': data,
      'timestamp': DateTime.now().toIso8601String(),
    });
    await _saveQueue();
    notifyListeners();
  }

  /// Remove operation from queue after successful sync
  Future<void> removeFromQueue(int index) async {
    if (index >= 0 && index < _pendingOperations.length) {
      _pendingOperations.removeAt(index);
      await _saveQueue();
      notifyListeners();
    }
  }

  /// Clear all pending operations
  Future<void> clearQueue() async {
    _pendingOperations.clear();
    await _saveQueue();
    notifyListeners();
  }

  /// Save cache to storage
  Future<void> _saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(_cachedPasses.map((p) => p.toJson()).toList()));
    } catch (e) {
      debugPrint('[GatePassCache] Error saving cache: $e');
    }
  }

  /// Save queue to storage
  Future<void> _saveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queueKey, jsonEncode(_pendingOperations));
    } catch (e) {
      debugPrint('[GatePassCache] Error saving queue: $e');
    }
  }

  /// Get operations for syncing
  List<Map<String, dynamic>> getOperationsToSync() {
    return List.from(_pendingOperations);
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}
