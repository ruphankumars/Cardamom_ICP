import 'package:flutter/material.dart';
import '../widgets/app_shell.dart';
import 'web_shell.dart';

class Breakpoints {
  static const double mobile = 768;
  static const double tablet = 1024;
  static const double desktop = 1440;
}

class ResponsiveScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget content;
  final List<Widget>? topActions;
  final Widget? floatingActionButton;
  final bool disableInternalScrolling;

  const ResponsiveScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.content,
    this.topActions,
    this.floatingActionButton,
    this.disableInternalScrolling = false,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isWideScreen = width >= Breakpoints.mobile;

    if (!isWideScreen) {
      return AppShell(
        title: title,
        subtitle: subtitle,
        topActions: topActions,
        floatingActionButton: floatingActionButton,
        disableInternalScrolling: disableInternalScrolling,
        content: content,
      );
    }

    return WebShell(
      title: title,
      subtitle: subtitle,
      topActions: topActions,
      floatingActionButton: floatingActionButton,
      child: content,
    );
  }
}
