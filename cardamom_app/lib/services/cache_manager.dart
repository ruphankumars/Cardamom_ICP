import 'package:flutter/foundation.dart';
import 'offline_cache.dart';
import 'connectivity_service.dart';

/// Central manager for all offline caches.
///
/// Provides access to typed caches and coordinates refresh/clear operations.
/// Registered as a Provider in main.dart for app-wide access.
class CacheManager extends ChangeNotifier {
  final ConnectivityService _connectivity;

  // Concrete caches — original
  final StockCache stockCache = StockCache();
  final OrderCache orderCache = OrderCache();
  final DailyCartCache dailyCartCache = DailyCartCache();
  final TaskCache taskCache = TaskCache();
  final AttendanceDataCache attendanceCache = AttendanceDataCache();
  final DashboardCache dashboardCache = DashboardCache();
  final DropdownCache dropdownCache = DropdownCache();

  // New caches for offline-first sync
  final ClientContactsCache clientContactsCache = ClientContactsCache();
  final OutstandingCache outstandingCache = OutstandingCache();
  final WorkersCache workersCache = WorkersCache();
  final ExpensesCache expensesCache = ExpensesCache();
  final GatePassesCache gatePassesCache = GatePassesCache();
  final DispatchDocsCache dispatchDocsCache = DispatchDocsCache();
  final ApprovalRequestsCache approvalRequestsCache = ApprovalRequestsCache();
  final SalesSummaryCache salesSummaryCache = SalesSummaryCache();
  final LedgerCache ledgerCache = LedgerCache();
  final PendingOrdersCache pendingOrdersCache = PendingOrdersCache();

  CacheManager(this._connectivity);

  /// Whether the device is currently online.
  bool get isOnline => _connectivity.isOnline;

  /// Record a successful data sync.
  void recordSync() {
    _connectivity.recordSync();
  }

  /// Clear all caches (e.g., on logout).
  Future<void> clearAll() async {
    await Future.wait([
      stockCache.clear(),
      orderCache.clear(),
      dailyCartCache.clear(),
      taskCache.clear(),
      attendanceCache.clear(),
      dashboardCache.clear(),
      dropdownCache.clear(),
      clientContactsCache.clear(),
      outstandingCache.clear(),
      workersCache.clear(),
      expensesCache.clear(),
      gatePassesCache.clear(),
      dispatchDocsCache.clear(),
      approvalRequestsCache.clear(),
      salesSummaryCache.clear(),
      ledgerCache.clear(),
      pendingOrdersCache.clear(),
    ]);
    debugPrint('[CacheManager] All caches cleared');
  }

  /// Instantly mutate cached data for optimistic UI updates.
  ///
  /// [cache] - the cache to update.
  /// [transform] - function that receives the current data and returns the updated data.
  /// Returns true if the cache had data to transform, false otherwise.
  Future<bool> updateLocal<T>({
    required OfflineCache<T> cache,
    required T Function(T current) transform,
  }) async {
    final current = await cache.load(ignoreExpiry: true);
    if (current == null) return false;
    final updated = transform(current);
    await cache.save(updated);
    notifyListeners();
    return true;
  }

  /// Stale-While-Revalidate: return cached data immediately, refresh silently in background.
  ///
  /// Returns cached data right away (if available), then fires [apiCall] in the
  /// background to refresh. The caller can optionally pass [onRefresh] to be
  /// notified when fresh data arrives.
  Future<CachedResult<T>?> fetchSWR<T>({
    required Future<T> Function() apiCall,
    required OfflineCache<T> cache,
    void Function(T freshData)? onRefresh,
  }) async {
    // Return stale data immediately
    final stale = await cache.load(ignoreExpiry: true);

    // Fire background refresh (don't await)
    _backgroundRefresh(apiCall: apiCall, cache: cache, onRefresh: onRefresh);

    if (stale != null) {
      return CachedResult(data: stale, fromCache: true, meta: cache.meta);
    }
    return null;
  }

  Future<void> _backgroundRefresh<T>({
    required Future<T> Function() apiCall,
    required OfflineCache<T> cache,
    void Function(T freshData)? onRefresh,
  }) async {
    try {
      final data = await apiCall();
      await cache.save(data);
      recordSync();
      onRefresh?.call(data);
    } catch (e) {
      debugPrint('[CacheManager] Background refresh failed: $e');
    }
  }

  /// Attempt an API call with offline fallback.
  ///
  /// [apiCall] - the network request to attempt.
  /// [cache] - the OfflineCache to use for fallback.
  /// [onSuccess] - optional callback when API succeeds (for additional processing).
  ///
  /// Returns a [CachedResult] containing the data and whether it came from cache.
  Future<CachedResult<T>> fetchWithCache<T>({
    required Future<T> Function() apiCall,
    required OfflineCache<T> cache,
    void Function(T data)? onSuccess,
  }) async {
    try {
      final data = await apiCall();
      // Save to cache on success
      await cache.save(data);
      recordSync();
      onSuccess?.call(data);
      return CachedResult(data: data, fromCache: false, meta: cache.meta);
    } catch (e) {
      debugPrint('[CacheManager] API call failed, trying cache: $e');
      // Fall back to cache
      final cached = await cache.load(ignoreExpiry: true);
      if (cached != null) {
        return CachedResult(
          data: cached,
          fromCache: true,
          meta: cache.meta,
        );
      }
      // No cache available either - rethrow
      rethrow;
    }
  }
}

/// Result wrapper that indicates whether data came from cache.
class CachedResult<T> {
  final T data;
  final bool fromCache;
  final CacheMeta? meta;

  CachedResult({
    required this.data,
    required this.fromCache,
    this.meta,
  });

  /// Whether the cached data is stale (older than half expiry).
  bool get isStale => meta?.isStale ?? false;

  /// Whether the cached data is expired (past expiry duration).
  bool get isExpired => meta?.isExpired ?? false;

  /// Human-readable age of the data.
  String get ageString => meta?.ageString ?? '';
}
