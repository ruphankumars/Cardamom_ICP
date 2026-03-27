import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// Describes a single column in the [WebDataTable].
class WebTableColumn {
  final String label;
  final String key;
  final double? width;
  final bool sortable;
  final Widget Function(dynamic value, Map<String, dynamic> row)? builder;

  const WebTableColumn({
    required this.label,
    required this.key,
    this.width,
    this.sortable = false,
    this.builder,
  });
}

/// A reusable web-style data table with sorting, loading shimmer,
/// empty state and hover effects.
class WebDataTable extends StatefulWidget {
  final List<WebTableColumn> columns;
  final List<Map<String, dynamic>> rows;
  final bool isLoading;
  final String? emptyMessage;
  final Widget? headerActions;
  final Function(Map<String, dynamic>)? onRowTap;
  final int? sortColumnIndex;
  final bool sortAscending;
  final Function(int, bool)? onSort;

  const WebDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.isLoading = false,
    this.emptyMessage,
    this.headerActions,
    this.onRowTap,
    this.sortColumnIndex,
    this.sortAscending = true,
    this.onSort,
  });

  @override
  State<WebDataTable> createState() => _WebDataTableState();
}

class _WebDataTableState extends State<WebDataTable> {
  int? _hoveredRowIndex;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Optional header actions row
          if (widget.headerActions != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFFE5E7EB)),
                ),
              ),
              child: widget.headerActions!,
            ),

          // Table header row
          _buildHeaderRow(),

          // Table body
          if (widget.isLoading)
            _buildLoadingShimmer()
          else if (widget.rows.isEmpty)
            _buildEmptyState()
          else
            _buildBody(),
        ],
      ),
    );
  }

  // ── Header row ─────────────────────────────────────────────────────────

  Widget _buildHeaderRow() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF1F5F9),
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          for (int i = 0; i < widget.columns.length; i++)
            _buildHeaderCell(widget.columns[i], i),
        ],
      ),
    );
  }

  Widget _buildHeaderCell(WebTableColumn column, int index) {
    final isSorted = widget.sortColumnIndex == index;

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          column.label,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF64748B),
          ),
        ),
        if (column.sortable) ...[
          const SizedBox(width: 4),
          Icon(
            isSorted
                ? (widget.sortAscending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded)
                : Icons.unfold_more_rounded,
            size: 14,
            color: isSorted ? AppTheme.primary : const Color(0xFF94A3B8),
          ),
        ],
      ],
    );

    Widget cell;
    if (column.sortable && widget.onSort != null) {
      cell = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            final ascending =
                widget.sortColumnIndex == index ? !widget.sortAscending : true;
            widget.onSort!(index, ascending);
          },
          child: child,
        ),
      );
    } else {
      cell = child;
    }

    if (column.width != null) {
      return SizedBox(width: column.width, child: cell);
    }
    return Expanded(child: cell);
  }

  // ── Body rows ──────────────────────────────────────────────────────────

  Widget _buildBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < widget.rows.length; i++) _buildRow(i),
      ],
    );
  }

  Widget _buildRow(int index) {
    final row = widget.rows[index];
    final isEven = index % 2 == 0;
    final isHovered = _hoveredRowIndex == index;

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredRowIndex = index),
      onExit: (_) => setState(() => _hoveredRowIndex = null),
      cursor: widget.onRowTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onRowTap != null ? () => widget.onRowTap!(row) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isHovered
                ? const Color(0xFFEEF2FF)
                : isEven
                    ? Colors.white
                    : const Color(0xFFF8F9FA),
            border: const Border(
              bottom: BorderSide(color: Color(0xFFF1F5F9)),
            ),
          ),
          child: Row(
            children: [
              for (final column in widget.columns)
                _buildDataCell(column, row),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDataCell(WebTableColumn column, Map<String, dynamic> row) {
    final value = row[column.key];

    Widget content;
    if (column.builder != null) {
      content = column.builder!(value, row);
    } else {
      content = Text(
        value?.toString() ?? '-',
        style: GoogleFonts.inter(
          fontSize: 13,
          color: AppTheme.title,
        ),
        overflow: TextOverflow.ellipsis,
      );
    }

    if (column.width != null) {
      return SizedBox(width: column.width, child: content);
    }
    return Expanded(child: content);
  }

  // ── Loading shimmer ────────────────────────────────────────────────────

  Widget _buildLoadingShimmer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: index.isEven ? Colors.white : const Color(0xFFF8F9FA),
            border: const Border(
              bottom: BorderSide(color: Color(0xFFF1F5F9)),
            ),
          ),
          child: Row(
            children: [
              for (final column in widget.columns)
                column.width != null
                    ? SizedBox(
                        width: column.width,
                        child: _shimmerBar(),
                      )
                    : Expanded(child: _shimmerBar()),
            ],
          ),
        );
      }),
    );
  }

  Widget _shimmerBar() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: child,
        );
      },
      onEnd: () {
        // The shimmer pulse will restart via the isLoading rebuild cycle
      },
      child: Container(
        height: 14,
        margin: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFE2E8F0),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }

  // ── Empty state ────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_rounded,
              size: 48,
              color: Colors.grey[300],
            ),
            const SizedBox(height: 12),
            Text(
              widget.emptyMessage ?? 'No data available',
              style: GoogleFonts.inter(
                fontSize: 14,
                color: const Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
