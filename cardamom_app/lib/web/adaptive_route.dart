import 'package:flutter/material.dart';
import 'responsive_scaffold.dart';
import 'web_shell.dart';

/// A widget that renders either a mobile screen or a web screen
/// based on the current viewport width.
///
/// On wide screens (>= 768px), shows [webChild] wrapped in [WebShell].
/// On narrow screens (< 768px), shows [mobileChild] as-is (already wrapped in AppShell).
class AdaptiveRoute extends StatelessWidget {
  /// The mobile version of the screen (existing screen with AppShell wrapping)
  final Widget mobileChild;

  /// The web version of the screen (standalone content, will be wrapped in WebShell)
  final Widget webChild;

  /// Title for the web shell top bar
  final String title;

  /// Optional subtitle for the web shell top bar
  final String? subtitle;

  /// Optional action buttons for the web shell top bar
  final List<Widget>? topActions;

  const AdaptiveRoute({
    super.key,
    required this.mobileChild,
    required this.webChild,
    required this.title,
    this.subtitle,
    this.topActions,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    if (width >= Breakpoints.mobile) {
      return WebShell(
        title: title,
        subtitle: subtitle,
        topActions: topActions,
        child: webChild,
      );
    }

    return mobileChild;
  }
}

/// Simplified adaptive route that wraps only web content in WebShell.
/// Use this when the mobile screen doesn't need to change.
class WebOnlyRoute extends StatelessWidget {
  /// The web content (standalone widget, no shell wrapping)
  final Widget child;

  /// Title for the web shell
  final String title;

  /// Optional subtitle
  final String? subtitle;

  const WebOnlyRoute({
    super.key,
    required this.child,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    if (width >= Breakpoints.mobile) {
      return WebShell(
        title: title,
        subtitle: subtitle,
        child: child,
      );
    }

    // On mobile, just show the child in a basic scaffold
    // (caller should provide the mobile version separately if needed)
    return Scaffold(
      body: child,
    );
  }
}
