import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart';
import '../../../services/api_service.dart';
import '../../../services/analytics_service.dart';
import '../../../services/persistence_service.dart';
import '../../../models/task.dart';

/// ChangeNotifier managing all dashboard data state.
///
/// This controller centralizes the data-fetching, caching, and state
/// that was previously spread across _AdminDashboardState fields and methods.
class DashboardDataController extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  final AnalyticsService _analyticsService = AnalyticsService();
  final PersistenceService _persistenceService = PersistenceService();

  // Core state
  bool isLoading = true;
  Map<String, dynamic>? dashboardData;
  List<dynamic> pendingOrders = [];
  List<dynamic> todayCart = [];

  // Analytics state
  List<StockForecast> stockForecasts = [];
  List<Insight> insights = [];
  List<ClientScore> clientScores = [];
  List<DemandTrend> demandTrends = [];

  // Sync state
  DateTime? lastSync;
  bool isOffline = false;

  // Previous values for animated counters
  num previousSalesValue = 0;
  num previousStockValue = 0;
  num previousPendingValue = 0;

  // Revenue milestones
  int lastMilestoneReached = 0;
  DateTime lastSyncTime = DateTime.now();

  // Intent detection
  int pendingViewCount = 0;

  // Filters
  String billingFilter = 'all';
  final Set<int> selectedPackingIndices = {};
  final Set<int> selectedUrgencyIndices = {};
  DateTime selectedDate = DateTime.now();

  // User tasks
  List<Task> userTasks = [];
  bool hasNewTasks = false;
  int lastSeenTaskCount = 0;

  // FAB positions
  Offset fabPosition = const Offset(20, 100);
  Offset arcFabPosition = const Offset(300, 600);
  bool isArcExpanded = false;

  /// Load cached data from persistence layer.
  Future<void> loadCache() async {
    final cachedData = await _persistenceService.getDashboardData();
    final cachedAnalytics = await _persistenceService.getAnalyticsData();
    final cachedLastSync = await _persistenceService.getLastSyncTime();

    if (cachedData != null) {
      dashboardData = cachedData['dashboard'];
      pendingOrders = cachedData['pendingOrders'] ?? [];
      todayCart = cachedData['todayCart'] ?? [];
      lastSync = cachedLastSync;
      isLoading = false;
      notifyListeners();
    }

    if (cachedAnalytics != null) {
      stockForecasts = (cachedAnalytics['forecasts'] as List? ?? []).map((e) => StockForecast.fromJson(e)).toList();
      insights = (cachedAnalytics['insights'] as List? ?? []).map((e) => Insight.fromJson(e)).toList();
      clientScores = (cachedAnalytics['clients'] as List? ?? []).map((e) => ClientScore.fromJson(e)).toList();
      demandTrends = (cachedAnalytics['trends'] as List? ?? []).map((e) => DemandTrend.fromJson(e)).toList();
      notifyListeners();
    }
  }

  /// Fetch fresh data from API and update cache.
  Future<void> loadData() async {
    try {
      final dataResp = await _apiService.getDashboard();
      final pendingResp = await _apiService.getPendingOrders();
      final cartResp = await _apiService.getTodayCart();

      final data = dataResp.data is Map<String, dynamic> ? dataResp.data as Map<String, dynamic> : <String, dynamic>{};
      final pending = pendingResp.data is List ? pendingResp.data as List<dynamic> : <dynamic>[];
      final cart = cartResp.data is List ? cartResp.data as List<dynamic> : <dynamic>[];

      // Store previous values before updating
      if (dashboardData != null) {
        final sales = dashboardData!['todaySalesVal'];
        previousSalesValue = sales is num ? sales : (num.tryParse('$sales') ?? 0);
        final stock = dashboardData!['totalStock'];
        previousStockValue = stock is num ? stock : (num.tryParse('$stock') ?? 0);
        final pend = dashboardData!['pendingQty'];
        previousPendingValue = pend is num ? pend : (num.tryParse('$pend') ?? 0);
      }

      dashboardData = data;
      pendingOrders = pending;
      todayCart = cart;
      isLoading = false;
      isOffline = false;
      lastSync = DateTime.now();
      lastSyncTime = DateTime.now();

      // Persist data
      await _persistenceService.saveDashboardData({
        'dashboard': data,
        'pendingOrders': pending,
        'todayCart': cart,
      });

      // Check revenue milestones
      _checkMilestones();

      notifyListeners();
    } catch (e) {
      if (isLoading && dashboardData == null) {
        isOffline = true;
        isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Load analytics data (forecasts, insights, etc.).
  Future<void> loadAnalytics() async {
    try {
      final forecastResult = await _analyticsService.getStockForecast();
      final insightResult = await _analyticsService.getProactiveInsights();
      final clientResult = await _analyticsService.getClientScores();
      final trendResult = await _analyticsService.getDemandTrends();

      stockForecasts = forecastResult.forecasts;
      insights = insightResult.insights;
      clientScores = clientResult.clients;
      demandTrends = trendResult.trends;

      // Cache analytics
      await _persistenceService.saveAnalyticsData({
        'forecasts': stockForecasts.map((e) => e.toJson()).toList(),
        'insights': insights.map((e) => e.toJson()).toList(),
        'clients': clientScores.map((e) => e.toJson()).toList(),
        'trends': demandTrends.map((e) => e.toJson()).toList(),
      });

      notifyListeners();
    } catch (_) {
      // Analytics are non-critical; fail silently
    }
  }

  /// Load user tasks from API.
  Future<void> loadUserTasks() async {
    try {
      final response = await _apiService.getTasks();
      // Handle paginated response: { data: [...], pagination: {...} }
      final resData = response.data;
      final tasks = resData is List ? resData as List : (resData is Map ? (resData['data'] ?? resData['tasks'] ?? []) as List : []);
      final newTasks = tasks.map((t) => Task.fromJson(t as Map<String, dynamic>)).toList();

      if (newTasks.length > lastSeenTaskCount) {
        hasNewTasks = true;
      }

      userTasks = newTasks;
      notifyListeners();
    } catch (_) {
      // Task loading is non-critical
    }
  }

  /// Mark tasks as seen (clear notification badge).
  void markTasksAsSeen() {
    lastSeenTaskCount = userTasks.length;
    hasNewTasks = false;
    notifyListeners();
  }

  /// Record a pending order view for intent detection.
  void onPendingViewed() {
    pendingViewCount++;
    notifyListeners();
  }

  /// Toggle the arc FAB expansion state.
  void toggleArcExpanded() {
    isArcExpanded = !isArcExpanded;
    notifyListeners();
  }

  /// Update FAB position after drag.
  void updateFabPosition(Offset position) {
    fabPosition = position;
    notifyListeners();
  }

  /// Update arc FAB position after drag.
  void updateArcFabPosition(Offset position) {
    arcFabPosition = position;
    notifyListeners();
  }

  /// Helper: get hours elapsed since 8am.
  double getHoursElapsed() {
    final now = DateTime.now();
    final hour = now.hour;
    if (hour < 8) return 0.5;
    if (hour >= 20) return 12;
    return (hour - 8) + (now.minute / 60);
  }

  void _checkMilestones() {
    if (dashboardData == null) return;
    final sales = dashboardData!['todaySalesVal'];
    final salesNum = sales is num ? sales : (num.tryParse('$sales') ?? 0);
    final milestone = (salesNum / 100000).floor();
    if (milestone > lastMilestoneReached) {
      lastMilestoneReached = milestone;
      // Milestone reached - UI layer can show celebration
    }
  }
}
