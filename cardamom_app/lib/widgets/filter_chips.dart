import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A single filter chip with optional close button
class FilterChipItem extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final Color? selectedColor;
  final IconData? icon;

  const FilterChipItem({
    super.key,
    required this.label,
    this.isSelected = false,
    this.onTap,
    this.onRemove,
    this.selectedColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final color = selectedColor ?? const Color(0xFF5D6E7E);

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap?.call();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: isSelected ? 12 : 14,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: isSelected ? color : Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : Colors.white.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: isSelected ? Colors.white : Colors.white.withOpacity(0.7),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? Colors.white : Colors.white.withOpacity(0.8),
              ),
            ),
            if (isSelected && onRemove != null) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  onRemove?.call();
                },
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Horizontal scrollable filter chips row
class FilterChipsRow extends StatelessWidget {
  final List<String> filters;
  final Set<String> selectedFilters;
  final ValueChanged<String>? onFilterTap;
  final ValueChanged<String>? onFilterRemove;
  final Color? selectedColor;
  final EdgeInsets? padding;

  const FilterChipsRow({
    super.key,
    required this.filters,
    required this.selectedFilters,
    this.onFilterTap,
    this.onFilterRemove,
    this.selectedColor,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: filters.map((filter) {
          final isSelected = selectedFilters.contains(filter);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChipItem(
              label: filter,
              isSelected: isSelected,
              selectedColor: selectedColor,
              onTap: () => onFilterTap?.call(filter),
              onRemove: isSelected ? () => onFilterRemove?.call(filter) : null,
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Pre-configured filter chip sets for common use cases
class GradeFilterChips extends StatelessWidget {
  final Set<String> selectedGrades;
  final ValueChanged<String>? onGradeToggle;

  const GradeFilterChips({
    super.key,
    required this.selectedGrades,
    this.onGradeToggle,
  });

  static const grades = [
    '8 mm',
    '7.8 bold',
    '7.5 to 8 mm',
    '7 to 8 mm',
    '6.5 to 8 mm',
    '6.5 to 7 mm',
    '6 to 7 mm',
    'Mini Bold',
    'Pan',
  ];

  @override
  Widget build(BuildContext context) {
    return FilterChipsRow(
      filters: grades,
      selectedFilters: selectedGrades,
      onFilterTap: onGradeToggle,
      onFilterRemove: onGradeToggle,
      selectedColor: const Color(0xFF10B981),
    );
  }
}

/// Type filter chips (Colour Bold, Fruit Bold, Rejection)
class TypeFilterChips extends StatelessWidget {
  final Set<String> selectedTypes;
  final ValueChanged<String>? onTypeToggle;

  const TypeFilterChips({
    super.key,
    required this.selectedTypes,
    this.onTypeToggle,
  });

  static const types = ['Colour Bold', 'Fruit Bold', 'Rejection'];

  @override
  Widget build(BuildContext context) {
    return FilterChipsRow(
      filters: types,
      selectedFilters: selectedTypes,
      onFilterTap: onTypeToggle,
      onFilterRemove: onTypeToggle,
      selectedColor: const Color(0xFF5D6E7E),
    );
  }
}
