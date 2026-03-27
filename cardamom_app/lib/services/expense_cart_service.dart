import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/expense_sheet.dart';

/// Expense Cart item for local draft storage
class ExpenseCartItem {
  final String id;
  final ExpenseCategory category;
  final LoadingType? subCategory;
  final int? quantity;
  final double? rate;
  final double amount;
  final String? note;
  final DateTime createdAt;

  ExpenseCartItem({
    required this.id,
    required this.category,
    this.subCategory,
    this.quantity,
    this.rate,
    required this.amount,
    this.note,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory ExpenseCartItem.fromJson(Map<String, dynamic> json) {
    return ExpenseCartItem(
      id: json['id'] ?? '',
      category: ExpenseCategory.fromString(json['category']),
      subCategory: LoadingType.fromString(json['subCategory']),
      quantity: json['quantity'] != null ? int.tryParse(json['quantity'].toString()) : null,
      rate: json['rate'] != null ? double.tryParse(json['rate'].toString()) : null,
      amount: double.tryParse(json['amount']?.toString() ?? '0') ?? 0,
      note: json['note'],
      createdAt: json['createdAt'] != null 
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category.apiValue,
    'subCategory': subCategory?.apiValue,
    'quantity': quantity,
    'rate': rate,
    'amount': amount,
    'note': note,
    'createdAt': createdAt.toIso8601String(),
  };

  /// Get display label for the item
  String get displayLabel {
    switch (category) {
      case ExpenseCategory.stitching:
        return 'Stitching · ${quantity ?? 0} bags';
      case ExpenseCategory.loading:
        final type = subCategory == LoadingType.in_ ? 'Unloading' : 'Loading';
        return '$type · ₹${amount.toInt()}';
      case ExpenseCategory.transport:
        return 'Transport · ₹${amount.toInt()}';
      case ExpenseCategory.fuel:
        return 'Fuel · ₹${amount.toInt()}';
      case ExpenseCategory.maintenance:
        return 'Maintenance · ₹${amount.toInt()}';
      case ExpenseCategory.misc:
        return 'Misc · ₹${amount.toInt()}';
      default:
        return '${category.displayName} · ₹${amount.toInt()}';
    }
  }
}

/// Service for managing expense cart (local drafts)
class ExpenseCartService extends ChangeNotifier {
  static const String _cartKey = 'expense_cart';
  
  List<ExpenseCartItem> _items = [];
  bool _isLoaded = false;
  
  List<ExpenseCartItem> get items => List.unmodifiable(_items);
  int get itemCount => _items.length;
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  
  double get totalAmount => _items.fold(0, (sum, item) => sum + item.amount);
  
  /// Variable expenses total (stitching, loading, transport, fuel, maintenance)
  double get variableTotal => _items
      .where((item) => item.category != ExpenseCategory.misc && 
                       item.category != ExpenseCategory.workerWages)
      .fold(0, (sum, item) => sum + item.amount);
  
  /// Misc expenses total
  double get miscTotal => _items
      .where((item) => item.category == ExpenseCategory.misc)
      .fold(0, (sum, item) => sum + item.amount);

  /// Load cart from SharedPreferences
  Future<void> loadCart() async {
    if (_isLoaded) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final cartJson = prefs.getString(_cartKey);
      
      if (cartJson != null && cartJson.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(cartJson);
        _items = decoded.map((json) => ExpenseCartItem.fromJson(json)).toList();
      }
      
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading expense cart: $e');
      _items = [];
      _isLoaded = true;
    }
  }

  /// Save cart to SharedPreferences
  Future<void> _saveCart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cartJson = jsonEncode(_items.map((item) => item.toJson()).toList());
      await prefs.setString(_cartKey, cartJson);
    } catch (e) {
      debugPrint('Error saving expense cart: $e');
    }
  }

  /// Add item to cart
  Future<void> addItem({
    required ExpenseCategory category,
    LoadingType? subCategory,
    int? quantity,
    double? rate,
    required double amount,
    String? note,
  }) async {
    final item = ExpenseCartItem(
      id: 'CART_${DateTime.now().millisecondsSinceEpoch}_${_items.length}_${Random().nextInt(99999).toString().padLeft(5, '0')}',
      category: category,
      subCategory: subCategory,
      quantity: quantity,
      rate: rate,
      amount: amount,
      note: note,
    );
    
    _items.add(item);
    await _saveCart();
    notifyListeners();
  }

  /// Remove item from cart by ID
  Future<void> removeItem(String id) async {
    _items.removeWhere((item) => item.id == id);
    await _saveCart();
    notifyListeners();
  }

  /// Update item in cart
  Future<void> updateItem(String id, {
    ExpenseCategory? category,
    LoadingType? subCategory,
    int? quantity,
    double? rate,
    double? amount,
    String? note,
  }) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    
    final oldItem = _items[index];
    _items[index] = ExpenseCartItem(
      id: oldItem.id,
      category: category ?? oldItem.category,
      subCategory: subCategory ?? oldItem.subCategory,
      quantity: quantity ?? oldItem.quantity,
      rate: rate ?? oldItem.rate,
      amount: amount ?? oldItem.amount,
      note: note ?? oldItem.note,
      createdAt: oldItem.createdAt,
    );
    
    await _saveCart();
    notifyListeners();
  }

  /// Clear all items from cart
  Future<void> clearCart() async {
    _items = [];
    await _saveCart();
    notifyListeners();
  }

  /// Get items converted to API format for submission
  List<Map<String, dynamic>> getItemsForApi() {
    return _items.map((item) => {
      'category': item.category.apiValue,
      'subCategory': item.subCategory?.apiValue,
      'quantity': item.quantity,
      'rate': item.rate,
      'amount': item.amount,
      'note': item.note,
    }).toList();
  }
}
