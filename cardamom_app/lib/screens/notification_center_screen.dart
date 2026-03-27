import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/notification_service.dart';
import '../services/auth_provider.dart';
import '../widgets/approval_panel.dart';

class NotificationCenterScreen extends StatefulWidget {
  const NotificationCenterScreen({super.key});

  @override
  State<NotificationCenterScreen> createState() => _NotificationCenterScreenState();
}

class _NotificationCenterScreenState extends State<NotificationCenterScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _checkAdminRole();
  }

  void _checkAdminRole() {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final role = auth.role?.toLowerCase() ?? '';
    _isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
    _tabController = TabController(length: _isAdmin ? 2 : 1, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        elevation: 0,
        actions: [
          TextButton(
            onPressed: () => context.read<NotificationService>().markAllAsRead(),
            child: const Text('Mark all as read', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E))),
          ),
        ],
        bottom: _isAdmin ? TabBar(
          controller: _tabController,
          labelColor: const Color(0xFF5D6E7E),
          unselectedLabelColor: const Color(0xFF94A3B8),
          indicatorColor: const Color(0xFF5D6E7E),
          tabs: [
            const Tab(text: 'Notifications'),
            Consumer<NotificationService>(
              builder: (context, service, _) {
                final pendingCount = service.pendingApprovalCount;
                return Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Approvals'),
                      if (pendingCount > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444),
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
                );
              },
            ),
          ],
        ) : null,
      ),
      body: _isAdmin
          ? TabBarView(
              controller: _tabController,
              children: [
                _buildNotificationsList(),
                const ApprovalPanel(),
              ],
            )
          : _buildNotificationsList(),
    );
  }

  Widget _buildNotificationsList() {
    return Consumer<NotificationService>(
      builder: (context, service, _) {
        final notifications = service.notifications;
        if (notifications.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.notifications_off_outlined, size: 48, color: Color(0xFFCBD5E1)),
                SizedBox(height: 16),
                Text('All caught up!', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: notifications.length,
          itemBuilder: (context, index) {
            final notification = notifications[index];
            return _buildNotificationCard(context, service, notification);
          },
        );
      },
    );
  }

  Widget _buildNotificationCard(BuildContext context, NotificationService service, AppNotification n) {
    final Color color = _getTypeColor(n.type);

    return Dismissible(
      key: Key(n.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => service.removeNotification(n.id),
      background: Container(
        margin: const EdgeInsets.only(bottom: 12),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
      ),
      child: GestureDetector(
        onTap: () {
          service.markAsRead(n.id);
          _showNotificationDetailDialog(context, service, n);
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: n.isRead ? Colors.white : const Color(0xFF5D6E7E).withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: n.isRead ? Colors.transparent : const Color(0xFF5D6E7E).withOpacity(0.1),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(_getTypeIcon(n.type), color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            n.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: n.isRead ? FontWeight.w600 : FontWeight.bold,
                              color: const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        Text(
                          _formatTimestamp(n.timestamp),
                          style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      n.body,
                      style: TextStyle(
                        fontSize: 12,
                        color: n.isRead ? const Color(0xFF64748B) : const Color(0xFF334155),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Action buttons: mark as read (tick) and dismiss (x)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Mark as read / tick button
                  if (!n.isRead)
                    GestureDetector(
                      onTap: () => service.markAsRead(n.id),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                        ),
                        child: const Icon(Icons.check_rounded, color: Color(0xFF10B981), size: 18),
                      ),
                    ),
                  if (!n.isRead) const SizedBox(height: 6),
                  // Dismiss / X button
                  GestureDetector(
                    onTap: () => service.removeNotification(n.id),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
                      ),
                      child: const Icon(Icons.close_rounded, color: Color(0xFFEF4444), size: 18),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showNotificationDetailDialog(BuildContext context, NotificationService service, AppNotification n) {
    final Color color = _getTypeColor(n.type);
    final bool isApprovalType = n.type == 'approval_result' || n.type == 'approval';
    final bool canActOnApproval = _isAdmin && isApprovalType && n.relatedRequestId != null;

    // Try to find matching pending approval request if this is an approval notification
    ApprovalRequest? matchedRequest;
    if (canActOnApproval) {
      final pending = service.pendingApprovals;
      matchedRequest = pending.where((r) => r.id == n.relatedRequestId).isNotEmpty
          ? pending.firstWhere((r) => r.id == n.relatedRequestId)
          : null;
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    Icon(_getTypeIcon(n.type), color: Colors.white, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        n.title,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              // Body
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Timestamp
                      Row(
                        children: [
                          const Icon(Icons.access_time, size: 14, color: Color(0xFF94A3B8)),
                          const SizedBox(width: 6),
                          Text(
                            DateFormat('dd MMM yyyy, HH:mm').format(n.timestamp),
                            style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Type badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          n.type.replaceAll('_', ' ').toUpperCase(),
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Message body
                      Text(
                        n.body,
                        style: const TextStyle(fontSize: 14, color: Color(0xFF334155), height: 1.6),
                      ),
                      // Show matched approval request details if found
                      if (matchedRequest != null) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 8),
                        const Text(
                          'Approval Request Details',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                        ),
                        const SizedBox(height: 8),
                        _buildDetailRow('Requested by', matchedRequest.requesterName),
                        _buildDetailRow('Action', matchedRequest.actionType.toUpperCase()),
                        _buildDetailRow('Resource', '${matchedRequest.resourceType.toUpperCase()} #${matchedRequest.resourceId}'),
                        if (matchedRequest.reason != null && matchedRequest.reason!.isNotEmpty)
                          _buildDetailRow('Reason', matchedRequest.reason!),
                      ],
                    ],
                  ),
                ),
              ),
              // Actions footer
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                ),
                child: matchedRequest != null
                    ? Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                _handleRejectFromNotification(context, service, n, matchedRequest!);
                              },
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text('Reject', style: TextStyle(fontWeight: FontWeight.bold)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFEF4444),
                                side: const BorderSide(color: Color(0xFFEF4444)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                _handleApproveFromNotification(context, service, n, matchedRequest!);
                              },
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                service.removeNotification(n.id);
                                Navigator.pop(ctx);
                              },
                              icon: const Icon(Icons.delete_outline_rounded, size: 18),
                              label: const Text('Dismiss', style: TextStyle(fontWeight: FontWeight.bold)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFEF4444),
                                side: const BorderSide(color: Color(0xFFEF4444)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                service.markAsRead(n.id);
                                Navigator.pop(ctx);
                              },
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('Mark Read', style: TextStyle(fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF5D6E7E),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
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

  Future<void> _handleApproveFromNotification(BuildContext context, NotificationService service, AppNotification n, ApprovalRequest request) async {
    final prefs = await SharedPreferences.getInstance();
    final adminId = prefs.getString('userId') ?? '';
    final adminName = prefs.getString('username') ?? 'Admin';

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final success = await service.approveRequest(request.id, adminId, adminName);

      if (success) {
        service.removeApprovalRequest(request.id);
        service.removeNotification(n.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Request approved'), backgroundColor: Color(0xFF10B981)),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to approve request'), backgroundColor: Color(0xFFEF4444)),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    } finally {
      if (context.mounted) Navigator.pop(context); // Close loading
    }
  }

  Future<void> _handleRejectFromNotification(BuildContext context, NotificationService service, AppNotification n, ApprovalRequest request) async {
    final reasonController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Reject Request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Reject ${request.actionType} request from ${request.requesterName}?',
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              decoration: InputDecoration(
                labelText: 'Reason (optional)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      reasonController.dispose();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final adminId = prefs.getString('userId') ?? '';
    final adminName = prefs.getString('username') ?? 'Admin';
    final reason = reasonController.text.isNotEmpty ? reasonController.text : 'No reason provided';
    reasonController.dispose();

    // Show loading
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()),
      );
    }

    try {
      final success = await service.rejectRequest(request.id, adminId, adminName, reason);

      if (success) {
        service.removeApprovalRequest(request.id);
        service.removeNotification(n.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Request rejected'), backgroundColor: Color(0xFFEF4444)),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to reject request'), backgroundColor: Color(0xFFEF4444)),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    } finally {
      if (context.mounted) Navigator.pop(context); // Close loading
    }
  }

  IconData _getTypeIcon(String type) {
    switch (type) {
      case 'stock': return Icons.inventory_2_rounded;
      case 'orders': return Icons.shopping_basket_rounded;
      case 'sync': return Icons.sync_rounded;
      case 'alert': return Icons.warning_amber_rounded;
      case 'approval_result': return Icons.how_to_vote_rounded;
      case 'approval': return Icons.how_to_vote_rounded;
      case 'documents': return Icons.description_rounded;
      default: return Icons.notifications_active_rounded;
    }
  }

  Color _getTypeColor(String type) {
    switch (type) {
      case 'stock': return const Color(0xFFEF4444);
      case 'orders': return const Color(0xFF10B981);
      case 'sync': return const Color(0xFF5D6E7E);
      case 'alert': return const Color(0xFFF59E0B);
      case 'approval_result': return const Color(0xFF8B5CF6);
      case 'approval': return const Color(0xFF8B5CF6);
      case 'documents': return const Color(0xFF0891B2);
      default: return const Color(0xFF5D6E7E);
    }
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('dd MMM').format(dt);
  }
}
