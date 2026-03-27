import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

class WebNegotiation extends StatefulWidget {
  final String? requestId;

  const WebNegotiation({super.key, this.requestId});

  @override
  State<WebNegotiation> createState() => _WebNegotiationState();
}

class _WebNegotiationState extends State<WebNegotiation> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  bool _isActionLoading = false;

  // Request data
  Map<String, dynamic> _request = {};
  List<dynamic> _chatHistory = [];
  String _userRole = 'user';

  // Negotiation form
  final _counterPriceController = TextEditingController();
  final _counterNotesController = TextEditingController();

  // Request list (when no requestId is provided)
  List<dynamic> _requests = [];
  String? _selectedRequestId;

  // Filters
  String _statusFilter = '';
  String _searchQuery = '';
  final _searchController = TextEditingController();

  static const Map<String, Color> _statusColors = {
    'Open': Color(0xFF3B82F6),
    'Admin Sent': Color(0xFFF97316),
    'Client Draft': Color(0xFFEAB308),
    'Client Sent': Color(0xFFA855F7),
    'Confirmed': Color(0xFF10B981),
    'Cancelled': Color(0xFFEF4444),
    'Converted': Color(0xFF6B7280),
    'Admin Draft': Color(0xFF6366F1),
  };

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _counterPriceController.dispose();
    _counterNotesController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';
    } catch (_) {}

    if (widget.requestId != null) {
      _selectedRequestId = widget.requestId;
      await _loadRequestDetails(widget.requestId!);
    } else {
      await _loadRequests();
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadRequests() async {
    try {
      final response = await _apiService.getAllRequests();
      if (!mounted) return;
      final data = response.data;
      if (data is List) {
        _requests = data;
      } else if (data is Map && data.containsKey('requests')) {
        _requests = data['requests'] ?? [];
      } else {
        _requests = [];
      }
    } catch (e) {
      debugPrint('Error loading requests: $e');
    }
  }

  Future<void> _loadRequestDetails(String requestId) async {
    try {
      final results = await Future.wait([
        _apiService.getRequest(requestId),
        _apiService.getRequestChat(requestId),
      ]);
      if (!mounted) return;
      _request = Map<String, dynamic>.from(results[0].data ?? {});
      final chatData = results[1].data;
      if (chatData is List) {
        _chatHistory = chatData;
      } else if (chatData is Map && chatData.containsKey('messages')) {
        _chatHistory = chatData['messages'] ?? [];
      } else {
        _chatHistory = [];
      }
    } catch (e) {
      debugPrint('Error loading request details: $e');
    }
  }

  Future<void> _updateStatus(String status) async {
    if (_selectedRequestId == null) return;
    setState(() => _isActionLoading = true);
    try {
      await _apiService.updateRequestStatus(_selectedRequestId!, status);
      await _loadRequestDetails(_selectedRequestId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Request $status'),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
    if (mounted) setState(() => _isActionLoading = false);
  }

  Future<void> _sendCounterOffer() async {
    if (_selectedRequestId == null) return;
    final price = double.tryParse(_counterPriceController.text);
    if (price == null || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid counter price'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    setState(() => _isActionLoading = true);
    try {
      await _apiService.sendNegotiationMessage(
        _selectedRequestId!,
        'Counter offer: ${_counterPriceController.text} - ${_counterNotesController.text}',
      );
      _counterPriceController.clear();
      _counterNotesController.clear();
      await _loadRequestDetails(_selectedRequestId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Counter offer sent'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
    if (mounted) setState(() => _isActionLoading = false);
  }

  List<dynamic> get _filteredRequests {
    var list = List.from(_requests);
    if (_statusFilter.isNotEmpty) {
      list = list
          .where((r) =>
              (r['status'] ?? '').toString().toLowerCase() ==
              _statusFilter.toLowerCase())
          .toList();
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((r) {
        final client = (r['client'] ?? r['clientName'] ?? '').toString().toLowerCase();
        final grade = (r['grade'] ?? '').toString().toLowerCase();
        return client.contains(q) || grade.contains(q);
      }).toList();
    }
    return list;
  }

  Color _statusColor(String status) {
    return _statusColors[status] ?? const Color(0xFF6B7280);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF5D6E7E)))
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 20),
                  Expanded(child: _buildContent()),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        if (_selectedRequestId != null && widget.requestId == null)
          IconButton(
            onPressed: () {
              setState(() {
                _selectedRequestId = null;
                _request = {};
                _chatHistory = [];
              });
            },
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
        Text(
          _selectedRequestId != null ? 'Negotiation' : 'Negotiations',
          style: GoogleFonts.manrope(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF1E293B),
          ),
        ),
        const Spacer(),
        if (_selectedRequestId != null && _request['status'] != null)
          _buildStatusBadge(_request['status'].toString()),
      ],
    );
  }

  Widget _buildContent() {
    if (_selectedRequestId != null) {
      return _buildSplitPanel();
    }
    return _buildRequestList();
  }

  // --- Request List View ---

  Widget _buildRequestList() {
    return Column(
      children: [
        _buildRequestFilters(),
        const SizedBox(height: 16),
        Expanded(child: _buildRequestTable()),
      ],
    );
  }

  Widget _buildRequestFilters() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              style: GoogleFonts.inter(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search by client or grade...',
                hintStyle: GoogleFonts.inter(
                    fontSize: 13, color: const Color(0xFF94A3B8)),
                prefixIcon: const Icon(Icons.search,
                    size: 18, color: Color(0xFF94A3B8)),
                filled: true,
                fillColor: const Color(0xFFF8F9FA),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF5D6E7E), width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _statusFilter.isEmpty ? null : _statusFilter,
                  hint: Text('All Statuses',
                      style: GoogleFonts.inter(
                          fontSize: 13, color: const Color(0xFF94A3B8))),
                  isExpanded: true,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  style: GoogleFonts.inter(
                      fontSize: 13, color: const Color(0xFF1E293B)),
                  items: [
                    DropdownMenuItem<String>(
                      value: null,
                      child: Text('All Statuses',
                          style: GoogleFonts.inter(
                              fontSize: 13, color: const Color(0xFF94A3B8))),
                    ),
                    ..._statusColors.keys.map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(s),
                        )),
                  ],
                  onChanged: (v) => setState(() => _statusFilter = v ?? ''),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestTable() {
    final reqs = _filteredRequests;
    if (reqs.isEmpty) {
      return _emptyState('No requests found');
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ListView.separated(
          itemCount: reqs.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Color(0xFFF1F5F9)),
          itemBuilder: (ctx, i) {
            final r = reqs[i];
            final id = (r['_id'] ?? r['id'] ?? '').toString();
            final client =
                (r['client'] ?? r['clientName'] ?? 'Unknown').toString();
            final status = (r['status'] ?? 'Open').toString();
            final items = r['items'] is List ? r['items'] as List : [];
            final grades = items
                .map((item) => (item['grade'] ?? '').toString())
                .where((g) => g.isNotEmpty)
                .join(', ');
            final createdAt =
                (r['createdAt'] ?? r['created_at'] ?? '').toString();

            return InkWell(
              onTap: () async {
                setState(() {
                  _isLoading = true;
                  _selectedRequestId = id;
                });
                await _loadRequestDetails(id);
                if (mounted) setState(() => _isLoading = false);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            client,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF1E293B),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            grades.isNotEmpty
                                ? grades
                                : '${items.length} item(s)',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        _formatDate(createdAt),
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: const Color(0xFF64748B),
                        ),
                      ),
                    ),
                    _buildStatusBadge(status),
                    const SizedBox(width: 12),
                    const Icon(Icons.chevron_right,
                        size: 18, color: Color(0xFF94A3B8)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // --- Split Panel View ---

  Widget _buildSplitPanel() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 5, child: _buildDetailsPanel()),
        const SizedBox(width: 20),
        Expanded(flex: 4, child: _buildNegotiationPanel()),
      ],
    );
  }

  Widget _buildDetailsPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Request Details',
              style: GoogleFonts.manrope(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 20),

            // Client info row
            _detailRow(
                'Client', (_request['client'] ?? _request['clientName'] ?? 'N/A').toString()),
            _detailRow('Status', _request['status']?.toString() ?? 'Open'),
            _detailRow(
                'Created',
                _formatDate(
                    (_request['createdAt'] ?? _request['created_at'] ?? '')
                        .toString())),
            if (_request['notes'] != null &&
                _request['notes'].toString().isNotEmpty)
              _detailRow('Notes', _request['notes'].toString()),

            const SizedBox(height: 20),
            const Divider(color: Color(0xFFF1F5F9)),
            const SizedBox(height: 16),

            // Items
            Text(
              'Items',
              style: GoogleFonts.manrope(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            _buildItemsTable(),

            const SizedBox(height: 24),
            const Divider(color: Color(0xFFF1F5F9)),
            const SizedBox(height: 16),

            // Chat history
            Text(
              'History',
              style: GoogleFonts.manrope(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            _buildChatHistory(),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF64748B),
              ),
            ),
          ),
          Expanded(
            child: label == 'Status'
                ? _buildStatusBadge(value)
                : Text(
                    value,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF1E293B),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsTable() {
    final items = _request['items'];
    if (items is! List || items.isEmpty) {
      return Text(
        'No items',
        style: GoogleFonts.inter(
          fontSize: 13,
          color: const Color(0xFF94A3B8),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            color: const Color(0xFFF1F5F9),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                _tableHeader('Grade', flex: 2),
                _tableHeader('Qty', flex: 1),
                _tableHeader('Price', flex: 1),
                _tableHeader('Status', flex: 1),
              ],
            ),
          ),
          // Rows
          ...items.map((item) {
            final grade = (item['grade'] ?? '').toString();
            final qty = (item['requestedKgs'] ??
                    item['offeredKgs'] ??
                    item['kgs'] ??
                    0)
                .toString();
            final price =
                (item['unitPrice'] ?? item['price'] ?? 0).toString();
            final itemStatus =
                (item['status'] ?? _request['status'] ?? '').toString();

            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(grade,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF1E293B),
                        )),
                  ),
                  Expanded(
                    flex: 1,
                    child: Text('$qty kg',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: const Color(0xFF475569),
                        )),
                  ),
                  Expanded(
                    flex: 1,
                    child: Text(price,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: const Color(0xFF475569),
                        )),
                  ),
                  Expanded(
                    flex: 1,
                    child: _buildStatusBadge(itemStatus, small: true),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _tableHeader(String text, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF475569),
        ),
      ),
    );
  }

  Widget _buildChatHistory() {
    if (_chatHistory.isEmpty) {
      return Text(
        'No messages yet',
        style: GoogleFonts.inter(
          fontSize: 13,
          color: const Color(0xFF94A3B8),
        ),
      );
    }

    return Column(
      children: _chatHistory.map<Widget>((msg) {
        final sender = (msg['sender'] ?? msg['from'] ?? 'System').toString();
        final text = (msg['text'] ?? msg['message'] ?? '').toString();
        final time = (msg['createdAt'] ?? msg['timestamp'] ?? '').toString();
        final isAdmin = sender.toLowerCase().contains('admin');

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isAdmin
                ? const Color(0xFFF0F7FF)
                : const Color(0xFFF8F9FA),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isAdmin
                  ? const Color(0xFF3B82F6).withOpacity(0.15)
                  : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    sender,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isAdmin
                          ? const Color(0xFF3B82F6)
                          : const Color(0xFF475569),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatDate(time),
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                text,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: const Color(0xFF334155),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildNegotiationPanel() {
    final status = (_request['status'] ?? 'Open').toString();
    final isClosed = status == 'Confirmed' ||
        status == 'Cancelled' ||
        status == 'Converted';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Negotiation',
              style: GoogleFonts.manrope(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 20),

            if (isClosed) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: status == 'Confirmed'
                      ? const Color(0xFFF0FDF4)
                      : status == 'Cancelled'
                          ? const Color(0xFFFEF2F2)
                          : const Color(0xFFF8F9FA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Icon(
                      status == 'Confirmed'
                          ? Icons.check_circle_outline
                          : status == 'Cancelled'
                              ? Icons.cancel_outlined
                              : Icons.swap_horiz,
                      size: 40,
                      color: _statusColor(status),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This request has been $status',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _statusColor(status),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // Counter offer form
              Text(
                'Counter Offer',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF475569),
                ),
              ),
              const SizedBox(height: 12),
              _buildFormField(
                label: 'Counter Price (per kg)',
                controller: _counterPriceController,
                hint: 'Enter counter price',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              _buildFormField(
                label: 'Notes',
                controller: _counterNotesController,
                hint: 'Add negotiation notes...',
                maxLines: 3,
              ),
              const SizedBox(height: 24),

              // Action buttons
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isActionLoading ? null : _sendCounterOffer,
                  icon: _isActionLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, size: 18),
                  label: Text(
                    'Send Counter Offer',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5D6E7E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isActionLoading
                          ? null
                          : () => _updateStatus('Confirmed'),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(
                        'Accept',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF10B981),
                        side: const BorderSide(color: Color(0xFF10B981)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isActionLoading
                          ? null
                          : () => _updateStatus('Cancelled'),
                      icon: const Icon(Icons.close, size: 18),
                      label: Text(
                        'Reject',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFEF4444),
                        side: const BorderSide(color: Color(0xFFEF4444)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFormField({
    required String label,
    required TextEditingController controller,
    String? hint,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          style: GoogleFonts.inter(fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.inter(
              fontSize: 13,
              color: const Color(0xFF94A3B8),
            ),
            filled: true,
            fillColor: const Color(0xFFF8F9FA),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: Color(0xFF5D6E7E), width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(String status, {bool small = false}) {
    final color = _statusColor(status);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 8 : 10,
        vertical: small ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: GoogleFonts.inter(
          fontSize: small ? 11 : 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _emptyState(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            message,
            style: GoogleFonts.manrope(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('dd MMM yyyy').format(date);
    } catch (_) {
      return dateStr;
    }
  }
}
