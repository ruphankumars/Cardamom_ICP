import 'package:flutter/foundation.dart';

import 'ai_brain_service.dart';
import 'analytics_service.dart';

// Re-export model types so consumers can import from ai_provider.dart
export 'ai_brain_service.dart'
    show DailyBriefing, AiAction, AiPattern, AiPrediction, AiOpportunity,
         BriefingSummary, GradeAnalysis, ClientAnalysis, ClientInfo,
         FinancialInfo, PatternInfo, AiRecommendation;
export 'analytics_service.dart' show InsightsResult, Insight;

/// High-level status of the AI subsystem.
enum AiStatus { uninitialized, loading, ready, error }

/// Central state manager for backend-driven AI features.
///
/// Wraps [AiBrainService] and [AnalyticsService] with caching and
/// ChangeNotifier so the widget tree reacts to AI data changes.
class AiProvider extends ChangeNotifier {
  final AiBrainService _brainService;
  final AnalyticsService _analyticsService;

  // ── State ──
  AiStatus _status = AiStatus.uninitialized;
  bool _isLoading = false;
  String? _errorMessage;

  // ── Cached data + timestamps ──
  DailyBriefing? _dailyBriefing;
  DateTime? _briefingFetchedAt;
  Map<String, dynamic>? _recommendations;
  DateTime? _recommendationsFetchedAt;
  InsightsResult? _insights;
  DateTime? _insightsFetchedAt;

  // On-demand (not cached)
  GradeAnalysis? _lastGradeAnalysis;
  ClientAnalysis? _lastClientAnalysis;

  static const _cacheTtl = Duration(minutes: 2);

  // ── Constructor ──
  AiProvider({AiBrainService? brainService, AnalyticsService? analyticsService})
      : _brainService = brainService ?? AiBrainService(),
        _analyticsService = analyticsService ?? AnalyticsService();

  // ── Getters ──
  AiStatus get status => _status;
  bool get isLoading => _isLoading;
  bool get isReady => _status == AiStatus.ready;
  String? get errorMessage => _errorMessage;

  DailyBriefing? get dailyBriefing => _dailyBriefing;
  Map<String, dynamic>? get recommendations => _recommendations;
  InsightsResult? get insights => _insights;
  GradeAnalysis? get lastGradeAnalysis => _lastGradeAnalysis;
  ClientAnalysis? get lastClientAnalysis => _lastClientAnalysis;

  bool get hasBriefing => _dailyBriefing != null && _dailyBriefing!.success;

  // ── Initialization ──

  /// Guards against concurrent init calls — all callers share the same future.
  Future<void>? _initFuture;

  Future<void> ensureInitialized() {
    if (_status == AiStatus.ready) return Future.value();
    // If already initialising, return the in-flight future so callers coalesce.
    if (_initFuture != null) return _initFuture!;
    _initFuture = _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    try {
      _status = AiStatus.loading;
      _errorMessage = null;
      notifyListeners();

      // Warm cache by fetching daily briefing
      await fetchDailyBriefing();
      _status = AiStatus.ready;
    } catch (e) {
      debugPrint('[AiProvider] Init failed: $e');
      _errorMessage = 'AI unavailable';
      _status = AiStatus.error;
    } finally {
      _initFuture = null; // allow retry on next call
    }
    notifyListeners();
  }

  // ── Daily Briefing (cached 2 min) ──

  Future<DailyBriefing> fetchDailyBriefing({bool forceRefresh = false}) async {
    if (!forceRefresh && _dailyBriefing != null && _briefingFetchedAt != null &&
        DateTime.now().difference(_briefingFetchedAt!) < _cacheTtl) {
      return _dailyBriefing!;
    }
    try {
      _isLoading = true;
      _clearError();
      notifyListeners();

      _dailyBriefing = await _brainService.getDailyBriefing();
      _briefingFetchedAt = DateTime.now();
      if (!_dailyBriefing!.success) {
        _setError(_dailyBriefing!.error ?? 'Failed to fetch briefing');
      }
      return _dailyBriefing!;
    } catch (e) {
      debugPrint('[AiProvider] Briefing error: $e');
      _setError('Failed to fetch briefing. Check your connection.');
      return DailyBriefing(success: false, error: e.toString());
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Grade Analysis (on-demand) ──

  Future<GradeAnalysis> fetchGradeAnalysis(String grade) async {
    try {
      _isLoading = true;
      _clearError();
      notifyListeners();

      _lastGradeAnalysis = await _brainService.getGradeAnalysis(grade);
      return _lastGradeAnalysis!;
    } catch (e) {
      debugPrint('[AiProvider] Grade analysis error: $e');
      _setError('Grade analysis failed. Check your connection.');
      return GradeAnalysis(success: false, error: e.toString());
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Client Analysis (on-demand) ──

  Future<ClientAnalysis> fetchClientAnalysis(String clientName) async {
    try {
      _isLoading = true;
      _clearError();
      notifyListeners();

      _lastClientAnalysis = await _brainService.getClientAnalysis(clientName);
      return _lastClientAnalysis!;
    } catch (e) {
      debugPrint('[AiProvider] Client analysis error: $e');
      _setError('Client analysis failed. Check your connection.');
      return ClientAnalysis(success: false, error: e.toString());
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Recommendations (cached 2 min) ──

  Future<Map<String, dynamic>> fetchRecommendations({bool forceRefresh = false}) async {
    if (!forceRefresh && _recommendations != null && _recommendationsFetchedAt != null &&
        DateTime.now().difference(_recommendationsFetchedAt!) < _cacheTtl) {
      return _recommendations!;
    }
    try {
      _isLoading = true;
      _clearError();
      notifyListeners();

      _recommendations = await _brainService.getAllRecommendations();
      _recommendationsFetchedAt = DateTime.now();
      return _recommendations!;
    } catch (e) {
      debugPrint('[AiProvider] Recommendations error: $e');
      _setError('Recommendations failed. Check your connection.');
      return {'success': false, 'error': e.toString()};
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Insights (cached 2 min) ──

  Future<InsightsResult> fetchInsights({bool forceRefresh = false}) async {
    if (!forceRefresh && _insights != null && _insightsFetchedAt != null &&
        DateTime.now().difference(_insightsFetchedAt!) < _cacheTtl) {
      return _insights!;
    }
    try {
      _isLoading = true;
      _clearError();
      notifyListeners();

      _insights = await _analyticsService.getProactiveInsights();
      _insightsFetchedAt = DateTime.now();
      return _insights!;
    } catch (e) {
      debugPrint('[AiProvider] Insights error: $e');
      _setError('Insights failed. Check your connection.');
      return InsightsResult(success: false, error: e.toString(), insights: []);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Helpers ──

  void _setError(String message) {
    _errorMessage = message;
    _status = AiStatus.error;
  }

  void _clearError() {
    _errorMessage = null;
    if (_status == AiStatus.error) {
      _status = AiStatus.ready;
    }
  }
}
