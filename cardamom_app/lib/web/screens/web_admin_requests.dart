import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

class WebAdminRequests extends StatefulWidget {
  const WebAdminRequests({super.key});

  @override
  State<WebAdminRequests> createState() => _WebAdminRequestsState();
}

class _WebAdminRequestsState extends State<WebAdminRequests> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _requests = [];

  // Pagination
  String? _cursor;
  bool _hasMore = false;
  bool _isLoadingMore = false;

  // Filters
  String _statusFilter = '';
  String _typeFilter = '';
  String _clientSearch = '';
  Timer? _debounceTimer;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadRequests();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadRequests() async {
    setState(() {
      _isLoading = true;
      _requests = [];
      _cursor = null;
      _hasMore = false;
    });
    await _loadPage();
  }

  Future<void> _loadPage() async {
    try {
      final cleanFilters = <String, dynamic>{};
      if (_statusFilter.isNotEmpty) cleanFilters['status'] = _statusFilter;
      if (_typeFilter.isNotEmpty) cleanFilters['type'] = _typeFilter;
      if (_clientSearch.isNotEmpty) cleanFilters['client'] = _clientSearch;

      final response = await _apiService.getAllRequestsPaginated(
        limit: 25,
        cursor: _cursor,
        filters: cleanFilters.isNotEmpty ? cleanFilters : null,
      );
      if (mounted) {
        final data = response.data as Map<String, dynamic>;
        final newRequests = (data['requests'] as List?) ?? [];
        final pagination = data['pagination'] as Map<String, dynamic>? ?? {};
        setState(() {
          if (_cursor == null) {
            _requests = newRequests;
          } else {
            _requests.addAll(newRequests);
          }
          _cursor = pagination['cursor'] as String?;
          _hasMore = pagination['hasMore'] as bool? ?? false;
          _isLoadingMore = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading requests: $e');
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    await _loadPage();
  }

  void _applyFilters() {
    _loadRequests();
  }

  // Stats
  int get _totalCount => _requests.length;
  int get _openCount => _requests.where((r) => r['status'] == 'OPEN').length;
  int get _negotiatingCount => _requests.where((r) =>
      r['status'] == 'ADMIN_SENT' || r['status'] == 'CLIENT_DRAFT' ||
      r['status'] == 'CLIENT_SENT' || r['status'] == 'ADMIN_DRAFT').length;
  int get _agreedCount => _requests.where((r) =>
      r['status'] == 'CONFIRMED' || r['status'] == 'CONVERTED_TO_ORDER').length;

  String _formatDate(dynamic dateStr) {
    if (dateStr == null) return '--';
    try {
      final raw = dateStr.toString();
      if (raw.contains('/')) return raw;
      final date = DateTime.parse(raw);
      return DateFormat('dd/MM/yy').format(date);
    } catch (e) {
      return dateStr.toString().split('T')[0];
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
          _buildStatsBar(),
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
              Text('Order Requests', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
              const SizedBox(height: 4),
              Text('Manage client order requests and price enquiries', style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
            ],
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _loadRequests,
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
          // Status dropdown
          _buildFilterDropdown(
            label: 'Status',
            value: _statusFilter,
            items: const [
              {'label': 'All Status', 'value': ''},
              {'label': 'Open', 'value': 'OPEN'},
              {'label': 'Admin Sent', 'value': 'ADMIN_SENT'},
              {'label': 'Client Sent', 'value': 'CLIENT_SENT'},
              {'label': 'Confirmed', 'value': 'CONFIRMED'},
              {'label': 'Cancelled', 'value': 'CANCELLED'},
              {'label': 'Admin Draft', 'value': 'ADMIN_DRAFT'},
            ],
            onChanged: (v) {
              setState(() => _statusFilter = v);
              _applyFilters();
            },
          ),
          const SizedBox(width: 12),
          // Type dropdown
          _buildFilterDropdown(
            label: 'Type',
            value: _typeFilter,
            items: const [
              {'label': 'All Types', 'value': ''},
              {'label': 'Order Request', 'value': 'REQUEST_ORDER'},
              {'label': 'Price Enquiry', 'value': 'ENQUIRE_PRICE'},
            ],
            onChanged: (v) {
              setState(() => _typeFilter = v);
              _applyFilters();
            },
          ),
          const SizedBox(width: 12),
          // Client search
          SizedBox(
            width: 240,
            child: TextField(
              onChanged: (v) {
                _clientSearch = v;
                _debounceTimer?.cancel();
                _debounceTimer = Timer(const Duration(milliseconds: 400), _applyFilters);
              },
              decoration: InputDecoration(
                hintText: 'Search by client...',
                hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                filled: true,
                fillColor: const Color(0xFFF3F4F6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterDropdown({
    required String label,
    required String value,
    required List<Map<String, String>> items,
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
          value: value,
          icon: const Icon(Icons.expand_more, size: 16),
          style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
          isDense: true,
          items: items.map((e) => DropdownMenuItem(value: e['value']!, child: Text(e['label']!))).toList(),
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }

  Widget _buildStatsBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 12),
      child: Row(
        children: [
          _buildStatChip('Total', _totalCount, const Color(0xFF5D6E7E)),
          const SizedBox(width: 12),
          _buildStatChip('Open', _openCount, const Color(0xFF3B82F6)),
          const SizedBox(width: 12),
          _buildStatChip('Negotiating', _negotiatingCount, const Color(0xFFF59E0B)),
          const SizedBox(width: 12),
          _buildStatChip('Agreed', _agreedCount, const Color(0xFF22C55E)),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, color: const Color(0xFF6B7280))),
          const SizedBox(width: 8),
          Text('$value', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
        ],
      ),
    );
  }

  Widget _buildTable() {
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
                _th('ID', flex: 2),
                _th('Date', flex: 2),
                _th('Client', flex: 3),
                _th('Type', flex: 2),
                _th('Items', flex: 1),
                _th('Version', flex: 1),
                _th('Status', flex: 2),
                _th('Actions', flex: 2),
              ],
            ),
          ),
          Expanded(
            child: _requests.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.request_page_outlined, size: 48, color: Colors.grey[300]),
                        const SizedBox(height: 12),
                        Text('No requests found', style: GoogleFonts.inter(color: const Color(0xFF9CA3AF))),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _requests.length + (_isLoadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _requests.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF5D6E7E))),
                        );
                      }
                      return _buildRequestRow(_requests[index], index);
                    },
                  ),
          ),
          // Footer
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFF1F5F9))),
            ),
            child: Row(
              children: [
                Text(
                  'Showing ${_requests.length} requests',
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

  Widget _buildRequestRow(Map<String, dynamic> req, int index) {
    final status = req['status']?.toString() ?? 'OPEN';
    final type = req['requestType']?.toString() ?? 'REQUEST_ORDER';
    final isEnquiry = type == 'ENQUIRE_PRICE';
    final currentItems = (req['currentItems'] as List?) ?? (req['requestedItems'] as List?) ?? [];
    final panelVersion = req['panelVersion'] ?? 1;

    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/negotiation', arguments: {'id': req['requestId']}),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: const Color(0xFFF1F5F9).withOpacity(0.8))),
          color: index.isEven ? Colors.white : const Color(0xFFFAFAFB),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                req['requestId'] ?? 'REQ-000',
                style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: const Color(0xFF111827)),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                _formatDate(req['createdAt']),
                style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280)),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                req['clientName'] ?? 'Unknown',
                style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500, color: const Color(0xFF374151)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: _buildTypeBadge(isEnquiry),
            ),
            Expanded(
              flex: 1,
              child: Text('${currentItems.length}', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
            ),
            Expanded(
              flex: 1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF5D6E7E).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'v$panelVersion',
                  style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: const Color(0xFF5D6E7E)),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: _buildStatusBadge(status),
            ),
            Expanded(
              flex: 2,
              child: Row(
                children: [
                  InkWell(
                    onTap: () => Navigator.pushNamed(context, '/negotiation', arguments: {'id': req['requestId']}),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3B82F6).withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.12)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.forum_outlined, size: 14, color: Color(0xFF3B82F6)),
                          const SizedBox(width: 4),
                          Text('View', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: const Color(0xFF3B82F6))),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeBadge(bool isEnquiry) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isEnquiry ? const Color(0xFF8B5CF6).withOpacity(0.1) : const Color(0xFF3B82F6).withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          isEnquiry ? 'Enquiry' : 'Order',
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: isEnquiry ? const Color(0xFF8B5CF6) : const Color(0xFF3B82F6),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color color;
    switch (status.toUpperCase()) {
      case 'OPEN': color = const Color(0xFF5D6E7E); break;
      case 'ADMIN_SENT': color = const Color(0xFFF97316); break;
      case 'CLIENT_DRAFT': color = const Color(0xFFEAB308); break;
      case 'CLIENT_SENT': color = const Color(0xFFA855F7); break;
      case 'CONFIRMED': color = const Color(0xFF10B981); break;
      case 'CANCELLED': color = const Color(0xFFEF4444); break;
      case 'REJECTED': color = const Color(0xFFEF4444); break;
      case 'CONVERTED_TO_ORDER': color = const Color(0xFF64748B); break;
      case 'ADMIN_DRAFT': color = const Color(0xFF6366F1); break;
      default: color = Colors.grey;
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          status.replaceAll('_', ' '),
          style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.3),
        ),
      ),
    );
  }
}
