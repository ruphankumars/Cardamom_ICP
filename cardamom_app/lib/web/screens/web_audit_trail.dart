import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/analytics_service.dart';

class WebAuditTrail extends StatefulWidget {
  const WebAuditTrail({super.key});

  @override
  State<WebAuditTrail> createState() => _WebAuditTrailState();
}

class _WebAuditTrailState extends State<WebAuditTrail> {
  final AnalyticsService _analyticsService = AnalyticsService();
  bool _isLoading = true;
  bool _isLoadingMore = false;
  List<AuditLog> _logs = [];
  String? _cursor;
  bool _hasMore = false;

  // Filters
  String _searchQuery = '';
  String _userFilter = '';
  String _actionFilter = '';
  DateTimeRange? _dateRange;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadLogs();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadLogs() async {
    setState(() {
      _isLoading = true;
      _logs = [];
      _cursor = null;
      _hasMore = false;
    });
    try {
      final result = await _analyticsService.getAuditLogsPaginated(limit: 50);
      if (mounted) {
        setState(() {
          _logs = result.logs;
          _cursor = result.cursor;
          _hasMore = result.hasMore;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading audit logs: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _cursor == null) return;
    setState(() => _isLoadingMore = true);
    try {
      final result = await _analyticsService.getAuditLogsPaginated(limit: 50, cursor: _cursor);
      if (mounted) {
        setState(() {
          _logs.addAll(result.logs);
          _cursor = result.cursor;
          _hasMore = result.hasMore;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading more: $e');
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  List<AuditLog> get _filteredLogs {
    return _logs.where((log) {
      final query = _searchQuery.toLowerCase();
      final matchesSearch = query.isEmpty ||
          log.user.toLowerCase().contains(query) ||
          log.action.toLowerCase().contains(query) ||
          log.target.toLowerCase().contains(query);
      final matchesUser = _userFilter.isEmpty || log.user.toLowerCase() == _userFilter.toLowerCase();
      final matchesAction = _actionFilter.isEmpty || log.action == _actionFilter;

      bool matchesDate = true;
      if (_dateRange != null) {
        try {
          final logDate = DateTime.tryParse(log.timestamp);
          if (logDate != null) {
            matchesDate = !logDate.isBefore(_dateRange!.start) &&
                !logDate.isAfter(_dateRange!.end.add(const Duration(days: 1)));
          }
        } catch (_) {}
      }

      return matchesSearch && matchesUser && matchesAction && matchesDate;
    }).toList();
  }

  Set<String> get _uniqueUsers => _logs.map((l) => l.user).where((u) => u.isNotEmpty).toSet();
  Set<String> get _uniqueActions => _logs.map((l) => l.action).where((a) => a.isNotEmpty).toSet();

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: _dateRange,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF5D6E7E)),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _dateRange = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          _buildFilters(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF5D6E7E)))
                : _buildTable(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Audit Trail', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
              const SizedBox(height: 4),
              Text('${_logs.length} activity records', style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
            ],
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _loadLogs,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text('Refresh', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF5D6E7E),
              side: const BorderSide(color: Color(0xFFD1D5DB)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 16),
      color: Colors.white,
      child: Row(
        children: [
          // Search
          SizedBox(
            width: 280,
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search logs...',
                hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                filled: true,
                fillColor: const Color(0xFFF3F4F6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // User filter
          _buildDropdownChip(
            label: _userFilter.isEmpty ? 'All Users' : _userFilter,
            items: ['', ..._uniqueUsers],
            itemLabel: (v) => v.isEmpty ? 'All Users' : v,
            onChanged: (v) => setState(() => _userFilter = v),
          ),
          const SizedBox(width: 12),
          // Action filter
          _buildDropdownChip(
            label: _actionFilter.isEmpty ? 'All Actions' : _actionFilter,
            items: ['', ..._uniqueActions],
            itemLabel: (v) => v.isEmpty ? 'All Actions' : v,
            onChanged: (v) => setState(() => _actionFilter = v),
          ),
          const SizedBox(width: 12),
          // Date range
          OutlinedButton.icon(
            onPressed: _pickDateRange,
            icon: const Icon(Icons.calendar_today, size: 14),
            label: Text(
              _dateRange != null
                  ? '${DateFormat('dd MMM').format(_dateRange!.start)} - ${DateFormat('dd MMM').format(_dateRange!.end)}'
                  : 'Date Range',
              style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF374151),
              side: const BorderSide(color: Color(0xFFD1D5DB)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          if (_dateRange != null) ...[
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => setState(() => _dateRange = null),
              color: const Color(0xFF6B7280),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdownChip({
    required String label,
    required List<String> items,
    required String Function(String) itemLabel,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD1D5DB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.contains(label) ? label : items.first,
          icon: const Icon(Icons.expand_more, size: 16),
          style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
          isDense: true,
          items: items.map((v) => DropdownMenuItem(value: v, child: Text(itemLabel(v)))).toList(),
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }

  Widget _buildTable() {
    final logs = _filteredLogs;
    return Container(
      margin: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      child: Column(
        children: [
          // Table header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F5F9),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            ),
            child: Row(
              children: [
                _th('Timestamp', flex: 3),
                _th('User', flex: 2),
                _th('Action', flex: 2),
                _th('Resource', flex: 3),
                _th('Details', flex: 4),
              ],
            ),
          ),
          // Table body
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.receipt_long_outlined, size: 48, color: Colors.grey[300]),
                        const SizedBox(height: 12),
                        Text('No audit logs found', style: GoogleFonts.inter(color: const Color(0xFF9CA3AF))),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: logs.length + (_isLoadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == logs.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF5D6E7E))),
                        );
                      }
                      return _buildLogRow(logs[index], index);
                    },
                  ),
          ),
          // Pagination footer
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFF1F5F9))),
            ),
            child: Row(
              children: [
                Text(
                  'Showing ${logs.length} of ${_logs.length} records',
                  style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280)),
                ),
                const Spacer(),
                if (_hasMore)
                  TextButton(
                    onPressed: _loadMore,
                    child: Text('Load More', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF5D6E7E))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _th(String text, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Text(text, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280))),
    );
  }

  Widget _buildLogRow(AuditLog log, int index) {
    final color = _getActionColor(log.action);
    String formattedTime = log.timestamp;
    try {
      final dt = DateTime.parse(log.timestamp);
      formattedTime = DateFormat('dd MMM yyyy, HH:mm').format(dt);
    } catch (_) {}

    String details = '';
    if (log.details.containsKey('grade')) {
      details = '${log.details['grade']} - ${log.details['kgs']} kgs';
    } else if (log.details.containsKey('orderData')) {
      final data = log.details['orderData'] is Map ? log.details['orderData'] as Map<String, dynamic> : <String, dynamic>{};
      details = '${data['grade']} - ${data['kgs']} kgs (Lot ${data['lot']})';
    } else if (log.details.isNotEmpty) {
      details = log.details.entries.take(3).map((e) => '${e.key}: ${e.value}').join(', ');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: const Color(0xFFF1F5F9).withOpacity(0.8))),
        color: index.isEven ? Colors.white : const Color(0xFFFAFAFB),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(formattedTime, style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280))),
          ),
          Expanded(
            flex: 2,
            child: Text(log.user, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500, color: const Color(0xFF374151))),
          ),
          Expanded(
            flex: 2,
            child: _buildActionBadge(log.action, color),
          ),
          Expanded(
            flex: 3,
            child: Text(log.target, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF111827))),
          ),
          Expanded(
            flex: 4,
            child: Text(
              details.isNotEmpty ? details : '--',
              style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBadge(String action, Color color) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          action,
          style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.5),
        ),
      ),
    );
  }

  Color _getActionColor(String action) {
    switch (action) {
      case 'CREATE': return const Color(0xFF10B981);
      case 'UPDATE': return const Color(0xFF5D6E7E);
      case 'DELETE': return const Color(0xFFEF4444);
      case 'DISPATCH': return const Color(0xFF3B82F6);
      default: return const Color(0xFF64748B);
    }
  }
}
