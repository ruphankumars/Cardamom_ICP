import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';

class WebFilterItem {
  final String label;
  final String? value;
  final List<String> options;

  const WebFilterItem({
    required this.label,
    this.value,
    required this.options,
  });

  WebFilterItem copyWith({String? value}) {
    return WebFilterItem(
      label: label,
      value: value,
      options: options,
    );
  }
}

class WebFilterPanel extends StatelessWidget {
  final List<WebFilterItem> filters;
  final ValueChanged<List<WebFilterItem>> onFiltersChanged;
  final VoidCallback? onClearAll;

  const WebFilterPanel({
    super.key,
    required this.filters,
    required this.onFiltersChanged,
    this.onClearAll,
  });

  bool get _hasActiveFilters => filters.any((f) => f.value != null);

  void _onFilterChanged(int index, String? newValue) {
    final updated = List<WebFilterItem>.from(filters);
    updated[index] = updated[index].copyWith(value: newValue);
    onFiltersChanged(updated);
  }

  void _clearAll() {
    if (onClearAll != null) {
      onClearAll!();
    } else {
      final cleared = filters
          .map((f) => WebFilterItem(
                label: f.label,
                value: null,
                options: f.options,
              ))
          .toList();
      onFiltersChanged(cleared);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ...filters.asMap().entries.map((entry) {
            final index = entry.key;
            final filter = entry.value;
            return Padding(
              padding: EdgeInsets.only(
                right: index < filters.length - 1 ? 12 : 0,
              ),
              child: _buildFilterDropdown(filter, index),
            );
          }),
          if (_hasActiveFilters) ...[
            const SizedBox(width: 12),
            _buildClearAllButton(),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterDropdown(WebFilterItem filter, int index) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: filter.value != null
              ? AppTheme.primary.withOpacity(0.4)
              : const Color(0xFFE5E7EB),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: filter.value,
          hint: Text(
            filter.label,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppTheme.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: AppTheme.muted.withOpacity(0.6),
            size: 20,
          ),
          isDense: true,
          style: GoogleFonts.inter(
            fontSize: 13,
            color: AppTheme.title,
            fontWeight: FontWeight.w500,
          ),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(8),
          items: [
            DropdownMenuItem<String>(
              value: null,
              child: Text(
                'All ${filter.label}',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppTheme.muted,
                ),
              ),
            ),
            ...filter.options.map((option) {
              return DropdownMenuItem<String>(
                value: option,
                child: Text(option),
              );
            }),
          ],
          onChanged: (value) => _onFilterChanged(index, value),
        ),
      ),
    );
  }

  Widget _buildClearAllButton() {
    return AnimatedOpacity(
      opacity: _hasActiveFilters ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: TextButton.icon(
        onPressed: _clearAll,
        icon: const Icon(Icons.clear_all_rounded, size: 18),
        label: Text(
          'Clear all',
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        style: TextButton.styleFrom(
          foregroundColor: AppTheme.danger,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}
