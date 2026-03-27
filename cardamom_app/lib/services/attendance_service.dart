import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/worker.dart';
import 'api_service.dart';

/// Service for managing workers and attendance
class AttendanceService extends ChangeNotifier {
  final ApiService _apiService;
  
  List<Worker> _workers = [];
  AttendanceSummary? _todaySummary;
  bool _isLoading = false;
  String? _error;

  AttendanceService(this._apiService);

  // Getters
  List<Worker> get workers => _workers;
  AttendanceSummary? get todaySummary => _todaySummary;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Get today's date in YYYY-MM-DD format
  String get todayDate {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// Load all workers
  Future<List<Worker>> loadWorkers({bool includeInactive = false}) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final response = await _apiService.getWorkers(includeInactive: includeInactive);
      final data = response.data is List ? response.data as List<dynamic> : <dynamic>[];
      _workers = data.map((w) => Worker.fromJson(w)).toList();
      
      _isLoading = false;
      notifyListeners();
      return _workers;
    } catch (e) {
      _isLoading = false;
      _error = e.toString();
      notifyListeners();
      debugPrint('Error loading workers: $e');
      return [];
    }
  }

  /// Search workers with fuzzy matching
  Future<WorkerSearchResult> searchWorkers(String query) async {
    try {
      final response = await _apiService.searchWorkers(query);
      return WorkerSearchResult.fromJson(response.data);
    } catch (e) {
      debugPrint('Error searching workers: $e');
      return WorkerSearchResult(exactMatches: [], similarMatches: []);
    }
  }

  /// Add a new worker
  Future<Map<String, dynamic>> addWorker({
    required String name,
    String? phone,
    double baseDailyWage = 500,
    double otHourlyRate = 100,
    String team = 'General',
  }) async {
    try {
      final response = await _apiService.addWorker({
        'name': name,
        'phone': phone,
        'baseDailyWage': baseDailyWage,
        'otHourlyRate': otHourlyRate,
        'team': team,
      });

      final result = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};

      if (result['success'] == true && result['worker'] != null) {
        // Add to local list
        _workers.add(Worker.fromJson(result['worker']));
        notifyListeners();
      }

      return result;
    } catch (e) {
      debugPrint('Error adding worker: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Force add worker (skip duplicate check)
  Future<Map<String, dynamic>> forceAddWorker({
    required String name,
    String? phone,
    double baseDailyWage = 500,
    double otHourlyRate = 100,
    String team = 'General',
  }) async {
    try {
      final response = await _apiService.forceAddWorker({
        'name': name,
        'phone': phone,
        'baseDailyWage': baseDailyWage,
        'otHourlyRate': otHourlyRate,
        'team': team,
      });

      final result = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};
      
      if (result['success'] == true && result['worker'] != null) {
        _workers.add(Worker.fromJson(result['worker']));
        notifyListeners();
      }
      
      return result;
    } catch (e) {
      debugPrint('Error force adding worker: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Update worker
  Future<bool> updateWorker(String workerId, Map<String, dynamic> updates) async {
    try {
      final response = await _apiService.updateWorker(workerId, updates);
      final result = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};
      
      if (result['success'] == true) {
        // Update local list
        final index = _workers.indexWhere((w) => w.id == workerId);
        if (index != -1) {
          _workers[index] = _workers[index].copyWith(
            name: updates['name'],
            phone: updates['phone'],
            baseDailyWage: updates['baseDailyWage']?.toDouble(),
            otHourlyRate: updates['otHourlyRate']?.toDouble(),
            team: updates['team'],
            isActive: updates['isActive'],
          );
          notifyListeners();
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error updating worker: $e');
      return false;
    }
  }

  /// Get worker teams
  Future<List<WorkerTeam>> getTeams() async {
    try {
      final response = await _apiService.getWorkerTeams();
      final data = response.data is List ? response.data as List<dynamic> : <dynamic>[];
      return data.map((t) => WorkerTeam.fromJson(t)).toList();
    } catch (e) {
      debugPrint('Error getting teams: $e');
      return [
        WorkerTeam(id: 'T1', name: 'General'),
        WorkerTeam(id: 'T2', name: 'Stitching'),
        WorkerTeam(id: 'T3', name: 'Loading'),
      ];
    }
  }

  /// Get attendance for a specific date
  Future<List<AttendanceRecord>> getAttendance(String date) async {
    try {
      final response = await _apiService.getAttendance(date);
      final data = response.data is List ? response.data as List<dynamic> : <dynamic>[];
      return data.map((a) => AttendanceRecord.fromJson(a)).toList();
    } catch (e) {
      debugPrint('Error getting attendance: $e');
      return [];
    }
  }

  /// Get attendance summary for a date
  Future<AttendanceSummary?> getAttendanceSummary(String date) async {
    try {
      final response = await _apiService.getAttendanceSummary(date);
      return AttendanceSummary.fromJson(response.data);
    } catch (e) {
      debugPrint('Error getting attendance summary: $e');
      return null;
    }
  }

  /// Load today's attendance summary
  Future<AttendanceSummary?> loadTodaySummary() async {
    _todaySummary = await getAttendanceSummary(todayDate);
    notifyListeners();
    return _todaySummary;
  }

  /// Load attendance summary for a specific date
  Future<AttendanceSummary?> loadSummary(String date) async {
    _todaySummary = await getAttendanceSummary(date);
    notifyListeners();
    return _todaySummary;
  }

  /// Mark attendance for a worker
  Future<Map<String, dynamic>> markAttendance({
    required String workerId,
    String? workerName,
    String? date,
    AttendanceStatus status = AttendanceStatus.full,
    double otHours = 0,
    String? otReason,
    double? wageOverride,
    required String markedBy,
  }) async {
    try {
      final attendanceDate = date ?? todayDate;

      // Resolve worker name from local list if not provided
      final resolvedName = workerName ?? _workers.where((w) => w.id == workerId).map((w) => w.name).firstOrNull ?? '';

      final response = await _apiService.markAttendance({
        'date': attendanceDate,
        'workerId': workerId,
        'workerName': resolvedName,
        'status': status.apiValue,
        'otHours': otHours,
        'otReason': otReason,
        'wageOverride': wageOverride,
        'markedBy': markedBy,
      });

      final result = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};
      
      // Refresh today's summary if marking for today
      if (attendanceDate == todayDate) {
        await loadTodaySummary();
      }
      
      return result;
    } catch (e) {
      debugPrint('Error marking attendance: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Register a face scan (entry or exit). Supports offline queueing.
  Future<Map<String, dynamic>> registerFaceScan({
    required String workerId,
    required String workerName,
    required DateTime scanTime,
    required String markedBy,
  }) async {
    final date = '${scanTime.year}-${scanTime.month.toString().padLeft(2, '0')}-${scanTime.day.toString().padLeft(2, '0')}';
    final scanData = {
      'date': date,
      'workerId': workerId,
      'workerName': workerName,
      'scanTime': scanTime.toUtc().toIso8601String(),
      'markedBy': markedBy,
    };

    try {
      // Try API directly
      final response = await _apiService.markAttendance(scanData);
      final result = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};

      // Refresh today's summary if marking for today
      if (date == todayDate) {
        await loadTodaySummary();
      }

      return result;
    } catch (e) {
      debugPrint('Error registering face scan online, queueing offline: $e');

      // Persist to SharedPreferences for later sync
      try {
        final prefs = await SharedPreferences.getInstance();
        final queueRaw = prefs.getStringList('offline_attendance_queue') ?? [];
        queueRaw.add(jsonEncode(scanData));
        await prefs.setStringList('offline_attendance_queue', queueRaw);
        debugPrint('[OfflineQueue] Queued scan for $workerName (${queueRaw.length} pending)');
        return {'success': true, 'offline': true, 'attendance': scanData};
      } catch (cacheErr) {
        debugPrint('[OfflineQueue] Failed to persist: $cacheErr');
        return {'success': false, 'error': 'Failed to save online and offline'};
      }
    }
  }

  /// Sync any offline-queued attendance scans. Call on app start or when connectivity is restored.
  Future<int> syncOfflineQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueRaw = prefs.getStringList('offline_attendance_queue') ?? [];
      if (queueRaw.isEmpty) return 0;

      debugPrint('[OfflineQueue] Syncing ${queueRaw.length} queued scans...');
      final failed = <String>[];
      int synced = 0;

      for (final raw in queueRaw) {
        try {
          final scanData = jsonDecode(raw) as Map<String, dynamic>;
          await _apiService.markAttendance(scanData);
          synced++;
        } catch (e) {
          debugPrint('[OfflineQueue] Failed to sync: $e');
          failed.add(raw);
        }
      }

      // Keep only failed items in queue
      await prefs.setStringList('offline_attendance_queue', failed);
      debugPrint('[OfflineQueue] Synced $synced, ${failed.length} remaining');

      if (synced > 0) {
        await loadTodaySummary();
      }

      return synced;
    } catch (e) {
      debugPrint('[OfflineQueue] Sync error: $e');
      return 0;
    }
  }

  /// Remove attendance record
  Future<bool> removeAttendance(String date, String workerId) async {
    try {
      final response = await _apiService.removeAttendance(date, workerId);
      final result = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};
      
      if (result['success'] == true && date == todayDate) {
        loadTodaySummary();
      }
      
      return result['success'] == true;
    } catch (e) {
      debugPrint('Error removing attendance: $e');
      return false;
    }
  }

  /// Copy previous day's workers to today
  Future<int> copyPreviousDayWorkers(String markedBy) async {
    try {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final fromDate = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
      
      final response = await _apiService.copyPreviousDayWorkers(fromDate, todayDate, markedBy);
      final result = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};
      
      if (result['success'] == true) {
        loadTodaySummary();
        return result['added'] ?? 0;
      }
      return 0;
    } catch (e) {
      debugPrint('Error copying previous day workers: $e');
      return 0;
    }
  }

  /// Get calendar data for a month
  Future<Map<String, CalendarEntry>> getCalendar(int year, int month) async {
    try {
      final response = await _apiService.getAttendanceCalendar(year, month);
      final data = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};

      return data.map((key, value) =>
        MapEntry(key, CalendarEntry.fromJson(key, value is Map ? value as Map<String, dynamic> : <String, dynamic>{}))
      );
    } catch (e) {
      debugPrint('Error getting calendar: $e');
      return {};
    }
  }

  /// Get worker by ID
  Worker? getWorkerById(String id) {
    try {
      return _workers.firstWhere((w) => w.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Restore workers from cached data (used when offline)
  void restoreWorkersFromCache(List<Worker> cachedWorkers) {
    _workers = cachedWorkers;
    notifyListeners();
  }

  /// Clear error
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
