import 'api_service.dart';

/// AI Brain Service - Frontend access to intelligent decision engine
/// Uses ApiService for auth tokens, cert bypass, and DNS fallback.
class AiBrainService {
  final ApiService _api;

  AiBrainService({ApiService? apiService}) : _api = apiService ?? ApiService();

  /// Get Daily Intelligence Briefing
  Future<DailyBriefing> getDailyBriefing() async {
    try {
      final response = await _api.getAiDailyBriefing();
      return DailyBriefing.fromJson(response.data);
    } catch (e) {
      return DailyBriefing(success: false, error: e.toString());
    }
  }

  /// Get deep analysis for a specific grade
  Future<GradeAnalysis> getGradeAnalysis(String grade) async {
    try {
      final response = await _api.getAiGradeAnalysis(grade);
      return GradeAnalysis.fromJson(response.data);
    } catch (e) {
      return GradeAnalysis(success: false, error: e.toString());
    }
  }

  /// Get deep analysis for a specific client
  Future<ClientAnalysis> getClientAnalysis(String clientName) async {
    try {
      final response = await _api.getAiClientAnalysis(clientName);
      return ClientAnalysis.fromJson(response.data);
    } catch (e) {
      return ClientAnalysis(success: false, error: e.toString());
    }
  }

  /// Get all recommendations
  Future<Map<String, dynamic>> getAllRecommendations() async {
    try {
      final response = await _api.getAiRecommendations();
      return response.data;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }
}

// Data Models

class DailyBriefing {
  final bool success;
  final String? error;
  final String? date;
  final String? dayOfWeek;
  final List<AiAction> priorityActions;
  final List<AiPattern> todayPatterns;
  final List<AiPrediction> predictions;
  final List<AiOpportunity> opportunities;
  final BriefingSummary? summary;

  DailyBriefing({
    required this.success,
    this.error,
    this.date,
    this.dayOfWeek,
    this.priorityActions = const [],
    this.todayPatterns = const [],
    this.predictions = const [],
    this.opportunities = const [],
    this.summary,
  });

  factory DailyBriefing.fromJson(Map<String, dynamic> json) {
    return DailyBriefing(
      success: json['success'] ?? false,
      error: json['error'],
      date: json['date'],
      dayOfWeek: json['dayOfWeek'],
      priorityActions: (json['priorityActions'] as List? ?? [])
          .map((e) => AiAction.fromJson(e))
          .toList(),
      todayPatterns: (json['todayPatterns'] as List? ?? [])
          .map((e) => AiPattern.fromJson(e))
          .toList(),
      predictions: (json['predictions'] as List? ?? [])
          .map((e) => AiPrediction.fromJson(e))
          .toList(),
      opportunities: (json['opportunities'] as List? ?? [])
          .map((e) => AiOpportunity.fromJson(e))
          .toList(),
      summary: json['summary'] != null
          ? BriefingSummary.fromJson(json['summary'])
          : null,
    );
  }
}

class AiAction {
  final String type;
  final String icon;
  final String text;
  final String? grade;
  final String? client;
  final String priority;

  AiAction({
    required this.type,
    required this.icon,
    required this.text,
    this.grade,
    this.client,
    required this.priority,
  });

  factory AiAction.fromJson(Map<String, dynamic> json) {
    return AiAction(
      type: json['type'] ?? '',
      icon: json['icon'] ?? '📌',
      text: json['text'] ?? '',
      grade: json['grade'],
      client: json['client'],
      priority: json['priority'] ?? 'medium',
    );
  }
}

class AiPattern {
  final String icon;
  final String text;

  AiPattern({required this.icon, required this.text});

  factory AiPattern.fromJson(Map<String, dynamic> json) {
    return AiPattern(
      icon: json['icon'] ?? '📊',
      text: json['text'] ?? '',
    );
  }
}

class AiPrediction {
  final String icon;
  final String text;

  AiPrediction({required this.icon, required this.text});

  factory AiPrediction.fromJson(Map<String, dynamic> json) {
    return AiPrediction(
      icon: json['icon'] ?? '🔮',
      text: json['text'] ?? '',
    );
  }
}

class AiOpportunity {
  final String icon;
  final String text;
  final String? grade;
  final String? client;

  AiOpportunity({
    required this.icon,
    required this.text,
    this.grade,
    this.client,
  });

  factory AiOpportunity.fromJson(Map<String, dynamic> json) {
    return AiOpportunity(
      icon: json['icon'] ?? '💡',
      text: json['text'] ?? '',
      grade: json['grade'],
      client: json['client'],
    );
  }
}

class BriefingSummary {
  final int totalStock;
  final int totalPending;
  final int pendingValue;
  final int activeClients;
  final int criticalGrades;
  final int dispatchLast7Days;

  BriefingSummary({
    required this.totalStock,
    required this.totalPending,
    required this.pendingValue,
    required this.activeClients,
    required this.criticalGrades,
    required this.dispatchLast7Days,
  });

  factory BriefingSummary.fromJson(Map<String, dynamic> json) {
    return BriefingSummary(
      totalStock: (json['totalStock'] as num?)?.toInt() ?? 0,
      totalPending: (json['totalPending'] as num?)?.toInt() ?? 0,
      pendingValue: (json['pendingValue'] as num?)?.toInt() ?? 0,
      activeClients: (json['activeClients'] as num?)?.toInt() ?? 0,
      criticalGrades: (json['criticalGrades'] as num?)?.toInt() ?? 0,
      dispatchLast7Days: (json['dispatchLast7Days'] as num?)?.toInt() ?? 0,
    );
  }
}

class GradeAnalysis {
  final bool success;
  final String? error;
  final String? grade;
  final int? currentStock;
  final String? urgency;
  final int? daysUntilDepletion;
  final double? dailyRate;
  final List<AiRecommendation> recommendations;

  GradeAnalysis({
    required this.success,
    this.error,
    this.grade,
    this.currentStock,
    this.urgency,
    this.daysUntilDepletion,
    this.dailyRate,
    this.recommendations = const [],
  });

  factory GradeAnalysis.fromJson(Map<String, dynamic> json) {
    return GradeAnalysis(
      success: json['success'] ?? false,
      error: json['error'],
      grade: json['grade'],
      currentStock: (json['currentStock'] as num?)?.toInt(),
      urgency: json['urgency'],
      daysUntilDepletion: (json['daysUntilDepletion'] as num?)?.toInt(),
      dailyRate: (json['dailyRate'] as num?)?.toDouble() ?? 0.0,
      recommendations: (json['recommendations'] as List? ?? [])
          .map((e) => AiRecommendation.fromJson(e))
          .toList(),
    );
  }
}

class ClientAnalysis {
  final bool success;
  final String? error;
  final ClientInfo? client;
  final FinancialInfo? financial;
  final PatternInfo? patterns;
  final List<AiRecommendation> recommendations;

  ClientAnalysis({
    required this.success,
    this.error,
    this.client,
    this.financial,
    this.patterns,
    this.recommendations = const [],
  });

  factory ClientAnalysis.fromJson(Map<String, dynamic> json) {
    return ClientAnalysis(
      success: json['success'] ?? false,
      error: json['error'],
      client: json['client'] != null ? ClientInfo.fromJson(json['client']) : null,
      financial: json['financial'] != null ? FinancialInfo.fromJson(json['financial']) : null,
      patterns: json['patterns'] != null ? PatternInfo.fromJson(json['patterns']) : null,
      recommendations: (json['recommendations'] as List? ?? [])
          .map((e) => AiRecommendation.fromJson(e))
          .toList(),
    );
  }
}

class ClientInfo {
  final String name;
  final int score;
  final int rank;
  final int totalClients;
  final String churnRisk;

  ClientInfo({
    required this.name,
    required this.score,
    required this.rank,
    required this.totalClients,
    required this.churnRisk,
  });

  factory ClientInfo.fromJson(Map<String, dynamic> json) {
    return ClientInfo(
      name: json['name'] ?? '',
      score: (json['score'] as num?)?.toInt() ?? 0,
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      totalClients: (json['totalClients'] as num?)?.toInt() ?? 0,
      churnRisk: json['churnRisk'] ?? 'low',
    );
  }
}

class FinancialInfo {
  final int totalValue;
  final int avgOrderValue;
  final int orderCount;
  final int pendingValue;
  final int pendingOrders;

  FinancialInfo({
    required this.totalValue,
    required this.avgOrderValue,
    required this.orderCount,
    required this.pendingValue,
    required this.pendingOrders,
  });

  factory FinancialInfo.fromJson(Map<String, dynamic> json) {
    return FinancialInfo(
      totalValue: (json['totalValue'] as num?)?.toInt() ?? 0,
      avgOrderValue: (json['avgOrderValue'] as num?)?.toInt() ?? 0,
      orderCount: (json['orderCount'] as num?)?.toInt() ?? 0,
      pendingValue: (json['pendingValue'] as num?)?.toInt() ?? 0,
      pendingOrders: (json['pendingOrders'] as num?)?.toInt() ?? 0,
    );
  }
}

class PatternInfo {
  final List<dynamic> topGrades;
  final int daysSinceLastOrder;

  PatternInfo({
    required this.topGrades,
    required this.daysSinceLastOrder,
  });

  factory PatternInfo.fromJson(Map<String, dynamic> json) {
    return PatternInfo(
      topGrades: json['topGrades'] ?? [],
      daysSinceLastOrder: (json['daysSinceLastOrder'] as num?)?.toInt() ?? 0,
    );
  }
}

class AiRecommendation {
  final String priority;
  final String icon;
  final String text;
  final String? action;
  final String? grade;
  final int? qty;

  AiRecommendation({
    required this.priority,
    required this.icon,
    required this.text,
    this.action,
    this.grade,
    this.qty,
  });

  factory AiRecommendation.fromJson(Map<String, dynamic> json) {
    return AiRecommendation(
      priority: json['priority'] ?? 'medium',
      icon: json['icon'] ?? '💡',
      text: json['text'] ?? '',
      action: json['action'],
      grade: json['grade'],
      qty: (json['qty'] as num?)?.toInt(),
    );
  }
}
