import 'package:dio/dio.dart';
import 'api_service.dart';

/// Analytics Service - Phase 3 Intelligence Features
/// 
/// Provides access to:
/// - Stock Depletion Forecast (3.1)
/// - Client Behavior Scoring (3.2)
/// - Proactive Insights (3.3)
class AnalyticsService {
  final ApiService _apiService;
  late final Dio _dio;

  AnalyticsService({ApiService? apiService}) : _apiService = apiService ?? ApiService() {
    // Reuse ApiService's authenticated Dio-like pattern
    _dio = Dio();
    _dio.options.baseUrl = ApiService.baseUrl;
    _dio.options.connectTimeout = const Duration(seconds: 30);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
    // Add auth interceptor so analytics requests are authenticated
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        options.baseUrl = ApiService.baseUrl;
        final token = _apiService.getAuthToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        return handler.next(options);
      },
    ));
  }

  /// Extracts a user-friendly error message from Dio errors.
  String _friendlyError(Object e) {
    if (e is DioException) {
      if (e.response?.statusCode == 401) return 'Authentication required. Please log in again.';
      if (e.response?.statusCode == 403) return 'Access denied. Superadmin role required.';
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return 'Request timed out. Check your connection.';
      }
      if (e.type == DioExceptionType.connectionError) {
        return 'Connection failed. Check your network.';
      }
    }
    return 'Request failed. Please try again.';
  }

  /// Get stock depletion forecasts for all grades
  Future<StockForecastResult> getStockForecast() async {
    try {
      final response = await _dio.get('/analytics/stock-forecast');
      return StockForecastResult.fromJson(response.data);
    } catch (e) {
      return StockForecastResult(
        success: false,
        error: _friendlyError(e),
        forecasts: [],
      );
    }
  }

  /// Get client behavior scores
  Future<ClientScoresResult> getClientScores() async {
    try {
      final response = await _dio.get('/analytics/client-scores');
      return ClientScoresResult.fromJson(response.data);
    } catch (e) {
      return ClientScoresResult(
        success: false,
        error: _friendlyError(e),
        clients: [],
      );
    }
  }

  /// Get proactive insights
  Future<InsightsResult> getProactiveInsights() async {
    try {
      final response = await _dio.get('/analytics/insights');
      return InsightsResult.fromJson(response.data);
    } catch (e) {
      return InsightsResult(
        success: false,
        error: _friendlyError(e),
        insights: [],
      );
    }
  }

  /// Get demand trends
  Future<DemandTrendResult> getDemandTrends() async {
    try {
      final response = await _dio.get('/analytics/demand-trends');
      return DemandTrendResult.fromJson(response.data);
    } catch (e) {
      return DemandTrendResult(
        success: false,
        error: _friendlyError(e),
        trends: [],
      );
    }
  }

  /// Get seasonal analysis
  Future<Map<String, dynamic>> getSeasonalAnalysis() async {
    try {
      final response = await _dio.get('/analytics/seasonal-analysis');
      return response.data;
    } catch (e) {
      return {'success': false, 'error': _friendlyError(e)};
    }
  }

  /// Get audit logs - Phase 4.3
  Future<List<AuditLog>> getAuditLogs({int limit = 50}) async {
    try {
      final response = await _dio.get('/analytics/audit-logs', queryParameters: {'limit': limit});
      if (response.data['success'] == true) {
        final List<dynamic> logsData = response.data['logs'] ?? [];
        return logsData.map((json) => AuditLog.fromJson(json)).toList();
      }
      return [];
    } catch (e) {
      throw Exception('Failed to load audit logs: $e');
    }
  }

  /// Get paginated audit logs with cursor-based pagination.
  /// Returns both the logs and pagination metadata.
  Future<AuditLogPaginatedResult> getAuditLogsPaginated({int limit = 25, String? cursor}) async {
    try {
      final params = <String, dynamic>{'limit': limit};
      if (cursor != null) params['cursor'] = cursor;
      final response = await _dio.get('/analytics/audit-logs', queryParameters: params);
      if (response.data['success'] == true) {
        final List<dynamic> logsData = response.data['logs'] ?? [];
        final pagination = response.data['pagination'] as Map<String, dynamic>? ?? {};
        return AuditLogPaginatedResult(
          logs: logsData.map((json) => AuditLog.fromJson(json)).toList(),
          cursor: pagination['cursor'] as String?,
          hasMore: pagination['hasMore'] as bool? ?? false,
          limit: pagination['limit'] as int? ?? limit,
        );
      }
      return AuditLogPaginatedResult(logs: [], cursor: null, hasMore: false, limit: limit);
    } catch (e) {
      throw Exception('Failed to load audit logs: $e');
    }
  }

  /// Get suggested prices - Phase 4.2 (cached for 5 minutes)
  static List<SuggestedPrice>? _priceCache;
  static DateTime? _priceCacheTime;
  static const _priceCacheTtl = Duration(minutes: 5);

  /// #76: Clear static cache on logout to prevent stale data across sessions
  static void clearCache() {
    _priceCache = null;
    _priceCacheTime = null;
  }

  Future<List<SuggestedPrice>> getSuggestedPrices() async {
    // Return cached data if within TTL
    if (_priceCache != null && _priceCacheTime != null &&
        DateTime.now().difference(_priceCacheTime!) < _priceCacheTtl) {
      return _priceCache!;
    }

    try {
      final response = await _dio.get('/analytics/suggested-prices');
      if (response.data['success'] == true) {
        final List<dynamic> suggestionsData = response.data['suggestions'] ?? [];
        _priceCache = suggestionsData.map((json) => SuggestedPrice.fromJson(json)).toList();
        _priceCacheTime = DateTime.now();
        return _priceCache!;
      }
      return [];
    } catch (e) {
      // Return stale cache on error if available
      if (_priceCache != null) return _priceCache!;
      throw Exception('Failed to load suggested prices: $e');
    }
  }
}

// Data Models

class StockForecast {
  final String grade;
  final int currentStock;
  final double dailyRate;
  final int weeklyDispatch;
  final int? daysUntilDepletion;
  final String urgency; // critical, warning, healthy, slow
  final List<String> substitutions;

  StockForecast({
    required this.grade,
    required this.currentStock,
    required this.dailyRate,
    required this.weeklyDispatch,
    this.daysUntilDepletion,
    required this.urgency,
    required this.substitutions,
  });

  factory StockForecast.fromJson(Map<String, dynamic> json) {
    return StockForecast(
      grade: json['grade'] ?? '',
      currentStock: json['currentStock'] ?? 0,
      dailyRate: (json['dailyRate'] ?? 0).toDouble(),
      weeklyDispatch: json['weeklyDispatch'] ?? 0,
      daysUntilDepletion: json['daysUntilDepletion'],
      urgency: json['urgency'] ?? 'healthy',
      substitutions: List<String>.from(json['substitutions'] ?? []),
    );
  }

  Map<String, dynamic> toJson() => {
    'grade': grade,
    'currentStock': currentStock,
    'dailyRate': dailyRate,
    'weeklyDispatch': weeklyDispatch,
    'daysUntilDepletion': daysUntilDepletion,
    'urgency': urgency,
    'substitutions': substitutions,
  };
}

class StockForecastResult {
  final bool success;
  final String? error;
  final List<StockForecast> forecasts;
  final int criticalCount;
  final int warningCount;
  final int healthyCount;
  final int slowCount;

  StockForecastResult({
    required this.success,
    this.error,
    required this.forecasts,
    this.criticalCount = 0,
    this.warningCount = 0,
    this.healthyCount = 0,
    this.slowCount = 0,
  });

  factory StockForecastResult.fromJson(Map<String, dynamic> json) {
    final forecastsList = (json['forecasts'] as List? ?? [])
        .map((f) => StockForecast.fromJson(f))
        .toList();
    final summary = json['summary'] ?? {};

    return StockForecastResult(
      success: json['success'] ?? false,
      error: json['error'],
      forecasts: forecastsList,
      criticalCount: summary['criticalCount'] ?? 0,
      warningCount: summary['warningCount'] ?? 0,
      healthyCount: summary['healthyCount'] ?? 0,
      slowCount: summary['slowCount'] ?? 0,
    );
  }
}

class ClientScore {
  final String name;
  final int velocityScore;
  final int orderCount;
  final int totalValue;
  final int avgOrderValue;
  final int daysSinceLastOrder;
  final String churnRisk; // low, medium, high
  final List<GradeAffinity> topGrades;

  ClientScore({
    required this.name,
    required this.velocityScore,
    required this.orderCount,
    required this.totalValue,
    required this.avgOrderValue,
    required this.daysSinceLastOrder,
    required this.churnRisk,
    required this.topGrades,
  });

  factory ClientScore.fromJson(Map<String, dynamic> json) {
    return ClientScore(
      name: json['name'] ?? '',
      velocityScore: json['velocityScore'] ?? 0,
      orderCount: json['orderCount'] ?? 0,
      totalValue: json['totalValue'] ?? 0,
      avgOrderValue: json['avgOrderValue'] ?? 0,
      daysSinceLastOrder: json['daysSinceLastOrder'] ?? 999,
      churnRisk: json['churnRisk'] ?? 'low',
      topGrades: (json['topGrades'] as List? ?? [])
          .map((g) => GradeAffinity.fromJson(g))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'velocityScore': velocityScore,
    'orderCount': orderCount,
    'totalValue': totalValue,
    'avgOrderValue': avgOrderValue,
    'daysSinceLastOrder': daysSinceLastOrder,
    'churnRisk': churnRisk,
    'topGrades': topGrades.map((e) => e.toJson()).toList(),
  };
}

class GradeAffinity {
  final String grade;
  final int kgs;

  GradeAffinity({required this.grade, required this.kgs});

  factory GradeAffinity.fromJson(Map<String, dynamic> json) {
    return GradeAffinity(
      grade: json['grade'] ?? '',
      kgs: json['kgs'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'grade': grade,
    'kgs': kgs,
  };
}

class ClientScoresResult {
  final bool success;
  final String? error;
  final List<ClientScore> clients;
  final int totalClients;
  final int highChurnRisk;
  final int mediumChurnRisk;

  ClientScoresResult({
    required this.success,
    this.error,
    required this.clients,
    this.totalClients = 0,
    this.highChurnRisk = 0,
    this.mediumChurnRisk = 0,
  });

  factory ClientScoresResult.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'] ?? {};
    return ClientScoresResult(
      success: json['success'] ?? false,
      error: json['error'],
      clients: (json['clients'] as List? ?? [])
          .map((c) => ClientScore.fromJson(c))
          .toList(),
      totalClients: summary['totalClients'] ?? 0,
      highChurnRisk: summary['highChurnRisk'] ?? 0,
      mediumChurnRisk: summary['mediumChurnRisk'] ?? 0,
    );
  }
}

class Insight {
  final String type; // dispatch_opportunity, low_stock, high_performer, unused_inventory
  final String priority; // critical, high, medium, low
  final String icon;
  final String title;
  final String description;
  final String? grade;
  final String? client;
  final String? action;
  final int? value;
  final List<String>? substitutions;

  Insight({
    required this.type,
    required this.priority,
    required this.icon,
    required this.title,
    required this.description,
    this.grade,
    this.client,
    this.action,
    this.value,
    this.substitutions,
  });

  factory Insight.fromJson(Map<String, dynamic> json) {
    return Insight(
      type: json['type'] ?? '',
      priority: json['priority'] ?? 'low',
      icon: json['icon'] ?? '💡',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      grade: json['grade'],
      client: json['client'],
      action: json['action'],
      value: json['value'],
      substitutions: json['substitutions'] != null
          ? List<String>.from(json['substitutions'])
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'priority': priority,
    'icon': icon,
    'title': title,
    'description': description,
    'grade': grade,
    'client': client,
    'action': action,
    'value': value,
    'substitutions': substitutions,
  };
}

class InsightsResult {
  final bool success;
  final String? error;
  final List<Insight> insights;
  final int totalInsights;
  final int criticalCount;
  final int totalPendingValue;

  InsightsResult({
    required this.success,
    this.error,
    required this.insights,
    this.totalInsights = 0,
    this.criticalCount = 0,
    this.totalPendingValue = 0,
  });

  factory InsightsResult.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'] ?? {};
    return InsightsResult(
      success: json['success'] ?? false,
      error: json['error'],
      insights: (json['insights'] as List? ?? [])
          .map((i) => Insight.fromJson(i))
          .toList(),
      totalInsights: summary['totalInsights'] ?? 0,
      criticalCount: summary['criticalCount'] ?? 0,
      totalPendingValue: summary['totalPendingValue'] ?? 0,
    );
  }
}

class DemandTrend {
  final String grade;
  final int avgWeeklyVolume;
  final int recentVolume;
  final int percentageChange;
  final String momentum; // rising, falling, stable
  final int projectedNextWeek;

  DemandTrend({
    required this.grade,
    required this.avgWeeklyVolume,
    required this.recentVolume,
    required this.percentageChange,
    required this.momentum,
    required this.projectedNextWeek,
  });

  factory DemandTrend.fromJson(Map<String, dynamic> json) {
    return DemandTrend(
      grade: json['grade'] ?? '',
      avgWeeklyVolume: json['avgWeeklyVolume'] ?? 0,
      recentVolume: json['recentVolume'] ?? 0,
      percentageChange: json['percentageChange'] ?? 0,
      momentum: json['momentum'] ?? 'stable',
      projectedNextWeek: json['projectedNextWeek'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'grade': grade,
    'avgWeeklyVolume': avgWeeklyVolume,
    'recentVolume': recentVolume,
    'percentageChange': percentageChange,
    'momentum': momentum,
    'projectedNextWeek': projectedNextWeek,
  };
}

class DemandTrendResult {
  final bool success;
  final String? error;
  final List<DemandTrend> trends;
  final int periodDays;

  DemandTrendResult({
    required this.success,
    this.error,
    required this.trends,
    this.periodDays = 90,
  });

  factory DemandTrendResult.fromJson(Map<String, dynamic> json) {
    return DemandTrendResult(
      success: json['success'] ?? false,
      error: json['error'],
      trends: (json['trends'] as List? ?? [])
          .map((t) => DemandTrend.fromJson(t))
          .toList(),
      periodDays: json['periodDays'] ?? 90,
    );
  }
}

class AuditLog {
  final String timestamp;
  final String user;
  final String action;
  final String target;
  final Map<String, dynamic> details;

  AuditLog({
    required this.timestamp,
    required this.user,
    required this.action,
    required this.target,
    required this.details,
  });

  factory AuditLog.fromJson(Map<String, dynamic> json) {
    return AuditLog(
      timestamp: json['timestamp'] ?? '',
      user: json['user'] ?? '',
      action: json['action'] ?? '',
      target: json['target'] ?? '',
      details: json['details'] ?? {},
    );
  }
}

class SuggestedPrice {
  final String grade;
  final int currentPrice;
  final int suggestedPrice;
  final int adjustmentPercent;
  final List<String> reasons;
  final String momentum;
  final int stockLevel;

  SuggestedPrice({
    required this.grade,
    required this.currentPrice,
    required this.suggestedPrice,
    required this.adjustmentPercent,
    required this.reasons,
    required this.momentum,
    required this.stockLevel,
  });

  factory SuggestedPrice.fromJson(Map<String, dynamic> json) {
    return SuggestedPrice(
      grade: json['grade'] ?? '',
      currentPrice: json['currentPrice'] ?? 0,
      suggestedPrice: json['suggestedPrice'] ?? 0,
      adjustmentPercent: json['adjustmentPercent'] ?? 0,
      reasons: List<String>.from(json['reasons'] ?? []),
      momentum: json['momentum'] ?? 'stable',
      stockLevel: json['stockLevel'] ?? 0,
    );
  }
}

/// Paginated audit log result with cursor metadata.
class AuditLogPaginatedResult {
  final List<AuditLog> logs;
  final String? cursor;
  final bool hasMore;
  final int limit;

  AuditLogPaginatedResult({
    required this.logs,
    this.cursor,
    this.hasMore = false,
    this.limit = 25,
  });
}
