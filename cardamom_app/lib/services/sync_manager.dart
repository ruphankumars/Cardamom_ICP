import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'persistent_operation_queue.dart';
import 'cache_manager.dart';
import 'connectivity_service.dart';

/// Sync status for UI display.
enum SyncStatus { idle, syncing, complete, error }

/// Orchestrates incremental data sync between the server and local caches.
///
/// Flow:
/// 1. Replay [PersistentOperationQueue] (pending writes first — FIFO)
/// 2. Call `/api/sync` with per-collection `since` timestamps
/// 3. Merge response into matching [OfflineCache] (upsert/delete)
/// 4. Update per-collection `lastSyncTimestamp`
///
/// Trigger points:
/// - On app launch after auth
/// - When [ConnectivityService] transitions offline → online
/// - Manual pull-to-refresh
class SyncManager extends ChangeNotifier {
  final ApiService _api;
  final PersistentOperationQueue _persistentQueue;
  final CacheManager _cacheManager;
  final ConnectivityService _connectivity;

  // Role-based collection lists — employees only sync what they need
  static const _adminCollections = [
    'dropdowns', 'orders', 'client_contacts', 'tasks',
    'workers', 'expenses', 'gate_passes',
    'dispatch_documents', 'approval_requests',
  ];
  static const _employeeCollections = [
    'dropdowns', 'orders', 'tasks', 'workers', 'gate_passes',
  ];

  SyncStatus _status = SyncStatus.idle;
  String? _currentCollection;
  String? _errorMessage;
  DateTime? _lastSyncTime;
  bool _wasOnline = true;
  Timer? _syncDebounce;
  Timer? _statusResetTimer;

  SyncManager({
    required ApiService apiService,
    required PersistentOperationQueue persistentQueue,
    required CacheManager cacheManager,
    required ConnectivityService connectivityService,
  })  : _api = apiService,
        _persistentQueue = persistentQueue,
        _cacheManager = cacheManager,
        _connectivity = connectivityService {
    // Listen for connectivity changes via ChangeNotifier
    _wasOnline = _connectivity.isOnline;
    _connectivity.addListener(_onConnectivityChanged);
  }

  void _onConnectivityChanged() {
    final isOnline = _connectivity.isOnline;
    if (isOnline && !_wasOnline) {
      // Debounce: wait 5s of stable connectivity before syncing
      // Prevents rapid WiFi flapping from firing multiple syncs
      _syncDebounce?.cancel();
      _syncDebounce = Timer(const Duration(seconds: 5), () {
        if (_connectivity.isOnline) {
          debugPrint('[SyncManager] Stable online for 5s — triggering sync');
          syncAll();
        }
      });
    } else if (!isOnline) {
      _syncDebounce?.cancel();
    }
    _wasOnline = isOnline;
  }

  // ── Public state ────────────────────────────────────────────────────

  SyncStatus get status => _status;
  String? get currentCollection => _currentCollection;
  String? get errorMessage => _errorMessage;
  bool get isSyncing => _status == SyncStatus.syncing;
  DateTime? get lastSyncTime => _lastSyncTime;

  // ── Sync trigger ────────────────────────────────────────────────────

  /// Full sync cycle: replay writes, then pull deltas for all collections.
  Future<void> syncAll() async {
    if (_status == SyncStatus.syncing) return; // Debounce
    if (!_connectivity.isOnline) {
      debugPrint('[SyncManager] Offline — skipping sync');
      return;
    }

    _status = SyncStatus.syncing;
    _errorMessage = null;
    notifyListeners();

    try {
      // Step 1: Replay pending writes
      if (_persistentQueue.pendingCount > 0) {
        _currentCollection = 'pending writes';
        notifyListeners();
        await _persistentQueue.processQueue(_api);
      }

      // Step 2: Pull deltas from server
      // Use role-based collection list — employees get fewer collections
      final prefs = await SharedPreferences.getInstance();
      final role = prefs.getString('userRole') ?? 'employee';
      final isAdmin = role == 'admin' || role == 'ops' || role == 'superadmin';
      final collectionPriority = isAdmin ? _adminCollections : _employeeCollections;

      // Build per-collection since timestamps (each collection gets its own delta)
      final sinceMap = await _getPerCollectionTimestamps(collectionPriority);

      _currentCollection = 'all';
      notifyListeners();

      final response = await _api.sync(
        collections: collectionPriority.join(','),
        sinceMap: sinceMap,
        role: role,
      );

      if (response.data['success'] == true) {
        final collections =
            response.data['collections'] as Map<String, dynamic>? ?? {};
        final serverTimestamp =
            response.data['syncTimestamp'] as String? ?? DateTime.now().toIso8601String();

        // Step 3: Merge each collection into its cache
        for (final key in collectionPriority) {
          if (collections.containsKey(key)) {
            _currentCollection = key;
            notifyListeners();
            await _mergeCollection(key, collections[key] as Map<String, dynamic>);
            await _setSyncTimestamp(key, serverTimestamp);
          }
        }
      }

      _status = SyncStatus.complete;
      _lastSyncTime = DateTime.now();
      _currentCollection = null;
    } catch (e) {
      debugPrint('[SyncManager] Sync error: $e');
      _status = SyncStatus.error;
      _errorMessage = e.toString();
    }

    notifyListeners();

    // Reset to idle after 3 seconds (cancellable to prevent overlap)
    _statusResetTimer?.cancel();
    _statusResetTimer = Timer(const Duration(seconds: 3), () {
      if (_status == SyncStatus.complete || _status == SyncStatus.error) {
        _status = SyncStatus.idle;
        _currentCollection = null;
        notifyListeners();
      }
    });
  }

  /// Sync a single collection (useful for manual refresh of a screen).
  Future<void> syncCollection(String collection) async {
    if (!_connectivity.isOnline) return;

    try {
      final since = await _getSyncTimestamp(collection);
      final response = await _api.sync(collections: collection, since: since);

      if (response.data['success'] == true) {
        final collections =
            response.data['collections'] as Map<String, dynamic>? ?? {};
        final serverTimestamp =
            response.data['syncTimestamp'] as String? ?? DateTime.now().toIso8601String();

        if (collections.containsKey(collection)) {
          await _mergeCollection(
              collection, collections[collection] as Map<String, dynamic>);
          await _setSyncTimestamp(collection, serverTimestamp);
        }
      }
    } catch (e) {
      debugPrint('[SyncManager] syncCollection($collection) error: $e');
    }
  }

  // ── Merge logic ─────────────────────────────────────────────────────

  Future<void> _mergeCollection(
      String key, Map<String, dynamic> syncResult) async {
    final data = syncResult['data'] as List<dynamic>? ?? [];
    final deletedIds = syncResult['deletedIds'] as List<dynamic>? ?? [];

    if (data.isEmpty && deletedIds.isEmpty) return;

    debugPrint(
        '[SyncManager] Merging $key: ${data.length} updates, ${deletedIds.length} deletes');

    // Route to the appropriate cache based on collection key
    switch (key) {
      case 'orders':
        await _mergeOrdersIntoCache(data, deletedIds);
        break;
      case 'dropdowns':
        await _mergeMapCache(_cacheManager.dropdownCache, data, key);
        break;
      case 'client_contacts':
        await _mergeListCache(_cacheManager.clientContactsCache, data, deletedIds);
        break;
      case 'tasks':
        await _mergeListCache(_cacheManager.taskCache, data, deletedIds);
        break;
      case 'workers':
        await _mergeListCache(_cacheManager.workersCache, data, deletedIds);
        break;
      case 'expenses':
        await _mergeListCache(_cacheManager.expensesCache, data, deletedIds);
        break;
      case 'gate_passes':
        await _mergeListCache(_cacheManager.gatePassesCache, data, deletedIds);
        break;
      case 'dispatch_documents':
        await _mergeListCache(_cacheManager.dispatchDocsCache, data, deletedIds);
        break;
      case 'approval_requests':
        await _mergeListCache(_cacheManager.approvalRequestsCache, data, deletedIds);
        break;
    }
  }

  /// Merge order data into the OrderCache.
  /// Orders span 3 Firestore collections tagged with _collection.
  Future<void> _mergeOrdersIntoCache(
      List<dynamic> data, List<dynamic> deletedIds) async {
    final cached = await _cacheManager.orderCache.load(ignoreExpiry: true);
    final existing = cached != null ? List<dynamic>.from(cached) : <dynamic>[];

    // Build lookup by ID for fast merge
    final existingMap = <String, dynamic>{};
    for (final item in existing) {
      if (item is Map && item['id'] != null) {
        existingMap[item['id'].toString()] = item;
      }
    }

    // Upsert new/updated docs
    for (final item in data) {
      if (item is Map && item['id'] != null) {
        existingMap[item['id'].toString()] = item;
      }
    }

    // Remove deleted docs
    final deleteSet = <String>{};
    for (final d in deletedIds) {
      if (d is Map && d['id'] != null) {
        deleteSet.add(d['id'].toString());
      } else if (d is String) {
        deleteSet.add(d);
      }
    }
    existingMap.removeWhere((key, _) => deleteSet.contains(key));

    await _cacheManager.orderCache.save(existingMap.values.toList());
  }

  /// Generic merge for list-type caches.
  Future<void> _mergeListCache(
    dynamic cache,
    List<dynamic> data,
    List<dynamic> deletedIds,
  ) async {
    final cached = await cache.load(ignoreExpiry: true);
    final existing = cached != null ? List<dynamic>.from(cached as List) : <dynamic>[];

    // Build lookup by ID
    final existingMap = <String, dynamic>{};
    for (final item in existing) {
      if (item is Map && item['id'] != null) {
        existingMap[item['id'].toString()] = item;
      }
    }

    // Upsert
    for (final item in data) {
      if (item is Map && item['id'] != null) {
        existingMap[item['id'].toString()] = item;
      }
    }

    // Delete
    final deleteSet = <String>{};
    for (final d in deletedIds) {
      if (d is String) {
        deleteSet.add(d);
      } else if (d is Map && d['id'] != null) {
        deleteSet.add(d['id'].toString());
      }
    }
    existingMap.removeWhere((key, _) => deleteSet.contains(key));

    await cache.save(existingMap.values.toList());
  }

  /// Merge for map-type caches (like dropdowns).
  Future<void> _mergeMapCache(
    dynamic cache,
    List<dynamic> data,
    String key,
  ) async {
    if (data.isEmpty) return;
    // For dropdowns, just save the fresh data directly (small dataset)
    final mapped = <String, dynamic>{};
    for (final item in data) {
      if (item is Map) {
        final id = item['id']?.toString() ?? '';
        mapped[id] = item;
      }
    }
    await cache.save(mapped);
  }

  // ── Per-collection sync timestamps ──────────────────────────────────

  Future<String?> _getSyncTimestamp(String collection) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('sync_ts_$collection');
  }

  Future<void> _setSyncTimestamp(String collection, String timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sync_ts_$collection', timestamp);
  }

  /// Build per-collection since timestamps.
  /// Each collection gets its own delta timestamp — never-synced collections
  /// get null (full dump for that collection only, not all collections).
  Future<Map<String, String?>> _getPerCollectionTimestamps(
      List<String> collections) async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, String?>{};
    for (final col in collections) {
      map[col] = prefs.getString('sync_ts_$col'); // null = first-time full dump
    }
    return map;
  }

  /// Clear all sync timestamps (e.g., on logout).
  Future<void> clearSyncTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('sync_ts_'));
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    _connectivity.removeListener(_onConnectivityChanged);
    super.dispose();
  }
}
