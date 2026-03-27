import 'package:flutter/foundation.dart';
import '../models/expense_sheet.dart';
import 'api_service.dart';
import 'package:intl/intl.dart';

/// Service for managing expenses - connects to backend API
class ExpenseService extends ChangeNotifier {
  final ApiService _apiService;
  
  ExpenseSheet? _currentSheet;
  ExpenseCalendarSummary? _calendarSummary;
  bool _isLoading = false;
  String? _error;

  ExpenseService(this._apiService);

  // Getters
  ExpenseSheet? get currentSheet => _currentSheet;
  ExpenseCalendarSummary? get calendarSummary => _calendarSummary;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Get today's date in ISO format
  String get todayDate => DateFormat('yyyy-MM-dd').format(DateTime.now());

  /// Load expense sheet for a specific date
  Future<ExpenseSheet?> loadExpenseSheet(String date) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _apiService.getExpenseSheet(date);
      _currentSheet = ExpenseSheet.fromJson(response.data);
      _isLoading = false;
      notifyListeners();
      return _currentSheet;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      debugPrint('Error loading expense sheet: $e');
      return null;
    }
  }

  /// Load today's expense sheet
  Future<ExpenseSheet?> loadTodaySheet() async {
    return loadExpenseSheet(todayDate);
  }

  /// Save expense sheet with items
  Future<Map<String, dynamic>> saveExpenseSheet({
    required String date,
    required List<Map<String, dynamic>> items,
    String? submittedBy,
  }) async {
    try {
      final response = await _apiService.saveExpenseSheet({
        'date': date,
        'items': items,
        'submittedBy': submittedBy,
      });

      // Reload the sheet after saving
      await loadExpenseSheet(date);

      return response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};
    } catch (e) {
      debugPrint('Error saving expense sheet: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Add a single expense item to the current sheet
  Future<bool> addExpenseItem({
    required String date,
    required ExpenseCategory category,
    LoadingType? subCategory,
    int? quantity,
    double? rate,
    required double amount,
    String? note,
    String? receiptUrl,
  }) async {
    final currentItems = _currentSheet?.items ?? [];
    
    // Create new item
    final newItem = {
      'category': category.apiValue,
      'subCategory': subCategory?.apiValue,
      'quantity': quantity,
      'rate': rate,
      'amount': amount,
      'note': note,
      'receiptUrl': receiptUrl,
    };

    // Add to existing items
    final allItems = [
      ...currentItems.map((item) => item.toJson()),
      newItem,
    ];

    final result = await saveExpenseSheet(date: date, items: allItems);
    return result['success'] == true;
  }

  /// Remove expense item by index
  Future<bool> removeExpenseItem(String date, int index) async {
    final currentItems = _currentSheet?.items ?? [];
    if (index >= currentItems.length) return false;

    final updatedItems = [...currentItems];
    updatedItems.removeAt(index);

    final result = await saveExpenseSheet(
      date: date,
      items: updatedItems.map((item) => item.toJson()).toList(),
    );
    return result['success'] == true;
  }

  /// Submit expense sheet for approval
  Future<bool> submitForApproval(String sheetId, String submittedBy) async {
    try {
      final response = await _apiService.submitExpenseSheet(sheetId, submittedBy);

      // Reload the sheet to get updated status
      if (_currentSheet != null) {
        await loadExpenseSheet(_currentSheet!.date);
      }

      return response.data['success'] == true;
    } catch (e) {
      debugPrint('Error submitting expense sheet: $e');
      return false;
    }
  }

  /// Approve expense sheet (admin only)
  Future<bool> approveSheet(String sheetId, String approvedBy) async {
    try {
      final response = await _apiService.approveExpenseSheet(sheetId, approvedBy);

      if (_currentSheet != null) {
        await loadExpenseSheet(_currentSheet!.date);
      }

      return response.data['success'] == true;
    } catch (e) {
      debugPrint('Error approving expense sheet: $e');
      return false;
    }
  }

  /// Reject expense sheet with reason (admin only)
  Future<bool> rejectSheet(String sheetId, String rejectedBy, String reason) async {
    try {
      final response = await _apiService.rejectExpenseSheet(sheetId, rejectedBy, reason);

      if (_currentSheet != null) {
        await loadExpenseSheet(_currentSheet!.date);
      }

      return response.data['success'] == true;
    } catch (e) {
      debugPrint('Error rejecting expense sheet: $e');
      return false;
    }
  }

  /// Load expense calendar for a month
  Future<ExpenseCalendarSummary?> loadExpenseCalendar(int year, int month) async {
    try {
      final response = await _apiService.getExpenseCalendar(year, month);
      _calendarSummary = ExpenseCalendarSummary.fromJson(response.data);
      notifyListeners();
      return _calendarSummary;
    } catch (e) {
      debugPrint('Error loading expense calendar: $e');
      return null;
    }
  }

  // Pending sheets for admin approval
  List<ExpenseSheet> _pendingSheets = [];
  List<ExpenseSheet> get pendingSheets => _pendingSheets;

  /// Load all pending expense sheets for admin approval
  Future<List<ExpenseSheet>> loadPendingSheets() async {
    try {
      final response = await _apiService.getPendingExpenses();
      final data = response.data is List ? response.data as List<dynamic> : <dynamic>[];
      _pendingSheets = data.map((json) => ExpenseSheet.fromJson(json)).toList();
      notifyListeners();
      return _pendingSheets;
    } catch (e) {
      debugPrint('Error loading pending expense sheets: $e');
      return [];
    }
  }

  /// Fetch pending expense sheets without notifying listeners (for FutureBuilder)
  Future<List<ExpenseSheet>> fetchPendingSheets() async {
    try {
      final response = await _apiService.getPendingExpenses();
      final data = response.data is List ? response.data as List<dynamic> : <dynamic>[];
      return data.map((json) => ExpenseSheet.fromJson(json)).toList();
    } catch (e) {
      debugPrint('Error loading pending expense sheets: $e');
      return [];
    }
  }

  /// Withdraw pending expense sheet (user can cancel before admin reviews)
  Future<bool> withdrawExpenseSheet(String sheetId) async {
    try {
      final response = await _apiService.withdrawExpenseSheet(sheetId);
      if (response.data['success'] == true) {
        // Reload the current sheet to reflect the change
        if (_currentSheet != null) {
          await loadExpenseSheet(_currentSheet!.date);
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error withdrawing expense sheet: $e');
      return false;
    }
  }

  /// Get status color for expense sheet
  static int getStatusColor(ExpenseStatus status) {
    switch (status) {
      case ExpenseStatus.draft:
        return 0xFF9E9E9E; // Grey
      case ExpenseStatus.pending:
        return 0xFFFF9800; // Orange
      case ExpenseStatus.approved:
        return 0xFF4CAF50; // Green
      case ExpenseStatus.rejected:
        return 0xFFF44336; // Red;
    }
  }
}
