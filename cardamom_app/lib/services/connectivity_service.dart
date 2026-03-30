import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'api_service.dart';

/// Centralized connectivity monitoring service.
///
/// Wraps `connectivity_plus` and adds a reachability check (HTTP HEAD to backend)
/// to detect captive portals and actual server reachability.
/// Exposes [isOnline], [connectionType], and [lastChecked] as observable state.
class ConnectivityService extends ChangeNotifier {
  bool _isOnline = true;
  ConnectivityResult _connectionType = ConnectivityResult.none;
  DateTime? _lastChecked;
  DateTime? _lastSyncTime;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _periodicCheck;

  // Primary health URL (ICP canister)
  // Production: update canister ID after mainnet deploy
  static const String _primaryHealthUrl = 'https://ge6oz-5qaaa-aaaaj-qrraq-cai.raw.icp0.io/api/health';
  // Fallback health URL (local development)
  static const String _fallbackHealthUrl = 'http://localhost:4943/api/health';

  // Reuse a single Dio instance for health checks to avoid resource leaks
  late final Dio _healthDio;

  ConnectivityService() {
    _healthDio = Dio()
      ..options.connectTimeout = const Duration(seconds: 5)
      ..options.receiveTimeout = const Duration(seconds: 5);
    // Allow self-signed cert for fallback IP health checks
    if (!kIsWeb) {
      (_healthDio.httpClientAdapter as IOHttpClientAdapter).createHttpClient =
          () {
        final client = HttpClient();
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) {
          return host == '216.24.57.7';
        };
        return client;
      };
    }
  }

  // Public getters
  bool get isOnline => _isOnline;
  ConnectivityResult get connectionType => _connectionType;
  DateTime? get lastChecked => _lastChecked;
  DateTime? get lastSyncTime => _lastSyncTime;

  /// Human-readable string for how long ago last sync happened.
  String get lastSyncAgo {
    final sync = _lastSyncTime;
    if (sync == null) return 'Never synced';
    final diff = DateTime.now().difference(sync);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Initialize the service. Call once during app startup.
  Future<void> initialize() async {
    // Initial connectivity check
    await _performConnectivityCheck();

    // Listen for platform connectivity changes
    try {
      _subscription = Connectivity().onConnectivityChanged.listen((results) {
        final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
        _handleConnectivityChange(result);
      });
    } catch (e) {
      debugPrint('[ConnectivityService] Listener setup failed: $e');
    }

    // Periodic reachability check every 30 seconds when online, 10 seconds when offline
    _startPeriodicCheck();
  }

  void _startPeriodicCheck() {
    _periodicCheck?.cancel();
    final interval = _isOnline ? const Duration(seconds: 30) : const Duration(seconds: 10);
    _periodicCheck = Timer.periodic(interval, (_) => _performConnectivityCheck());
  }

  Future<void> _handleConnectivityChange(ConnectivityResult result) async {
    _connectionType = result;
    if (result == ConnectivityResult.none) {
      _setOffline();
    } else {
      // Platform says connected, but verify with reachability check
      await _performReachabilityCheck();
    }
  }

  /// Full connectivity check: platform + reachability.
  Future<void> _performConnectivityCheck() async {
    try {
      final results = await Connectivity().checkConnectivity();
      final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
      _connectionType = result;

      if (result == ConnectivityResult.none) {
        _setOffline();
        return;
      }

      await _performReachabilityCheck();
    } catch (e) {
      debugPrint('[ConnectivityService] Check failed: $e');
      // On error, keep current state rather than flip-flopping
    }
  }

  /// HTTP HEAD reachability check to backend.
  /// Tries primary cloud URL first; on DNS failure, tries fallback IP.
  Future<void> _performReachabilityCheck() async {
    // Try primary URL first
    if (await _tryHealthCheck(_primaryHealthUrl)) return;

    // DNS likely failed — try fallback IP (fixes home WiFi DNS issue)
    debugPrint('[ConnectivityService] Primary health check failed, trying fallback IP...');
    if (await _tryHealthCheck(_fallbackHealthUrl)) {
      // Fallback worked — also trigger ApiService DNS fallback so API calls work
      ApiService.activateFallback();
      return;
    }

    // Both failed — truly offline
    _setOffline();
    _lastChecked = DateTime.now();
  }

  /// Single health check attempt. Returns true if server is reachable.
  Future<bool> _tryHealthCheck(String url, {String? hostHeader}) async {
    try {
      final options = Options(headers: hostHeader != null ? {'Host': hostHeader} : null);
      final response = await _healthDio.head(url, options: options);
      if (response.statusCode != null && response.statusCode! < 500) {
        _setOnline();
        _lastChecked = DateTime.now();
        return true;
      }
      // 5xx: server overloaded — keep current state
      debugPrint('[ConnectivityService] Server returned ${response.statusCode} — keeping current state');
      _lastChecked = DateTime.now();
      return true; // Server is reachable, just overloaded
    } on DioException catch (e) {
      if (e.response?.statusCode != null && e.response!.statusCode! >= 500) {
        debugPrint('[ConnectivityService] Server ${e.response?.statusCode} — keeping current state');
        _lastChecked = DateTime.now();
        return true; // Reachable but erroring
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  void _setOnline() {
    final wasOffline = !_isOnline;
    _isOnline = true;
    if (wasOffline) {
      _lastSyncTime = DateTime.now();
      debugPrint('[ConnectivityService] Back online');
      _startPeriodicCheck(); // Adjust interval
      notifyListeners(); // Only notify when state actually changed
    }
  }

  void _setOffline() {
    final wasOnline = _isOnline;
    _isOnline = false;
    if (wasOnline) {
      debugPrint('[ConnectivityService] Gone offline');
      _startPeriodicCheck(); // Adjust interval
      notifyListeners(); // Only notify when state actually changed
    }
  }

  /// Record a successful sync timestamp (called by CacheManager after data refresh).
  void recordSync() {
    _lastSyncTime = DateTime.now();
    notifyListeners();
  }

  /// Force a connectivity recheck (useful for pull-to-refresh).
  Future<void> forceCheck() async {
    await _performConnectivityCheck();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _periodicCheck?.cancel();
    _healthDio.close();
    super.dispose();
  }
}
