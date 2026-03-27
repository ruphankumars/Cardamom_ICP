import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../services/notification_service.dart';
import '../../services/auth_provider.dart';

class WebNotificationCenter extends StatefulWidget {
  const WebNotificationCenter({super.key});

  @override
  State<WebNotificationCenter> createState() => _WebNotificationCenterState();
}

class _WebNotificationCenterState extends State<WebNotificationCenter> {
  String _activeTab = 'all'; // 'all', 'approval', 'my_requests', 'alerts'
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _checkRole();
  }

  void _checkRole() {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final role = auth.role?.toLowerCase() ?? '';
    _isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          _buildTabs(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Consumer<NotificationService>(
      builder: (context, service, _) {
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
                  Text('Notifications', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
                  const SizedBox(height: 4),
                  Text(
                    '${service.unreadCount} unread notifications',
                    style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280)),
                  ),
                ],
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => service.markAllAsRead(),
                icon: const Icon(Icons.done_all, size: 16),
                label: Text('Mark all read', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
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
      },
    );
  }

  Widget _buildTabs() {
    return Consumer<NotificationService>(
      builder: (context, service, _) {
        return Container(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 16),
          color: Colors.white,
          child: Row(
            children: [
              _buildTab('All', 'all', null),
              const SizedBox(width: 8),
              if (_isAdmin)
                _buildTab('Approval Requests', 'approval', service.pendingApprovalCount > 0 ? service.pendingApprovalCount : null),
              if (_isAdmin) const SizedBox(width: 8),
              _buildTab('My Requests', 'my_requests', service.myUnreadCount > 0 ? service.myUnreadCount : null),
              const SizedBox(width: 8),
              _buildTab('Alerts', 'alerts', null),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTab(String label, String value, int? badgeCount) {
    final active = _activeTab == value;
    return InkWell(
      onTap: () => setState(() => _activeTab = value),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF5D6E7E) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? const Color(0xFF5D6E7E) : const Color(0xFFD1D5DB)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : const Color(0xFF6B7280),
              ),
            ),
            if (badgeCount != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: active ? Colors.white : const Color(0xFFEF4444),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$badgeCount',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: active ? const Color(0xFF5D6E7E) : Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Consumer<NotificationService>(
      builder: (context, service, _) {
        final notifications = _getFilteredNotifications(service);

        if (notifications.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.notifications_off_outlined, size: 56, color: Colors.grey[300]),
                const SizedBox(height: 12),
                Text('All caught up!', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600, color: const Color(0xFF9CA3AF))),
                const SizedBox(height: 4),
                Text('No notifications to show', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFFD1D5DB))),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 24),
          itemCount: notifications.length,
          itemBuilder: (context, index) => _buildNotificationCard(service, notifications[index]),
        );
      },
    );
  }

  List<AppNotification> _getFilteredNotifications(NotificationService service) {
    final all = service.notifications;
    switch (_activeTab) {
      case 'approval':
        return all.where((n) => n.type == 'approval_result' || n.type == 'approval').toList();
      case 'my_requests':
        return all.where((n) => n.type == 'approval_result').toList();
      case 'alerts':
        return all.where((n) => n.type == 'alert' || n.type == 'stock').toList();
      default:
        return all;
    }
  }

  Widget _buildNotificationCard(NotificationService service, AppNotification n) {
    final color = _getTypeColor(n.type);
    final icon = _getTypeIcon(n.type);

    return InkWell(
      onTap: () => service.markAsRead(n.id),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: n.isRead ? Colors.white : const Color(0xFF5D6E7E).withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: n.isRead ? const Color(0xFFF1F5F9) : const Color(0xFF5D6E7E).withOpacity(0.1),
          ),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 6)],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 16),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          n.title,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w700,
                            color: const Color(0xFF111827),
                          ),
                        ),
                      ),
                      Text(
                        _formatTimestamp(n.timestamp),
                        style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    n.body,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: n.isRead ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            // Unread dot
            if (!n.isRead) ...[
              const SizedBox(width: 12),
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 6),
                decoration: const BoxDecoration(
                  color: Color(0xFF5D6E7E),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _getTypeIcon(String type) {
    switch (type) {
      case 'stock': return Icons.inventory_2_rounded;
      case 'orders': return Icons.shopping_basket_rounded;
      case 'sync': return Icons.sync_rounded;
      case 'alert': return Icons.warning_amber_rounded;
      case 'approval_result': return Icons.how_to_vote_rounded;
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
      default: return const Color(0xFF5D6E7E);
    }
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('dd MMM').format(dt);
  }
}
