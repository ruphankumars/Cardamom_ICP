import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Metadata stored alongside cached data.
class CacheMeta {
  final DateTime lastSyncTimestamp;
  final int dataVersion;
  final Duration expiryDuration;

  CacheMeta({
    required this.lastSyncTimestamp,
    this.dataVersion = 1,
    required this.expiryDuration,
  });

  bool get isExpired =>
      DateTime.now().difference(lastSyncTimestamp) > expiryDuration;

  /// Returns true if data is older than half the expiry duration.
  bool get isStale =>
      DateTime.now().difference(lastSyncTimestamp) > (expiryDuration * 0.5);

  /// Human-readable age string.
  String get ageString {
    final diff = DateTime.now().difference(lastSyncTimestamp);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Map<String, dynamic> toJson() => {
    'lastSyncTimestamp': lastSyncTimestamp.toIso8601String(),
    'dataVersion': dataVersion,
    'expiryDurationMs': expiryDuration.inMilliseconds,
  };

  factory CacheMeta.fromJson(Map<String, dynamic> json) => CacheMeta(
    lastSyncTimestamp: DateTime.parse(json['lastSyncTimestamp']),
    dataVersion: json['dataVersion'] ?? 1,
    expiryDuration: Duration(milliseconds: json['expiryDurationMs'] ?? 3600000),
  );
}

/// Storage strategy for cache data.
enum CacheStorage { sharedPreferences, file }

/// Generic offline cache base class.
///
/// Handles serialization to SharedPreferences (small datasets) or
/// JSON files via path_provider (large datasets).
abstract class OfflineCache<T> {
  final String cacheKey;
  final Duration defaultExpiry;
  final CacheStorage storage;

  CacheMeta? _meta;

  OfflineCache({
    required this.cacheKey,
    required this.defaultExpiry,
    this.storage = CacheStorage.sharedPreferences,
  });

  // Getters
  CacheMeta? get meta => _meta;
  bool get hasCachedData => _meta != null;
  bool get isExpired => _meta?.isExpired ?? true;
  bool get isStale => _meta?.isStale ?? true;
  String get ageString => _meta?.ageString ?? 'No data';
  DateTime? get lastSyncTime => _meta?.lastSyncTimestamp;

  /// Serialize data to JSON-encodable format.
  dynamic toJsonData(T data);

  /// Deserialize data from JSON.
  T fromJsonData(dynamic json);

  /// Save data to cache.
  Future<void> save(T data) async {
    _meta = CacheMeta(
      lastSyncTimestamp: DateTime.now(),
      expiryDuration: defaultExpiry,
    );

    final payload = jsonEncode({
      'meta': _meta!.toJson(),
      'data': toJsonData(data),
    });

    try {
      if (storage == CacheStorage.file) {
        await _writeToFile(payload);
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(cacheKey, payload);
      }
    } catch (e) {
      debugPrint('[OfflineCache:$cacheKey] Save error: $e');
    }
  }

  /// Load data from cache. Returns null if no cache or expired.
  Future<T?> load({bool ignoreExpiry = false}) async {
    try {
      String? raw;
      if (storage == CacheStorage.file) {
        raw = await _readFromFile();
      } else {
        final prefs = await SharedPreferences.getInstance();
        raw = prefs.getString(cacheKey);
      }

      if (raw == null) return null;

      final decoded = jsonDecode(raw);
      _meta = CacheMeta.fromJson(decoded['meta']);

      if (!ignoreExpiry && _meta!.isExpired) {
        debugPrint('[OfflineCache:$cacheKey] Cache expired');
        // Still return data but caller can check isExpired
      }

      return fromJsonData(decoded['data']);
    } catch (e) {
      debugPrint('[OfflineCache:$cacheKey] Load error: $e');
      return null;
    }
  }

  /// Clear cached data.
  Future<void> clear() async {
    _meta = null;
    try {
      if (storage == CacheStorage.file) {
        final file = await _cacheFile;
        if (await file.exists()) {
          await file.delete();
        }
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(cacheKey);
      }
    } catch (e) {
      debugPrint('[OfflineCache:$cacheKey] Clear error: $e');
    }
  }

  // File-based storage helpers
  Future<File> get _cacheFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/cache_$cacheKey.json');
  }

  Future<void> _writeToFile(String data) async {
    final file = await _cacheFile;
    // Atomic write: write to temp file, then rename to prevent corruption on concurrent access
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(data);
    await tempFile.rename(file.path);
  }

  Future<String?> _readFromFile() async {
    final file = await _cacheFile;
    if (await file.exists()) {
      return await file.readAsString();
    }
    return null;
  }
}

// ============================================================
// Concrete cache implementations
// ============================================================

/// Cache for net stock data (TTL: 1 hour).
class StockCache extends OfflineCache<Map<String, dynamic>> {
  StockCache()
      : super(
          cacheKey: 'offline_stock',
          defaultExpiry: const Duration(hours: 1),
        );

  @override
  dynamic toJsonData(Map<String, dynamic> data) => data;

  @override
  Map<String, dynamic> fromJsonData(dynamic json) =>
      Map<String, dynamic>.from(json);
}

/// Cache for order list (TTL: 2 hours, file-based for large datasets).
class OrderCache extends OfflineCache<List<dynamic>> {
  OrderCache()
      : super(
          cacheKey: 'offline_orders',
          defaultExpiry: const Duration(hours: 2),
          storage: CacheStorage.file,
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for today's daily cart (TTL: 2 hours).
class DailyCartCache extends OfflineCache<Map<String, dynamic>> {
  DailyCartCache()
      : super(
          cacheKey: 'offline_daily_cart',
          defaultExpiry: const Duration(hours: 2),
        );

  @override
  dynamic toJsonData(Map<String, dynamic> data) => data;

  @override
  Map<String, dynamic> fromJsonData(dynamic json) =>
      Map<String, dynamic>.from(json);
}

/// Cache for task lists (TTL: 4 hours).
class TaskCache extends OfflineCache<List<dynamic>> {
  TaskCache()
      : super(
          cacheKey: 'offline_tasks',
          defaultExpiry: const Duration(hours: 4),
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for attendance data (TTL: 2 hours).
class AttendanceDataCache extends OfflineCache<Map<String, dynamic>> {
  AttendanceDataCache()
      : super(
          cacheKey: 'offline_attendance',
          defaultExpiry: const Duration(hours: 2),
        );

  @override
  dynamic toJsonData(Map<String, dynamic> data) => data;

  @override
  Map<String, dynamic> fromJsonData(dynamic json) =>
      Map<String, dynamic>.from(json);
}

/// Cache for dashboard summary data (TTL: 1 hour).
class DashboardCache extends OfflineCache<Map<String, dynamic>> {
  DashboardCache()
      : super(
          cacheKey: 'offline_dashboard',
          defaultExpiry: const Duration(hours: 1),
        );

  @override
  dynamic toJsonData(Map<String, dynamic> data) => data;

  @override
  Map<String, dynamic> fromJsonData(dynamic json) =>
      Map<String, dynamic>.from(json);
}

/// Cache for dropdown options (TTL: 7 days).
class DropdownCache extends OfflineCache<Map<String, dynamic>> {
  DropdownCache()
      : super(
          cacheKey: 'offline_dropdowns',
          defaultExpiry: const Duration(days: 7),
        );

  @override
  dynamic toJsonData(Map<String, dynamic> data) => data;

  @override
  Map<String, dynamic> fromJsonData(dynamic json) =>
      Map<String, dynamic>.from(json);
}

// ============================================================
// New caches for offline-first sync
// ============================================================

/// Cache for client contacts (TTL: 24h, file-based).
class ClientContactsCache extends OfflineCache<List<dynamic>> {
  ClientContactsCache()
      : super(
          cacheKey: 'offline_client_contacts',
          defaultExpiry: const Duration(hours: 24),
          storage: CacheStorage.file,
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for outstanding payments data (TTL: 7 days, file-based).
class OutstandingCache extends OfflineCache<Map<String, dynamic>> {
  OutstandingCache()
      : super(
          cacheKey: 'offline_outstanding',
          defaultExpiry: const Duration(days: 7),
          storage: CacheStorage.file,
        );

  @override
  dynamic toJsonData(Map<String, dynamic> data) => data;

  @override
  Map<String, dynamic> fromJsonData(dynamic json) =>
      Map<String, dynamic>.from(json);
}

/// Cache for workers list (TTL: 24h).
class WorkersCache extends OfflineCache<List<dynamic>> {
  WorkersCache()
      : super(
          cacheKey: 'offline_workers',
          defaultExpiry: const Duration(hours: 24),
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for expense sheets (TTL: 12h, file-based).
class ExpensesCache extends OfflineCache<List<dynamic>> {
  ExpensesCache()
      : super(
          cacheKey: 'offline_expenses',
          defaultExpiry: const Duration(hours: 12),
          storage: CacheStorage.file,
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for gate passes (TTL: 12h, file-based).
class GatePassesCache extends OfflineCache<List<dynamic>> {
  GatePassesCache()
      : super(
          cacheKey: 'offline_gate_passes',
          defaultExpiry: const Duration(hours: 12),
          storage: CacheStorage.file,
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for dispatch documents (TTL: 24h, file-based).
class DispatchDocsCache extends OfflineCache<List<dynamic>> {
  DispatchDocsCache()
      : super(
          cacheKey: 'offline_dispatch_docs',
          defaultExpiry: const Duration(hours: 24),
          storage: CacheStorage.file,
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for approval requests (TTL: 4h).
class ApprovalRequestsCache extends OfflineCache<List<dynamic>> {
  ApprovalRequestsCache()
      : super(
          cacheKey: 'offline_approval_requests',
          defaultExpiry: const Duration(hours: 4),
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for sales summary (TTL: 2h).
class SalesSummaryCache extends OfflineCache<Map<String, dynamic>> {
  SalesSummaryCache()
      : super(
          cacheKey: 'offline_sales_summary',
          defaultExpiry: const Duration(hours: 2),
        );

  @override
  dynamic toJsonData(Map<String, dynamic> data) => data;

  @override
  Map<String, dynamic> fromJsonData(dynamic json) =>
      Map<String, dynamic>.from(json);
}

/// Cache for ledger clients (TTL: 2h).
class LedgerCache extends OfflineCache<List<dynamic>> {
  LedgerCache()
      : super(
          cacheKey: 'offline_ledger',
          defaultExpiry: const Duration(hours: 2),
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}

/// Cache for pending orders (TTL: 2h).
class PendingOrdersCache extends OfflineCache<List<dynamic>> {
  PendingOrdersCache()
      : super(
          cacheKey: 'offline_pending_orders',
          defaultExpiry: const Duration(hours: 2),
        );

  @override
  dynamic toJsonData(List<dynamic> data) => data;

  @override
  List<dynamic> fromJsonData(dynamic json) => List<dynamic>.from(json);
}
