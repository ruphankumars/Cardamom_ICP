/// Expense Sheet and Item models for Phase 2

/// Categories for expense items
enum ExpenseCategory {
  workerWages('worker_wages', 'Worker Wages'),
  stitching('stitching', 'Stitching'),
  loading('loading', 'Loading'),
  transport('transport', 'Transport'),
  fuel('fuel', 'Fuel'),
  maintenance('maintenance', 'Maintenance'),
  misc('misc', 'Miscellaneous');

  final String apiValue;
  final String displayName;
  const ExpenseCategory(this.apiValue, this.displayName);

  static ExpenseCategory fromString(String? value) {
    return ExpenseCategory.values.firstWhere(
      (e) => e.apiValue == value,
      orElse: () => ExpenseCategory.misc,
    );
  }
}

/// Sub-categories for loading expenses
enum LoadingType {
  in_('in', 'Unloading (Purchase)'),
  out('out', 'Loading (Sales)');

  final String apiValue;
  final String displayName;
  const LoadingType(this.apiValue, this.displayName);

  static LoadingType? fromString(String? value) {
    if (value == null || value.isEmpty) return null;
    return LoadingType.values.firstWhere(
      (e) => e.apiValue == value,
      orElse: () => LoadingType.out,
    );
  }
}

/// Expense sheet status
enum ExpenseStatus {
  draft('draft', 'Draft'),
  pending('pending', 'Pending Approval'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected');

  final String apiValue;
  final String displayName;
  const ExpenseStatus(this.apiValue, this.displayName);

  static ExpenseStatus fromString(String? value) {
    return ExpenseStatus.values.firstWhere(
      (e) => e.apiValue == value,
      orElse: () => ExpenseStatus.draft,
    );
  }
}

/// Individual expense item
class ExpenseItem {
  final String id;
  final String sheetId;
  final ExpenseCategory category;
  final LoadingType? subCategory;
  final int? quantity;
  final double? rate;
  final double amount;
  final String? note;
  final String? receiptUrl;
  final DateTime? createdAt;

  ExpenseItem({
    required this.id,
    required this.sheetId,
    required this.category,
    this.subCategory,
    this.quantity,
    this.rate,
    required this.amount,
    this.note,
    this.receiptUrl,
    this.createdAt,
  });

  factory ExpenseItem.fromJson(Map<String, dynamic> json) {
    return ExpenseItem(
      id: json['id']?.toString() ?? '',
      sheetId: json['sheetId']?.toString() ?? '',
      category: ExpenseCategory.fromString(json['category']?.toString()),
      subCategory: LoadingType.fromString(json['subCategory']?.toString()),
      quantity: json['quantity'] != null ? int.tryParse(json['quantity'].toString()) : null,
      rate: json['rate'] != null ? double.tryParse(json['rate'].toString()) : null,
      amount: double.tryParse(json['amount']?.toString() ?? '0') ?? 0,
      note: json['note']?.toString(),
      receiptUrl: json['receiptUrl']?.toString(),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sheetId': sheetId,
    'category': category.apiValue,
    'subCategory': subCategory?.apiValue,
    'quantity': quantity,
    'rate': rate,
    'amount': amount,
    'note': note,
    'receiptUrl': receiptUrl,
  };

  /// Creates a copy with updated fields
  ExpenseItem copyWith({
    String? id,
    String? sheetId,
    ExpenseCategory? category,
    LoadingType? subCategory,
    int? quantity,
    double? rate,
    double? amount,
    String? note,
    String? receiptUrl,
  }) {
    return ExpenseItem(
      id: id ?? this.id,
      sheetId: sheetId ?? this.sheetId,
      category: category ?? this.category,
      subCategory: subCategory ?? this.subCategory,
      quantity: quantity ?? this.quantity,
      rate: rate ?? this.rate,
      amount: amount ?? this.amount,
      note: note ?? this.note,
      receiptUrl: receiptUrl ?? this.receiptUrl,
      createdAt: createdAt,
    );
  }
}

/// Daily expense sheet
class ExpenseSheet {
  final String? id;
  final String date;
  final double workerWages;
  final double totalVariable;
  final double totalMisc;
  final double grandTotal;
  final ExpenseStatus status;
  final String? submittedBy;
  final DateTime? submittedAt;
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? rejectionReason;
  final List<ExpenseItem> items;

  ExpenseSheet({
    this.id,
    required this.date,
    required this.workerWages,
    this.totalVariable = 0,
    this.totalMisc = 0,
    required this.grandTotal,
    this.status = ExpenseStatus.draft,
    this.submittedBy,
    this.submittedAt,
    this.approvedBy,
    this.approvedAt,
    this.rejectionReason,
    this.items = const [],
  });

  factory ExpenseSheet.fromJson(Map<String, dynamic> json) {
    final itemsList = json['items'] as List<dynamic>? ?? [];
    
    return ExpenseSheet(
      id: json['id']?.toString(),
      date: json['date']?.toString() ?? '',
      workerWages: double.tryParse(json['workerWages']?.toString() ?? '0') ?? 0,
      totalVariable: double.tryParse(json['totalVariable']?.toString() ?? '0') ?? 0,
      totalMisc: double.tryParse(json['totalMisc']?.toString() ?? '0') ?? 0,
      grandTotal: double.tryParse(json['grandTotal']?.toString() ?? '0') ?? 0,
      status: ExpenseStatus.fromString(json['status']?.toString()),
      submittedBy: json['submittedBy']?.toString(),
      submittedAt: json['submittedAt'] != null
          ? DateTime.tryParse(json['submittedAt'].toString())
          : null,
      approvedBy: json['approvedBy']?.toString(),
      approvedAt: json['approvedAt'] != null
          ? DateTime.tryParse(json['approvedAt'].toString())
          : null,
      rejectionReason: json['rejectionReason']?.toString(),
      items: itemsList.map((item) => ExpenseItem.fromJson(item)).toList(),
    );
  }

  /// Get variable expense items only
  List<ExpenseItem> get variableItems => items.where((item) =>
    item.category != ExpenseCategory.workerWages &&
    item.category != ExpenseCategory.misc
  ).toList();

  /// Get misc expense items only
  List<ExpenseItem> get miscItems => items.where((item) =>
    item.category == ExpenseCategory.misc
  ).toList();

  /// Calculate misc percentage
  double get miscPercentage {
    if (grandTotal == 0) return 0;
    return (totalMisc / grandTotal) * 100;
  }

  /// Check if sheet can be edited
  bool get canEdit => status == ExpenseStatus.draft || status == ExpenseStatus.rejected;

  /// Check if sheet can be submitted
  bool get canSubmit => (status == ExpenseStatus.draft || status == ExpenseStatus.rejected);

  /// Check if sheet can be approved (admin only)
  bool get canApprove => status == ExpenseStatus.pending;
}

/// Calendar day data for expense calendar view
class ExpenseCalendarDay {
  final String date;
  final double total;
  final ExpenseStatus status;

  ExpenseCalendarDay({
    required this.date,
    required this.total,
    required this.status,
  });

  factory ExpenseCalendarDay.fromJson(Map<String, dynamic> json) {
    return ExpenseCalendarDay(
      date: json['date']?.toString() ?? '',
      total: double.tryParse(json['total']?.toString() ?? '0') ?? 0,
      status: ExpenseStatus.fromString(json['status']?.toString()),
    );
  }
}

/// Monthly expense calendar summary
class ExpenseCalendarSummary {
  final List<ExpenseCalendarDay> days;
  final double grandTotal;
  final double approved;
  final double pending;

  ExpenseCalendarSummary({
    required this.days,
    required this.grandTotal,
    required this.approved,
    required this.pending,
  });

  factory ExpenseCalendarSummary.fromJson(Map<String, dynamic> json) {
    final daysList = json['days'] as List<dynamic>? ?? [];
    final totals = json['totals'] as Map<String, dynamic>? ?? {};

    return ExpenseCalendarSummary(
      days: daysList.map((d) => ExpenseCalendarDay.fromJson(d)).toList(),
      grandTotal: double.tryParse(totals['grandTotal']?.toString() ?? '0') ?? 0,
      approved: double.tryParse(totals['approved']?.toString() ?? '0') ?? 0,
      pending: double.tryParse(totals['pending']?.toString() ?? '0') ?? 0,
    );
  }
}
