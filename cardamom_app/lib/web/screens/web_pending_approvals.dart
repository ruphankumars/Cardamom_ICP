import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';

class WebPendingApprovals extends StatefulWidget {
  const WebPendingApprovals({super.key});

  @override
  State<WebPendingApprovals> createState() => _WebPendingApprovalsState();
}

class _WebPendingApprovalsState extends State<WebPendingApprovals> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _requests = [];
  String _filter = 'all'; // 'all', 'edit', 'delete'
  String _statusFilter = 'pending'; // 'pending', 'all'

  // Pagination
  String? _cursor;
  bool _hasMore = false;
  bool _isLoadingMore = false;

  static const Map<String, String> _rejectionCategories = {
    'price_too_high': 'Price Too High',
    'quality_concern': 'Quality Concern',
    'timing': 'Bad Timing',
    'insufficient_info': 'Insufficient Information',
    'duplicate': 'Duplicate Request',
    'other': 'Other',
  };

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    setState(() {
      _isLoading = true;
      _requests = [];
      _cursor = null;
      _hasMore = false;
    });

    if (_statusFilter == 'pending') {
      try {
        final response = await _apiService.getPendingApprovalRequests();
        if (mounted) {
          setState(() {
            _requests = (response.data['requests'] as List?) ?? [];
            _hasMore = false;
            _isLoading = false;
          });
        }
      } catch (e) {
        debugPrint('Error loading requests: $e');
        if (mounted) setState(() => _isLoading = false);
      }
    } else {
      await _loadPage();
    }
  }

  Future<void> _loadPage() async {
    try {
      final response = await _apiService.getAllApprovalRequestsPaginated(
        limit: 25,
        cursor: _cursor,
      );
      if (mounted) {
        final data = response.data as Map<String, dynamic>;
        final newRequests = (data['requests'] as List?) ?? [];
        final pagination = data['pagination'] as Map<String, dynamic>? ?? {};
        setState(() {
          _requests.addAll(newRequests);
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

  List<dynamic> get _filteredRequests {
    return _requests.where((r) {
      if (_filter == 'edit') return r['actionType'] == 'edit';
      if (_filter == 'delete') return r['actionType'] == 'delete';
      return true;
    }).toList();
  }

  Future<void> _approveRequest(Map<String, dynamic> request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Approve Request?'),
        content: Text('Approve ${request['actionType']} request for ${request['resourceType']}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22C55E), foregroundColor: Colors.white),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      await _apiService.approveRequest(
        request['id'],
        auth.userId ?? 'admin',
        auth.username ?? 'Admin',
      );
      _showSnackBar('Request approved and executed');
      await _loadRequests();
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  Future<void> _rejectRequest(Map<String, dynamic> request) async {
    final reasonController = TextEditingController();
    String selectedCategory = 'other';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('Reject Request'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Reject ${request['actionType']} request?'),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedCategory,
                decoration: InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                items: _rejectionCategories.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setDialogState(() => selectedCategory = v ?? 'other'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Reason',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, null), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(c, {
                'reason': reasonController.text.isEmpty ? 'No reason provided' : reasonController.text,
                'category': selectedCategory,
              }),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444), foregroundColor: Colors.white),
              child: const Text('Reject'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;

    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      await _apiService.rejectRequest(
        request['id'],
        auth.userId ?? 'admin',
        auth.username ?? 'Admin',
        result['reason']!,
        rejectionCategory: result['category'] ?? 'other',
      );
      _showSnackBar('Request rejected');
      await _loadRequests();
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF5D6E7E)))
                : _buildContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final pendingCount = _requests.where((r) => r['status'] == 'pending').length;
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
              Text('Pending Approvals', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
              const SizedBox(height: 4),
              Text(
                '$pendingCount pending requests',
                style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280)),
              ),
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

  Widget _buildContent() {
    final filtered = _filteredRequests;
    return Column(
      children: [
        // Filter tabs
        Container(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 16),
          color: Colors.white,
          child: Row(
            children: [
              // Status filter
              _buildTabChip('Pending', 'pending', _statusFilter, (v) {
                setState(() => _statusFilter = v);
                _loadRequests();
              }),
              const SizedBox(width: 8),
              _buildTabChip('All History', 'all', _statusFilter, (v) {
                setState(() => _statusFilter = v);
                _loadRequests();
              }),
              const SizedBox(width: 24),
              Container(width: 1, height: 24, color: const Color(0xFFE5E7EB)),
              const SizedBox(width: 24),
              // Type filter
              _buildTabChip('All Types', 'all', _filter, (v) => setState(() => _filter = v)),
              const SizedBox(width: 8),
              _buildTabChip('Edit Requests', 'edit', _filter, (v) => setState(() => _filter = v)),
              const SizedBox(width: 8),
              _buildTabChip('Delete Requests', 'delete', _filter, (v) => setState(() => _filter = v)),
            ],
          ),
        ),
        // Cards list
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline, size: 56, color: Colors.grey[300]),
                      const SizedBox(height: 12),
                      Text(
                        _statusFilter == 'pending' ? 'No pending approvals' : 'No requests found',
                        style: GoogleFonts.inter(fontSize: 16, color: const Color(0xFF9CA3AF)),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(32, 16, 32, 24),
                  itemCount: filtered.length + (_isLoadingMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == filtered.length) {
                      return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2)));
                    }
                    return _buildRequestCard(filtered[index]);
                  },
                ),
        ),
        if (_hasMore && !_isLoadingMore)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: TextButton(
              onPressed: _loadMore,
              child: Text('Load More', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF5D6E7E))),
            ),
          ),
      ],
    );
  }

  Widget _buildTabChip(String label, String value, String current, ValueChanged<String> onTap) {
    final active = current == value;
    return InkWell(
      onTap: () => onTap(value),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF5D6E7E) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? const Color(0xFF5D6E7E) : const Color(0xFFD1D5DB)),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }

  Widget _buildRequestCard(Map<String, dynamic> request) {
    final isPending = request['status'] == 'pending';
    final actionType = request['actionType'] ?? 'unknown';
    final resourceType = request['resourceType'] ?? 'unknown';
    final requesterName = request['requesterName'] ?? 'Unknown';
    final createdAt = DateTime.tryParse(request['createdAt'] ?? '');
    final resourceData = request['resourceData'] as Map<String, dynamic>? ?? {};
    final proposedChanges = request['proposedChanges'] as Map<String, dynamic>?;

    Color statusColor;
    IconData statusIcon;
    switch (request['status']) {
      case 'approved':
        statusColor = const Color(0xFF22C55E);
        statusIcon = Icons.check_circle;
        break;
      case 'rejected':
        statusColor = const Color(0xFFEF4444);
        statusIcon = Icons.cancel;
        break;
      default:
        statusColor = const Color(0xFFF59E0B);
        statusIcon = Icons.pending;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left: info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      _buildBadge(
                        actionType.toUpperCase(),
                        actionType == 'delete' ? const Color(0xFFEF4444) : const Color(0xFF3B82F6),
                        icon: actionType == 'delete' ? Icons.delete : Icons.edit,
                      ),
                      const SizedBox(width: 8),
                      _buildBadge(
                        (request['status'] ?? 'unknown').toUpperCase(),
                        statusColor,
                        icon: statusIcon,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        resourceType,
                        style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF9CA3AF)),
                      ),
                      const Spacer(),
                      if (createdAt != null)
                        Text(
                          DateFormat('dd MMM, HH:mm').format(createdAt),
                          style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF9CA3AF)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Resource details
                  if (resourceData['client'] != null)
                    Text('Client: ${resourceData['client']}', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: const Color(0xFF111827))),
                  if (resourceData['lot'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Lot: ${resourceData['lot']} - Grade: ${resourceData['grade'] ?? 'N/A'}', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
                    ),
                  if (resourceData['kgs'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('${resourceData['kgs']} Kgs @ ${resourceData['price'] ?? 'N/A'}', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
                    ),
                  // Diff for edit requests
                  if (actionType == 'edit' && proposedChanges != null) ...[
                    const SizedBox(height: 12),
                    _buildDiffDisplay(resourceData, proposedChanges),
                  ],
                  // Requester
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.person_outline, size: 14, color: Color(0xFF9CA3AF)),
                      const SizedBox(width: 4),
                      Text('Requested by $requesterName', style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280))),
                    ],
                  ),
                  // Rejection reason
                  if (request['status'] == 'rejected' && request['rejectionReason'] != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 14, color: Color(0xFFEF4444)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Rejected: ${request['rejectionReason']}',
                              style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFFEF4444)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Right: action buttons
            if (isPending) ...[
              const SizedBox(width: 24),
              Column(
                children: [
                  SizedBox(
                    width: 120,
                    child: ElevatedButton.icon(
                      onPressed: () => _approveRequest(request),
                      icon: const Icon(Icons.check, size: 16),
                      label: Text('Approve', style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF22C55E),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 120,
                    child: OutlinedButton.icon(
                      onPressed: () => _rejectRequest(request),
                      icon: const Icon(Icons.close, size: 16),
                      label: Text('Reject', style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFEF4444),
                        side: const BorderSide(color: Color(0xFFEF4444)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

  Widget _buildBadge(String label, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(label, style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.3)),
        ],
      ),
    );
  }

  Widget _buildDiffDisplay(Map<String, dynamic> oldData, Map<String, dynamic> newData) {
    final changedKeys = newData.keys.where((key) =>
      oldData[key]?.toString() != newData[key]?.toString()
    ).toList();
    if (changedKeys.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Changes', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280))),
          const SizedBox(height: 8),
          ...changedKeys.map((key) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text(key, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF))),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(4)),
                  child: Text('${oldData[key]}', style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFFEF4444), decoration: TextDecoration.lineThrough)),
                ),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 10, color: Color(0xFF9CA3AF))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(4)),
                  child: Text('${newData[key]}', style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF22C55E), fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}
