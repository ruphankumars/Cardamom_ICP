import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Pill-shaped segmented tab navigation
class SegmentedTabs extends StatefulWidget {
  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int>? onTabSelected;
  final Color? activeColor;
  final Color? inactiveColor;
  final Color? backgroundColor;
  final double height;

  const SegmentedTabs({
    super.key,
    required this.tabs,
    this.selectedIndex = 0,
    this.onTabSelected,
    this.activeColor,
    this.inactiveColor,
    this.backgroundColor,
    this.height = 44,
  });

  @override
  State<SegmentedTabs> createState() => _SegmentedTabsState();
}

class _SegmentedTabsState extends State<SegmentedTabs> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.selectedIndex;
  }

  @override
  void didUpdateWidget(SegmentedTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _selectedIndex = widget.selectedIndex;
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.activeColor ?? const Color(0xFF5D6E7E); // AppTheme.primary
    final inactiveColor = widget.inactiveColor ?? const Color(0xFF5D6E7E).withOpacity(0.6);
    final bgColor = widget.backgroundColor ?? const Color(0xFFA8A8A1).withOpacity(0.3); // titaniumDark recessed

    return Container(
      height: widget.height,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(widget.height / 2),
      ),
      child: Row(
        children: widget.tabs.asMap().entries.map((entry) {
          final index = entry.key;
          final label = entry.value;
          final isSelected = index == _selectedIndex;

          return Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() {
                  _selectedIndex = index;
                });
                widget.onTabSelected?.call(index);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: isSelected ? activeColor : Colors.transparent,
                  borderRadius: BorderRadius.circular((widget.height - 8) / 2),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: activeColor.withOpacity(0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected ? Colors.white : inactiveColor,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Icon-based segmented tabs
class IconSegmentedTabs extends StatefulWidget {
  final List<IconData> icons;
  final List<String>? labels;
  final int selectedIndex;
  final ValueChanged<int>? onTabSelected;
  final Color? activeColor;

  const IconSegmentedTabs({
    super.key,
    required this.icons,
    this.labels,
    this.selectedIndex = 0,
    this.onTabSelected,
    this.activeColor,
  });

  @override
  State<IconSegmentedTabs> createState() => _IconSegmentedTabsState();
}

class _IconSegmentedTabsState extends State<IconSegmentedTabs> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.selectedIndex;
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.activeColor ?? const Color(0xFF5D6E7E); // AppTheme.primary

    return Container(
      height: 56,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFA8A8A1).withOpacity(0.3), // titaniumDark recessed
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: widget.icons.asMap().entries.map((entry) {
          final index = entry.key;
          final icon = entry.value;
          final label = widget.labels != null && index < widget.labels!.length
              ? widget.labels![index]
              : null;
          final isSelected = index == _selectedIndex;

          return Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() {
                  _selectedIndex = index;
                });
                widget.onTabSelected?.call(index);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: isSelected
                      ? activeColor.withOpacity(0.2)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: isSelected
                          ? activeColor
                          : Colors.white.withOpacity(0.5),
                    ),
                    if (label != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w400,
                          color: isSelected
                              ? activeColor
                              : Colors.white.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
