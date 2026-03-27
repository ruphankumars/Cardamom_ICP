import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistence Service - Phase 4.4 Offline Mode
/// Handles local caching of dashboard and analytics data
class PersistenceService {
  static const String keyDashboardData = 'cached_dashboard_data';
  static const String keyAnalyticsData = 'cached_analytics_data';
  static const String keyLastSync = 'last_sync_timestamp';

  /// Save dashboard data to local storage
  Future<void> saveDashboardData(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyDashboardData, jsonEncode(data));
    await prefs.setInt(keyLastSync, DateTime.now().millisecondsSinceEpoch);
  }

  /// Get cached dashboard data
  Future<Map<String, dynamic>?> getDashboardData() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString(keyDashboardData);
    if (data != null) {
      return jsonDecode(data);
    }
    return null;
  }

  /// Save analytics data (forecasts, insights, scores, trends)
  Future<void> saveAnalyticsData(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyAnalyticsData, jsonEncode(data));
  }

  /// Get cached analytics data
  Future<Map<String, dynamic>?> getAnalyticsData() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString(keyAnalyticsData);
    if (data != null) {
      return jsonDecode(data);
    }
    return null;
  }

  /// Get last sync time
  Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final int? timestamp = prefs.getInt(keyLastSync);
    if (timestamp != null) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    return null;
  }

  /// Clear all cache
  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyDashboardData);
    await prefs.remove(keyAnalyticsData);
    await prefs.remove(keyLastSync);
  }
}
