import 'package:flutter/foundation.dart';
import '../models/gate_pass.dart';
import 'api_service.dart';
import 'gate_pass_cache.dart';

/// Service for managing gate passes with offline support
class GatePassService extends ChangeNotifier {
  final ApiService _apiService;
  GatePassCache? _cache;

  List<GatePass> _passes = [];
  List<GatePass> _pendingPasses = [];
  GatePass? _currentPass;
  bool _isLoading = false;
  String? _error;
  bool _isOffline = false;

  GatePassService(this._apiService);

  /// Set the cache instance (injected from app initialization)
  void setCache(GatePassCache cache) {
    // Remove listener from old cache if switching
    _cache?.removeListener(_onCacheUpdate);
    _cache = cache;
    cache.addListener(_onCacheUpdate);
  }

  @override
  void dispose() {
    _cache?.removeListener(_onCacheUpdate);
    super.dispose();
  }

  void _onCacheUpdate() {
    _isOffline = _cache?.isOffline ?? false;
    notifyListeners();
  }

  // Getters
  List<GatePass> get passes => List.unmodifiable(_passes);
  List<GatePass> get pendingPasses => List.unmodifiable(_pendingPasses);
  GatePass? get currentPass => _currentPass;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isOffline => _isOffline;
  int get pendingOperationsCount => _cache?.pendingCount ?? 0;

  /// Load all gate passes with optional filters
  Future<void> loadPasses({
    GatePassStatus? status,
    GatePassType? type,
    String? requestedBy,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _apiService.getGatePasses(
        status: status?.name,
        type: type?.name,
        requestedBy: requestedBy,
      );

      _passes = (response.data as List)
          .map((json) => GatePass.fromJson(json))
          .toList();
      _error = null;

      // Cache the results
      _cache?.cachePasses(_passes);

      // Sync any pending operations
      if (_cache != null && !_cache!.isOffline && _cache!.hasPendingOperations) {
        await syncPendingOperations();
      }
    } catch (e) {
      _error = 'Failed to load gate passes: $e';
      debugPrint(_error);

      // Use cached data when offline
      if (_cache != null && _cache!.cachedPasses.isNotEmpty) {
        _passes = List.from(_cache!.cachedPasses);
        _error = 'Showing cached data (offline)';
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Sync pending operations when back online
  Future<void> syncPendingOperations() async {
    if (_cache == null || !_cache!.hasPendingOperations) return;

    final operations = _cache!.getOperationsToSync();
    // Iterate in reverse so that removeFromQueue index shifts don't skip items
    for (int i = operations.length - 1; i >= 0; i--) {
      final op = operations[i];
      try {
        switch (op['operation']) {
          case 'create':
            await _apiService.createGatePass(op['data'] as Map<String, dynamic>);
            break;
          case 'approve':
            await _apiService.approveGatePass(op['data']['id']);
            break;
          case 'reject':
            await _apiService.rejectGatePass(op['data']['id'], op['data']['reason']);
            break;
        }
        await _cache!.removeFromQueue(i);
        debugPrint('[GatePassService] Synced operation: ${op['operation']}');
      } catch (e) {
        debugPrint('[GatePassService] Failed to sync: $e');
      }
    }
    notifyListeners();
  }

  /// Load pending passes for admin approval
  Future<void> loadPendingPasses() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _apiService.getPendingGatePasses();

      _pendingPasses = (response.data as List)
          .map((json) => GatePass.fromJson(json))
          .toList();
      _error = null;
    } catch (e) {
      _error = 'Failed to load pending passes: $e';
      debugPrint(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Get a specific gate pass by ID
  Future<GatePass?> getPassById(String id) async {
    try {
      final response = await _apiService.getGatePass(id);
      _currentPass = GatePass.fromJson(response.data);
      notifyListeners();
      return _currentPass;
    } catch (e) {
      debugPrint('Failed to get gate pass: $e');
      return null;
    }
  }

  /// Create a new gate pass request
  Future<GatePass?> createPass({
    required GatePassType type,
    required GatePassPackaging packaging,
    required int bagCount,
    required int boxCount,
    double bagWeight = 50,
    double boxWeight = 20,
    double? actualWeight,
    required GatePassPurpose purpose,
    String? notes,
    String? vehicleNumber,
    String? driverName,
    String? driverPhone,
    required String requestedBy,
  }) async {
    try {
      final calculatedWeight = (bagCount * bagWeight) + (boxCount * boxWeight);
      final finalWeight = actualWeight ?? calculatedWeight;

      final response = await _apiService.createGatePass({
        'type': type.name,
        'packaging': packaging.name,
        'bagCount': bagCount,
        'boxCount': boxCount,
        'bagWeight': bagWeight,
        'boxWeight': boxWeight,
        'calculatedWeight': calculatedWeight,
        'actualWeight': finalWeight,
        'finalWeight': finalWeight,
        'purpose': purpose == GatePassPurpose.return_ ? 'return' : purpose.name,
        'notes': notes,
        'vehicleNumber': vehicleNumber,
        'driverName': driverName,
        'driverPhone': driverPhone,
        'requestedBy': requestedBy,
      });

      final pass = GatePass.fromJson(response.data);
      _passes.insert(0, pass);
      _cache?.addToCache(pass);
      notifyListeners();
      return pass;
    } catch (e) {
      debugPrint('Failed to create gate pass: $e');
      
      // Queue for offline if we have cache
      if (_cache != null) {
        final calculatedWeight = (bagCount * bagWeight) + (boxCount * boxWeight);
        final offlineWeight = actualWeight ?? calculatedWeight;
        await _cache!.queueOperation('create', {
          'type': type.name,
          'packaging': packaging.name,
          'bagCount': bagCount,
          'boxCount': boxCount,
          'bagWeight': bagWeight,
          'boxWeight': boxWeight,
          'calculatedWeight': calculatedWeight,
          'actualWeight': offlineWeight,
          'finalWeight': offlineWeight,
          'purpose': purpose == GatePassPurpose.return_ ? 'return' : purpose.name,
          'notes': notes,
          'vehicleNumber': vehicleNumber,
          'driverName': driverName,
          'driverPhone': driverPhone,
          'requestedBy': requestedBy,
        });
        debugPrint('[GatePassService] Queued create for offline sync');
      }
      return null;
    }
  }

  /// Update an existing gate pass (before approval)
  Future<GatePass?> updatePass(String id, Map<String, dynamic> updates) async {
    try {
      final response = await _apiService.updateGatePass(id, updates);
      final pass = GatePass.fromJson(response.data);
      
      // Update in local list
      final index = _passes.indexWhere((p) => p.id == id);
      if (index >= 0) {
        _passes[index] = pass;
      }
      
      notifyListeners();
      return pass;
    } catch (e) {
      debugPrint('Failed to update gate pass: $e');
      return null;
    }
  }

  /// Approve a gate pass (confirmation-based, no signature required)
  Future<bool> approvePass(String id) async {
    try {
      _error = null;
      final response = await _apiService.approveGatePass(id);

      if (response.data == null) {
        _error = 'Gate pass not found after approval';
        notifyListeners();
        return false;
      }

      final pass = GatePass.fromJson(response.data);

      // Update in lists
      _updatePassInLists(pass);

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to approve gate pass: $e');
      _error = 'Failed to approve: ${e.toString().replaceAll('DioException', '').replaceAll(RegExp(r'\[.*?\]'), '').trim()}';
      notifyListeners();
      return false;
    }
  }

  /// Reject a gate pass with reason
  Future<bool> rejectPass(String id, String reason) async {
    try {
      final response = await _apiService.rejectGatePass(id, reason);
      final pass = GatePass.fromJson(response.data);
      
      // Update in lists
      _updatePassInLists(pass);
      
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to reject gate pass: $e');
      return false;
    }
  }

  /// Helper to update pass in all lists
  void _updatePassInLists(GatePass pass) {
    // Update in main list
    final mainIndex = _passes.indexWhere((p) => p.id == pass.id);
    if (mainIndex >= 0) {
      _passes[mainIndex] = pass;
    }
    
    // Remove from pending if approved/rejected
    if (!pass.isPending) {
      _pendingPasses.removeWhere((p) => p.id == pass.id);
    }
    
    // Update current pass
    if (_currentPass?.id == pass.id) {
      _currentPass = pass;
    }
  }

  /// Get user's passes
  Future<List<GatePass>> getMyPasses(String username) async {
    await loadPasses(requestedBy: username);
    return _passes;
  }

  /// Get count of pending passes (for badge)
  int get pendingCount => _pendingPasses.length;

  /// Record entry time for a pass
  Future<bool> recordEntry(String id) async {
    try {
      final response = await _apiService.recordGatePassEntry(id);
      final pass = GatePass.fromJson(response.data);
      _updatePassInLists(pass);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to record entry: $e');
      return false;
    }
  }

  /// Record exit time for a pass
  Future<bool> recordExit(String id) async {
    try {
      final response = await _apiService.recordGatePassExit(id);
      final pass = GatePass.fromJson(response.data);
      _updatePassInLists(pass);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to record exit: $e');

      // Set meaningful error message for specific cases
      if (e.toString().contains('Entry must be recorded')) {
        _error = 'Entry must be recorded before exit can be recorded';
      } else {
        _error = 'Failed to record exit: ${e.toString().replaceAll('DioException', '').replaceAll(RegExp(r'\[.*?\]'), '').trim()}';
      }
      notifyListeners();
      return false;
    }
  }

  /// Mark pass as completed
  Future<bool> completePass(String id) async {
    try {
      final response = await _apiService.completeGatePass(id);
      final pass = GatePass.fromJson(response.data);
      _updatePassInLists(pass);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to complete pass: $e');
      return false;
    }
  }
}
