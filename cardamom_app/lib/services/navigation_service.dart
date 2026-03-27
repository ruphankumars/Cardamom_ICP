import 'package:flutter/material.dart';

/// Global navigator key for programmatic navigation (e.g., 401 redirect to login)
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Global route notifier — tracks current route name for the desktop sidebar
final ValueNotifier<String> currentRouteNotifier = ValueNotifier<String>('/');

/// Route observer that updates the global route notifier
class AppRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _updateRoute(route);
  }
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _updateRoute(previousRoute);
  }
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _updateRoute(newRoute);
  }
  void _updateRoute(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) {
      currentRouteNotifier.value = name;
    }
  }
}

final appRouteObserver = AppRouteObserver();

/// RouteObserver for RouteAware screens — enables didPopNext() callbacks
/// so screens can silently refresh data when a child screen is popped.
final routeObserver = RouteObserver<ModalRoute<dynamic>>();
