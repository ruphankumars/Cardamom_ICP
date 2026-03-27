import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

/// Dedicated screen for viewing all of user's approval requests
/// Two tabs: Pending and Completed (approved + rejected)
class MyRequestsScreen extends StatefulWidget {
  const MyRequestsScreen({super.key});

  @override
  State<MyRequestsScreen> createState() => _MyRequestsScreenState();
}

class _MyRequestsScreenState extends State<MyRequestsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // Refresh requests when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationService>().fetchMyRequests();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'My Requests',
      subtitle: 'View your approval request history',
      disableInternalScrolling: true,
      content: Column(
        children: [
          // Tab bar
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            decoration: BoxDecoration(
              color: const Color(0xFFE2E8F0),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Consumer<NotificationService>(
              builder: (context, service, _) {
                final allRequests = service.myRequests;
                final pendingCount = allRequests.where((r) => r.status == 'pending').length;
                final completedCount = allRequests.where((r) => r.status != 'pending').length;

                return TabBar(
                  controller: _tabController,
                  indicator: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  labelColor: const Color(0xFF0F172A),
                  unselectedLabelColor: const Color(0xFF64748B),
                  labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  padding: const EdgeInsets.all(4),
                  tabs: [
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.hourglass_top, size: 16),
                          const SizedBox(width: 6),
                          const Text('Pending'),
                          if (pendingCount > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF59E0B),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '$pendingCount',
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle_outline, size: 16),
                          const SizedBox(width: 6),
                          const Text('Completed'),
                          if (completedCount > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF64748B),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '$completedCount',
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // Tab content
          Expanded(
            child: Consumer<NotificationService>(
              builder: (context, service, _) {
                final allRequests = service.myRequests;
                final pending = allRequests.where((r) => r.status == 'pending').toList();
                final completed = allRequests.where((r) => r.status != 'pending').toList();

                return TabBarView(
                  controller: _tabController,
                  children: [
                    _buildRequestList(pending, service, isPendingTab: true),
                    _buildRequestList(completed, service, isPendingTab: false),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestList(List<ApprovalRequest> requests, NotificationService service, {required bool isPendingTab}) {
    if (requests.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isPendingTab ? Icons.hourglass_empty : Icons.inbox_rounded,
              size: 56,
              color: Colors.grey[300],
            ),
            const SizedBox(height: 16),
            Text(
              isPendingTab ? 'No pending requests' : 'No completed requests',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey[500]),
            ),
            const SizedBox(height: 8),
            Text(
              isPendingTab
                  ? 'Your pending approval requests will appear here'
                  : 'Approved and rejected requests will appear here',
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => service.fetchMyRequests(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: requests.length,
        itemBuilder: (context, index) {
          return _MyRequestCard(request: requests[index]);
        },
      ),
    );
  }
}

/// Individual request card — tappable for full detail view
class _MyRequestCard extends StatelessWidget {
  final ApprovalRequest request;

  const _MyRequestCard({required this.request});

  @override
  Widget build(BuildContext context) {
    final isPending = request.status == 'pending';
    final isApproved = request.status == 'approved';

    Color statusColor;
    IconData statusIcon;
    String statusLabel;

    if (isPending) {
      statusColor = const Color(0xFFF59E0B);
      statusIcon = Icons.hourglass_top;
      statusLabel = 'PENDING';
    } else if (isApproved) {
      statusColor = const Color(0xFF10B981);
      statusIcon = Icons.check_circle;
      statusLabel = 'APPROVED';
    } else {
      statusColor = const Color(0xFFEF4444);
      statusIcon = Icons.cancel;
      statusLabel = 'REJECTED';
    }

    final isDelete = request.actionType == 'delete';
    final actionColor = isDelete ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    final actionLabel = _capitalizeFirst(request.actionType);

    return GestureDetector(
      onTap: () => _showDetailDialog(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: statusColor.withValues(alpha: 0.25),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status icon
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(statusIcon, color: statusColor, size: 20),
            ),
            const SizedBox(width: 12),
            // Request info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Action type badge + resource type
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: actionColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          actionLabel,
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: actionColor),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _capitalizeFirst(request.resourceType),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Resource description
                  Text(
                    _buildResourceDescription(),
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // Timestamp
                  Text(
                    _getTimeAgo(request.createdAt),
                    style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                  ),
                  // Reason (if provided)
                  if (request.reason != null && request.reason!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      request.reason!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  // Admin response info (for completed)
                  if (!isPending && request.adminName != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 12,
                          color: statusColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${isApproved ? 'Approved' : 'Rejected'} by ${request.adminName}',
                          style: TextStyle(fontSize: 11, color: statusColor, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    if (request.rejectReason != null && request.rejectReason!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Reason: ${request.rejectReason}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFFEF4444), fontStyle: FontStyle.italic),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Status badge + chevron
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Icon(Icons.chevron_right, size: 18, color: Colors.grey[400]),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _buildResourceDescription() {
    final data = request.resourceData;
    if (data == null) return '${request.resourceType} #${request.resourceId}';

    final client = data['client'] ?? '';
    final lot = data['lot'] ?? '';
    final grade = data['grade'] ?? '';

    if (client.toString().isNotEmpty && lot.toString().isNotEmpty) {
      return '$client - $lot${grade.toString().isNotEmpty ? ' ($grade)' : ''}';
    }

    return '${request.resourceType} #${request.resourceId}';
  }

  String _capitalizeFirst(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  String _getTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('dd MMM yyyy, HH:mm').format(time);
  }

  void _showDetailDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => _MyRequestDetailDialog(request: request),
    );
  }
}

/// Full detail dialog for a request (read-only — no approve/reject buttons)
class _MyRequestDetailDialog extends StatelessWidget {
  final ApprovalRequest request;

  const _MyRequestDetailDialog({required this.request});

  @override
  Widget build(BuildContext context) {
    final isPending = request.status == 'pending';
    final isApproved = request.status == 'approved';

    Color statusColor;
    String statusLabel;
    IconData statusIcon;

    if (isPending) {
      statusColor = const Color(0xFFF59E0B);
      statusLabel = 'Pending Approval';
      statusIcon = Icons.hourglass_top;
    } else if (isApproved) {
      statusColor = const Color(0xFF10B981);
      statusLabel = 'Approved';
      statusIcon = Icons.check_circle;
    } else {
      statusColor = const Color(0xFFEF4444);
      statusLabel = 'Rejected';
      statusIcon = Icons.cancel;
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with status color
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: statusColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  Icon(statusIcon, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_capitalizeFirst(request.actionType)} ${_capitalizeFirst(request.resourceType)}',
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          statusLabel,
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
            ),
            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoRow('Action', _capitalizeFirst(request.actionType)),
                    _buildInfoRow('Resource', _capitalizeFirst(request.resourceType)),
                    _buildInfoRow('Requested at', DateFormat('dd MMM yyyy, HH:mm').format(request.createdAt)),
                    if (request.reason != null && request.reason!.isNotEmpty)
                      _buildInfoRow('Your Reason', request.reason!),
                    const Divider(height: 24),
                    // Resource details
                    const Text(
                      'Resource Details',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                    ),
                    const SizedBox(height: 8),
                    _buildResourceDetails(),
                    // Proposed changes
                    if (request.proposedChanges != null && request.proposedChanges!.isNotEmpty) ...[
                      const Divider(height: 24),
                      const Text(
                        'Proposed Changes',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                      const SizedBox(height: 8),
                      _buildChanges(),
                    ],
                    // Resolution info (for completed requests)
                    if (!isPending) ...[
                      const Divider(height: 24),
                      const Text(
                        'Resolution',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: statusColor.withValues(alpha: 0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(statusIcon, color: statusColor, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  statusLabel,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                ),
                              ],
                            ),
                            if (request.adminName != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                '${isApproved ? 'Approved' : 'Rejected'} by ${request.adminName}',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                              ),
                            ],
                            if (request.resolvedAt != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                'On ${DateFormat('dd MMM yyyy, HH:mm').format(request.resolvedAt!)}',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                              ),
                            ],
                            if (request.rejectReason != null && request.rejectReason!.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Reason: ${request.rejectReason}',
                                style: const TextStyle(fontSize: 12, color: Color(0xFFEF4444), fontStyle: FontStyle.italic),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Close button at bottom
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF64748B),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF0F172A))),
          ),
        ],
      ),
    );
  }

  Widget _buildResourceDetails() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Icon(
            _getResourceIcon(request.resourceType),
            color: const Color(0xFF64748B),
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            request.resourceType.toUpperCase(),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF0F172A),
            ),
          ),
          if (request.resourceId > 0) ...[
            const SizedBox(width: 8),
            Text(
              '#${request.resourceId}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getResourceIcon(String resourceType) {
    switch (resourceType.toLowerCase()) {
      case 'order':
        return Icons.shopping_cart_outlined;
      case 'purchase':
        return Icons.add_shopping_cart;
      case 'expense':
        return Icons.receipt_long_outlined;
      case 'gatepass':
        return Icons.badge_outlined;
      default:
        return Icons.article_outlined;
    }
  }

  Widget _buildChanges() {
    final changes = request.proposedChanges!;
    final resourceType = request.resourceType.toLowerCase();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFCD34D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _buildFormattedChanges(changes, resourceType),
      ),
    );
  }

  List<Widget> _buildFormattedChanges(Map<String, dynamic> changes, String resourceType) {
    if (resourceType == 'order') {
      return _buildOrderChanges(changes);
    }
    // Default: show all fields
    return changes.entries
        .where((e) => e.value != null && e.value.toString().isNotEmpty)
        .map((e) => _buildChangeRow(_capitalizeFirst(e.key), '${e.value}'))
        .toList();
  }

  List<Widget> _buildOrderChanges(Map<String, dynamic> changes) {
    final widgets = <Widget>[];

    final lot = changes['lot'] ?? changes['lotNumber'] ?? '';
    final grade = changes['grade'] ?? '';
    final no = changes['no'] ?? changes['bags'] ?? '';
    final bagbox = changes['bagbox'] ?? '';
    final kgs = changes['kgs'] ?? '';
    final price = changes['price'] ?? '';
    final brand = changes['brand'] ?? '';
    final notes = changes['notes'] ?? '';

    String orderLine = '';
    if (lot.toString().isNotEmpty) orderLine += '$lot: ';
    if (grade.toString().isNotEmpty) orderLine += '$grade';
    if (no.toString().isNotEmpty && bagbox.toString().isNotEmpty) {
      orderLine += ' - $no $bagbox';
    }
    if (kgs.toString().isNotEmpty) orderLine += ' - $kgs kgs';
    if (price.toString().isNotEmpty) orderLine += ' × ₹$price';
    if (brand.toString().isNotEmpty) orderLine += ' - $brand';

    if (orderLine.isNotEmpty) {
      widgets.add(
        Text(
          orderLine.trim(),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFFD97706),
          ),
        ),
      );
    }

    if (notes.toString().isNotEmpty) {
      widgets.add(const SizedBox(height: 6));
      widgets.add(
        Row(
          children: [
            const Text('≡ ', style: TextStyle(color: Color(0xFF92400E), fontSize: 12)),
            Expanded(
              child: Text(
                notes.toString(),
                style: const TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF92400E),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final handledKeys = {'lot', 'lotNumber', 'grade', 'no', 'bags', 'bagbox', 'kgs', 'price', 'brand', 'notes'};
    for (final entry in changes.entries) {
      if (!handledKeys.contains(entry.key) && entry.value != null && entry.value.toString().isNotEmpty) {
        widgets.add(const SizedBox(height: 4));
        widgets.add(_buildChangeRow(entry.key, '${entry.value}'));
      }
    }

    return widgets.isEmpty ? [const Text('No changes', style: TextStyle(color: Color(0xFF92400E)))] : widgets;
  }

  Widget _buildChangeRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFD97706)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _capitalizeFirst(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
