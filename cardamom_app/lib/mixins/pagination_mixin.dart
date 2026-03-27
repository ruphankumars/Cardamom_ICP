import 'package:flutter/material.dart';
import '../models/paginated_response.dart';

/// Mixin that provides infinite scroll pagination behavior for list screens.
///
/// Usage:
/// ```dart
/// class _MyScreenState extends State<MyScreen> with PaginationMixin {
///   @override
///   Future<void> loadNextPage() async {
///     // Implement loading next page
///   }
/// }
/// ```
///
/// Wrap your scrollable widget with NotificationListener:
/// ```dart
/// NotificationListener<ScrollNotification>(
///   onNotification: onScrollNotification,
///   child: ListView.builder(...),
/// )
/// ```
mixin PaginationMixin<T extends StatefulWidget> on State<T> {
  final PaginationInfo paginationInfo = PaginationInfo();

  /// Override this to load the next page of data.
  Future<void> loadNextPage();

  /// Call this on pull-to-refresh to reset pagination and reload.
  Future<void> resetAndReload() async {
    paginationInfo.reset();
    await loadNextPage();
  }

  /// Attach this to a NotificationListener<ScrollNotification>.
  /// Triggers loadNextPage() when user scrolls within 200px of the bottom.
  bool onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollEndNotification &&
        notification.metrics.extentAfter < 200 &&
        paginationInfo.hasMore &&
        !paginationInfo.isLoadingMore) {
      paginationInfo.isLoadingMore = true;
      loadNextPage();
    }
    return false;
  }

  /// Build a loading indicator widget for the bottom of the list.
  /// Returns empty if not loading more, a progress indicator if loading,
  /// or "No more items" text if all pages loaded.
  Widget buildPaginationFooter() {
    if (paginationInfo.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (!paginationInfo.hasMore) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(
          child: Text(
            'No more items',
            style: TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 13,
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
