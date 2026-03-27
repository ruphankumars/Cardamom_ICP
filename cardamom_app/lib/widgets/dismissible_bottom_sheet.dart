import 'package:flutter/material.dart';

/// A wrapper widget that enables tap-to-dismiss behavior for DraggableScrollableSheet.
/// 
/// Wraps the sheet content in a Stack with a transparent GestureDetector layer
/// that catches taps outside the sheet content and dismisses the bottom sheet.
class DismissibleBottomSheet extends StatelessWidget {
  /// The initial size of the sheet (0.0 to 1.0).
  final double initialChildSize;
  
  /// The minimum size when dragged down (0.0 to 1.0).
  final double minChildSize;
  
  /// The maximum size when dragged up (0.0 to 1.0).
  final double maxChildSize;
  
  /// Builder that creates the sheet content.
  /// Returns a widget that will be displayed inside the draggable sheet.
  final Widget Function(BuildContext context, ScrollController scrollController) builder;
  
  const DismissibleBottomSheet({
    super.key,
    this.initialChildSize = 0.7,
    this.minChildSize = 0.4,
    this.maxChildSize = 0.95,
    required this.builder,
  });
  
  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: initialChildSize,
      minChildSize: minChildSize,
      maxChildSize: maxChildSize,
      expand: false, // Allows native modal barrier to be clicked in empty space
      builder: (context, scrollController) {
        return builder(context, scrollController);
      },
    );
  }
}

/// Helper function to show a dismissible modal bottom sheet.
/// 
/// Use this instead of showModalBottomSheet when you want the user to be able
/// to dismiss the sheet by tapping outside of it.
Future<T?> showDismissibleBottomSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext context, ScrollController scrollController) builder,
  double initialChildSize = 0.7,
  double minChildSize = 0.4,
  double maxChildSize = 0.95,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DismissibleBottomSheet(
      initialChildSize: initialChildSize,
      minChildSize: minChildSize,
      maxChildSize: maxChildSize,
      builder: builder,
    ),
  );
}
