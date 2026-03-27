/// Generic paginated response model for consuming cursor-based pagination
/// API responses.
///
/// The backend returns responses in this envelope format:
/// ```json
/// {
///   "data": [...],
///   "pagination": {
///     "cursor": "last_doc_id",
///     "hasMore": true,
///     "limit": 25
///   }
/// }
/// ```
class PaginatedResponse<T> {
  final List<T> data;
  final String? cursor;
  final bool hasMore;
  final int limit;
  final bool truncated;

  PaginatedResponse({
    required this.data,
    this.cursor,
    this.hasMore = false,
    this.limit = 25,
    this.truncated = false,
  });

  /// Parse a paginated response from JSON.
  ///
  /// [json] is the raw response map.
  /// [fromJson] converts each item in the data array to type T.
  /// [dataKey] is the key for the data array (default: 'data').
  factory PaginatedResponse.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJson, {
    String dataKey = 'data',
  }) {
    final pagination = json['pagination'] as Map<String, dynamic>? ?? {};
    final rawData = json[dataKey];

    List<T> items = [];
    if (rawData is List) {
      items = rawData
          .whereType<Map<String, dynamic>>()
          .map((item) => fromJson(item))
          .toList();
    }

    return PaginatedResponse<T>(
      data: items,
      cursor: pagination['cursor'] as String?,
      hasMore: pagination['hasMore'] as bool? ?? false,
      limit: pagination['limit'] as int? ?? 25,
      truncated: pagination['truncated'] as bool? ?? false,
    );
  }

  /// Parse a paginated response where the data key holds requests/logs/tasks.
  /// Useful for endpoints like { success: true, requests: [...], pagination: {...} }
  factory PaginatedResponse.fromJsonWithKey(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJson,
    String dataKey,
  ) {
    return PaginatedResponse.fromJson(json, fromJson, dataKey: dataKey);
  }
}

/// Pagination metadata for tracking state in Flutter widgets.
class PaginationInfo {
  String? cursor;
  bool hasMore;
  bool isLoadingMore;
  int limit;

  PaginationInfo({
    this.cursor,
    this.hasMore = true,
    this.isLoadingMore = false,
    this.limit = 25,
  });

  /// Reset pagination state (e.g., on pull-to-refresh).
  void reset() {
    cursor = null;
    hasMore = true;
    isLoadingMore = false;
  }

  /// Update from a paginated response.
  void updateFrom<T>(PaginatedResponse<T> response) {
    cursor = response.cursor;
    hasMore = response.hasMore;
    isLoadingMore = false;
    limit = response.limit;
  }
}
