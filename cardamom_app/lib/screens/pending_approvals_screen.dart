import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/navigation_service.dart';
import '../mixins/pagination_mixin.dart';
import '../mixins/optimistic_action_mixin.dart';
import '../services/operation_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

class PendingApprovalsScreen extends StatefulWidget {
  const PendingApprovalsScreen({super.key});

  @override
  State<PendingApprovalsScreen> createState() => _PendingApprovalsScreenState();
}

class _PendingApprovalsScreenState extends State<PendingApprovalsScreen>
    with PaginationMixin, RouteAware, OptimisticActionMixin {
  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();

  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _requests = [];
  String _filter = 'pending'; // 'pending' | 'all'

  /// Rejection category options for the dropdown
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() => _loadRequests();

  Future<void> _loadRequests() async {
    paginationInfo.reset();
    setState(() {
      _isLoading = true;
      _requests = [];
    });
    if (_filter == 'pending') {
      // Pending filter uses non-paginated endpoint (small dataset)
      try {
        final response = await _apiService.getPendingApprovalRequests();
        if (mounted) {
          setState(() {
            _requests = (response.data['requests'] as List?) ?? [];
            paginationInfo.hasMore = false;
            _isLoading = false;
          });
        }
      } catch (e) {
        debugPrint('Error loading requests: $e');
        if (mounted) setState(() => _isLoading = false);
      }
    } else {
      await loadNextPage();
    }
  }

  @override
  Future<void> loadNextPage() async {
    try {
      // NOTE: Other screens (view_orders, view_expenses) should filter out items
      // where lockedByApproval == true to prevent editing resources that have
      // a pending approval request. Apply: .where((item) => item['lockedByApproval'] != true)
      final response = await _apiService.getAllApprovalRequestsPaginated(
        limit: paginationInfo.limit,
        cursor: paginationInfo.cursor,
      );

      if (mounted) {
        final data = response.data as Map<String, dynamic>;
        final newRequests = (data['requests'] as List?) ?? [];
        final pagination = data['pagination'] as Map<String, dynamic>? ?? {};
        setState(() {
          _requests.addAll(newRequests);
          paginationInfo.cursor = pagination['cursor'] as String?;
          paginationInfo.hasMore = pagination['hasMore'] as bool? ?? false;
          paginationInfo.isLoadingMore = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading requests: $e');
      if (mounted) {
        setState(() {
          paginationInfo.isLoadingMore = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _approveRequest(Map<String, dynamic> request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Approve Request?'),
        content: Text('Approve ${request['actionType']} request for ${request['resourceType']}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
            child: const Text('Approve'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    fireAndForget(
      type: 'approve',
      apiCall: () => _apiService.approveRequest(
        request['id'],
        auth.userId ?? 'admin',
        auth.username ?? 'Admin',
      ),
      onSuccess: () {
        if (mounted) {
          setState(() {
            _requests.removeWhere((r) => r['id'] == request['id']);
          });
        }
      },
      successMessage: 'Request approved and executed',
      failureMessage: 'Failed to approve request',
    );
  }

  Future<void> _rejectRequest(Map<String, dynamic> request) async {
    final controller = TextEditingController();
    String selectedCategory = 'other';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (c) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
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
                      labelText: 'Rejection Category',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    items: _rejectionCategories.entries.map((entry) {
                      return DropdownMenuItem<String>(
                        value: entry.key,
                        child: Text(entry.value),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setDialogState(() {
                        selectedCategory = value ?? 'other';
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      labelText: 'Reason for rejection',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    maxLines: 2,
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, null), child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: () => Navigator.pop(c, {
                    'reason': controller.text.isEmpty ? 'No reason provided' : controller.text,
                    'category': selectedCategory,
                  }),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                  child: const Text('Reject'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    fireAndForget(
      type: 'reject',
      apiCall: () => _apiService.rejectRequest(
        request['id'],
        auth.userId ?? 'admin', // Use actual admin ID
        auth.username ?? 'Admin', // Use actual admin name
        result['reason']!,
        rejectionCategory: result['category'] ?? 'other',
      ),
      onSuccess: () {
        if (mounted) {
          setState(() {
            _requests.removeWhere((r) => r['id'] == request['id']);
          });
        }
      },
      successMessage: 'Request rejected',
      failureMessage: 'Failed to reject request',
    );
  }

  /// Builds a clean two-column before/after diff display for proposed changes
  Widget _buildDiffDisplay(Map<String, dynamic>? oldData, Map<String, dynamic>? newData) {
    if (oldData == null || newData == null) return const SizedBox.shrink();

    final changedKeys = newData.keys.where((key) =>
      oldData[key]?.toString() != newData[key]?.toString()
    ).toList();

    if (changedKeys.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(10),
            child: Text('Changes', style: TextStyle(
              fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF64748B)
            )),
          ),
          ...changedKeys.map((key) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: [
                Expanded(child: Text(key, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('${oldData[key]}', style: const TextStyle(fontSize: 11, color: Color(0xFFEF4444), decoration: TextDecoration.lineThrough)),
                ),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.arrow_forward, size: 12, color: Color(0xFF94A3B8))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('${newData[key]}', style: const TextStyle(fontSize: 11, color: Color(0xFF22C55E), fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          )),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _filter == 'all' ? onScrollNotification : null,
      child: AppShell(
        title: 'Pending Approvals',
        subtitle: 'Review and approve user requests',
        topActions: [
          _buildFilterChip('Pending', 'pending'),
          const SizedBox(width: 8),
          _buildFilterChip('All', 'all'),
        ],
        content: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _requests.isEmpty
                ? _buildEmptyState()
                : _buildRequestList(),
      ),
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isActive = _filter == value;
    return GestureDetector(
      onTap: () {
        setState(() => _filter = value);
        _loadRequests();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF5D6E7E) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF5D6E7E)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.white : const Color(0xFF5D6E7E),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            _filter == 'pending' ? 'No pending approvals' : 'No requests found',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestList() {
    return Column(
      children: [
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _requests.length,
          itemBuilder: (context, index) => _buildRequestCard(_requests[index]),
        ),
        if (_filter == 'all') buildPaginationFooter(),
      ],
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

    return Stack(
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: AppTheme.glassDecoration,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: actionType == 'delete' ? Colors.red.withOpacity(0.1) : Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            actionType == 'delete' ? Icons.delete : Icons.edit,
                            size: 16,
                            color: actionType == 'delete' ? Colors.red : Colors.blue,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            actionType.toUpperCase(),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: actionType == 'delete' ? Colors.red : Colors.blue,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, size: 14, color: statusColor),
                          const SizedBox(width: 4),
                          Text(
                            request['status']?.toUpperCase() ?? 'UNKNOWN',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    if (createdAt != null)
                      Text(
                        DateFormat('MMM d, HH:mm').format(createdAt),
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                  ],
                ),
                const SizedBox(height: 16),

                // Resource info
                Text('$resourceType', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                if (resourceData['client'] != null)
                  Text('Client: ${resourceData['client']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                if (resourceData['lot'] != null)
                  Text('Lot: ${resourceData['lot']} - Grade: ${resourceData['grade'] ?? 'N/A'}'),
                if (resourceData['kgs'] != null)
                  Text('${resourceData['kgs']} Kgs @ ${resourceData['price'] ?? 'N/A'}'),

                const SizedBox(height: 12),

                // Diff display for edit requests with proposed changes
                if (actionType == 'edit' && proposedChanges != null)
                  _buildDiffDisplay(resourceData, proposedChanges),

                // Requester info
                Row(
                  children: [
                    const Icon(Icons.person, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text('Requested by: $requesterName', style: const TextStyle(fontSize: 12)),
                  ],
                ),

                if (request['reason'] != null && request['reason'].toString().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.notes, size: 16, color: Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(child: Text(request['reason'], style: const TextStyle(fontSize: 12))),
                      ],
                    ),
                  ),
                ],

                // Rejection reason if rejected
                if (request['status'] == 'rejected' && request['rejectionReason'] != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning, size: 16, color: Colors.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (request['rejectionCategory'] != null && request['rejectionCategory'] != 'other')
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    _rejectionCategories[request['rejectionCategory']] ?? request['rejectionCategory'],
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red),
                                  ),
                                ),
                              Text(
                                'Rejected: ${request['rejectionReason']}',
                                style: const TextStyle(fontSize: 12, color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Action buttons for pending requests
                if (isPending) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _rejectRequest(request),
                          icon: const Icon(Icons.close, size: 18),
                          label: const Text('Reject'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFEF4444),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _approveRequest(request),
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text('Approve'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF22C55E),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        // Lock visual indicator when resource is locked by an approval
        if (request['lockedByApproval'] == true)
          Positioned(
            top: 8, right: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.lock, size: 14, color: Colors.orange.shade700),
            ),
          ),
      ],
    );
  }
}
