import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

class WebMyRequests extends StatefulWidget {
  const WebMyRequests({super.key});

  @override
  State<WebMyRequests> createState() => _WebMyRequestsState();
}

class _WebMyRequestsState extends State<WebMyRequests> with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _cardRadius = 12.0;

  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;
  List<dynamic> _allRequests = [];

  late TabController _tabController;
  static const _tabs = ['All', 'Open', 'Negotiating', 'Confirmed', 'Cancelled'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    _loadRequests();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadRequests() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await _apiService.getMyRequests();
      if (!mounted) return;
      setState(() {
        _allRequests = response.data['requests'] ?? [];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load requests: $e';
        _isLoading = false;
      });
    }
  }

  List<dynamic> get _filteredRequests {
    switch (_tabController.index) {
      case 1: // Open
        return _allRequests.where((r) => r['status'] == 'OPEN').toList();
      case 2: // Negotiating
        return _allRequests.where((r) =>
            r['status'] == 'ADMIN_SENT' ||
            r['status'] == 'CLIENT_DRAFT' ||
            r['status'] == 'CLIENT_SENT' ||
            r['status'] == 'ADMIN_DRAFT').toList();
      case 3: // Confirmed
        return _allRequests.where((r) =>
            r['status'] == 'CONFIRMED' || r['status'] == 'CONVERTED_TO_ORDER').toList();
      case 4: // Cancelled
        return _allRequests.where((r) =>
            r['status'] == 'CANCELLED' || r['status'] == 'REJECTED').toList();
      default:
        return _allRequests;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : _error != null
              ? _buildError()
              : RefreshIndicator(
                  onRefresh: _loadRequests,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(),
                        const SizedBox(height: 24),
                        _buildFilterTabs(),
                        const SizedBox(height: 20),
                        _buildRequestsTable(),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
          const SizedBox(height: 16),
          Text(_error!, style: GoogleFonts.inter(fontSize: 14, color: Colors.red.shade700)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadRequests,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Retry', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_cardRadius)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('My Requests', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: const Color(0xFF1A1A2E))),
            const SizedBox(height: 4),
            Text(
              'View and track your order requests and price enquiries',
              style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280)),
            ),
          ],
        ),
        const Spacer(),
        // Count
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${_allRequests.length} total',
            style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _primary),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _loadRequests,
          icon: const Icon(Icons.refresh, color: _primary),
          tooltip: 'Refresh',
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_cardRadius),
              side: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterTabs() {
    final counts = [
      _allRequests.length,
      _allRequests.where((r) => r['status'] == 'OPEN').length,
      _allRequests.where((r) => ['ADMIN_SENT', 'CLIENT_DRAFT', 'CLIENT_SENT', 'ADMIN_DRAFT'].contains(r['status'])).length,
      _allRequests.where((r) => r['status'] == 'CONFIRMED' || r['status'] == 'CONVERTED_TO_ORDER').length,
      _allRequests.where((r) => r['status'] == 'CANCELLED' || r['status'] == 'REJECTED').length,
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_tabs.length, (i) {
          final selected = _tabController.index == i;
          return GestureDetector(
            onTap: () => _tabController.animateTo(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? _primary : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _tabs[i],
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : const Color(0xFF6B7280),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: selected ? Colors.white.withOpacity(0.2) : const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${counts[i]}',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: selected ? Colors.white : const Color(0xFF6B7280),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildRequestsTable() {
    final filtered = _filteredRequests;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        children: [
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(48),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.inbox_rounded, size: 48, color: Colors.grey.shade300),
                    const SizedBox(height: 12),
                    Text('No requests found', style: GoogleFonts.inter(fontSize: 15, color: const Color(0xFF6B7280))),
                    const SizedBox(height: 4),
                    Text(
                      'Requests matching this filter will appear here',
                      style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            _buildTableHeader(),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            ...filtered.map((req) => _buildTableRow(req)),
          ],
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    const style = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: const [
          Expanded(flex: 2, child: Text('Request ID', style: style)),
          Expanded(flex: 2, child: Text('Type', style: style)),
          Expanded(flex: 2, child: Text('Status', style: style)),
          Expanded(flex: 1, child: Text('Items', style: style)),
          Expanded(flex: 2, child: Text('Created', style: style)),
          Expanded(flex: 2, child: Text('Last Updated', style: style)),
          Expanded(flex: 1, child: Text('Action', style: style)),
        ],
      ),
    );
  }

  Widget _buildTableRow(dynamic req) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/negotiation', arguments: {'id': req['requestId']}),
      hoverColor: const Color(0xFFF9FAFB),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Text(
                    'REQ-${(req['requestId'] ?? '').toString().split('-').last}',
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _primary, decoration: TextDecoration.underline),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Row(
                    children: [
                      Icon(
                        req['requestType'] == 'ENQUIRE_PRICE' ? Icons.currency_rupee : Icons.inventory_2,
                        size: 14,
                        color: const Color(0xFF6B7280),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        req['requestType'] == 'ENQUIRE_PRICE' ? 'Price Enquiry' : 'Order Request',
                        style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF4A5568)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Align(alignment: Alignment.centerLeft, child: _StatusBadge(status: req['status'] ?? 'OPEN')),
                ),
                Expanded(
                  flex: 1,
                  child: Text(
                    '${((req['requestedItems'] as List?) ?? []).length}',
                    style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B)),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    _formatDate(req['createdAt']),
                    style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B)),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    _formatDate(req['updatedAt']),
                    style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B)),
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.chat_bubble_outline, size: 12, color: Color(0xFF64748B)),
                        const SizedBox(width: 6),
                        Text('View', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF475569))),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF1F5F9)),
        ],
      ),
    );
  }

  String _formatDate(dynamic dateStr) {
    if (dateStr == null) return '--';
    try {
      final raw = dateStr.toString();
      if (raw.contains('/')) return raw;
      final date = DateTime.parse(raw);
      return DateFormat('dd MMM yyyy, HH:mm').format(date);
    } catch (_) {
      return dateStr.toString().split('T').first;
    }
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = switch (status.toUpperCase()) {
      'OPEN' => (const Color(0xFF3B82F6), 'Open'),
      'ADMIN_SENT' => (const Color(0xFFF97316), 'Admin Sent'),
      'ADMIN_DRAFT' => (const Color(0xFF6366F1), 'Admin Draft'),
      'CLIENT_DRAFT' => (const Color(0xFFEAB308), 'Draft'),
      'CLIENT_SENT' => (const Color(0xFFA855F7), 'Client Sent'),
      'CONFIRMED' => (const Color(0xFF10B981), 'Confirmed'),
      'CONVERTED_TO_ORDER' => (const Color(0xFF6B7280), 'Converted'),
      'CANCELLED' => (const Color(0xFFEF4444), 'Cancelled'),
      'REJECTED' => (const Color(0xFF7F1D1D), 'Rejected'),
      _ => (Colors.grey, status.replaceAll('_', ' ')),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
