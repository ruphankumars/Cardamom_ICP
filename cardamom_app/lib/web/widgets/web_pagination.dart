import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';

class WebPagination extends StatelessWidget {
  final int currentPage;
  final int totalItems;
  final int itemsPerPage;
  final ValueChanged<int> onPageChanged;
  final int maxVisiblePages;

  const WebPagination({
    super.key,
    required this.currentPage,
    required this.totalItems,
    required this.itemsPerPage,
    required this.onPageChanged,
    this.maxVisiblePages = 5,
  });

  int get totalPages => (totalItems / itemsPerPage).ceil();

  int get startItem => totalItems == 0 ? 0 : (currentPage - 1) * itemsPerPage + 1;

  int get endItem {
    final end = currentPage * itemsPerPage;
    return end > totalItems ? totalItems : end;
  }

  @override
  Widget build(BuildContext context) {
    if (totalItems == 0) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Showing $startItem-$endItem of $totalItems',
          style: GoogleFonts.inter(
            fontSize: 13,
            color: AppTheme.muted,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildNavButton(
              icon: Icons.chevron_left_rounded,
              onTap: currentPage > 1
                  ? () => onPageChanged(currentPage - 1)
                  : null,
              label: 'Previous',
            ),
            const SizedBox(width: 4),
            ..._buildPageNumbers(),
            const SizedBox(width: 4),
            _buildNavButton(
              icon: Icons.chevron_right_rounded,
              onTap: currentPage < totalPages
                  ? () => onPageChanged(currentPage + 1)
                  : null,
              label: 'Next',
              iconAfter: true,
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildPageNumbers() {
    final pages = <Widget>[];
    final visiblePages = _getVisiblePages();

    for (int i = 0; i < visiblePages.length; i++) {
      final page = visiblePages[i];

      if (page == -1) {
        pages.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: Text(
                  '...',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppTheme.muted,
                  ),
                ),
              ),
            ),
          ),
        );
      } else {
        final isActive = page == currentPage;
        pages.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              onTap: isActive ? null : () => onPageChanged(page),
              borderRadius: BorderRadius.circular(8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isActive ? AppTheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$page',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    color: isActive ? Colors.white : AppTheme.title,
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    return pages;
  }

  List<int> _getVisiblePages() {
    if (totalPages <= maxVisiblePages) {
      return List.generate(totalPages, (i) => i + 1);
    }

    final pages = <int>[];
    final half = (maxVisiblePages - 2) ~/ 2;

    pages.add(1);

    int start = currentPage - half;
    int end = currentPage + half;

    if (start <= 2) {
      start = 2;
      end = maxVisiblePages - 1;
    }

    if (end >= totalPages) {
      end = totalPages - 1;
      start = totalPages - maxVisiblePages + 2;
    }

    if (start > 2) {
      pages.add(-1); // ellipsis
    }

    for (int i = start; i <= end; i++) {
      pages.add(i);
    }

    if (end < totalPages - 1) {
      pages.add(-1); // ellipsis
    }

    pages.add(totalPages);

    return pages;
  }

  Widget _buildNavButton({
    required IconData icon,
    required VoidCallback? onTap,
    required String label,
    bool iconAfter = false,
  }) {
    final isDisabled = onTap == null;
    final color = isDisabled ? AppTheme.muted.withOpacity(0.3) : AppTheme.title;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: isDisabled
                ? const Color(0xFFE5E7EB).withOpacity(0.5)
                : const Color(0xFFE5E7EB),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!iconAfter)
              Icon(icon, size: 18, color: color),
            if (!iconAfter) const SizedBox(width: 4),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
            if (iconAfter) const SizedBox(width: 4),
            if (iconAfter)
              Icon(icon, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}
