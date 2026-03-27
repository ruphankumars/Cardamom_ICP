/// Frosted header widgets for the admin dashboard.
///
/// Contains the main FrostedHeader with notification bell/profile menu,
/// GlassStatPill for glassmorphic stat displays, and SyncIndicator
/// for last-sync time display.
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_theme.dart';
import '../../../services/auth_provider.dart';
import '../../../services/notification_service.dart';
import '../../../models/task.dart';

/// Frosted header bar with menu, logo, notifications, and profile.
class FrostedHeader extends StatelessWidget {
  final List<Task> userTasks;
  final VoidCallback onMarkTasksSeen;
  final VoidCallback onShowNotifications;

  const FrostedHeader({
    super.key,
    required this.userTasks,
    required this.onMarkTasksSeen,
    required this.onShowNotifications,
  });

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (scaffoldContext) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            // Menu button - machined disc style
            GestureDetector(
              onTap: () => Scaffold.of(scaffoldContext).openDrawer(),
              child: Container(
                width: 44, height: 44,
                decoration: AppTheme.machinedDecoration,
                child: const Icon(Icons.menu, color: AppTheme.primary, size: 22),
              ),
            ),
            Expanded(
              child: Center(
                child: Image.asset(
                  'assets/emperor_logo_transparent.png',
                  height: 40,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            // Notification bell icon with count badge
            ...[
              GestureDetector(
                onTap: () {
                  onMarkTasksSeen();
                  onShowNotifications();
                },
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 44, height: 44,
                      decoration: AppTheme.machinedDecoration,
                      child: const Icon(Icons.notifications_rounded, color: AppTheme.primary, size: 22),
                    ),
                    Consumer<NotificationService>(
                      builder: (context, notificationService, _) {
                        final taskCount = userTasks.where((t) => t.status == TaskStatus.ongoing || t.status == TaskStatus.pending).length;
                        final approvalCount = notificationService.pendingApprovalCount;
                        final myPending = notificationService.myPendingCount;
                        final totalCount = taskCount + approvalCount + myPending + notificationService.unreadCount;

                        if (totalCount == 0) return const SizedBox.shrink();

                        return Positioned(
                          right: 2,
                          top: 2,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.red.withOpacity(0.4),
                                  blurRadius: 4,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Text(
                              '$totalCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
            // Profile button with popup menu
            PopupMenuButton<String>(
              offset: const Offset(0, 50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              color: AppTheme.titaniumLight,
              elevation: 8,
              onSelected: (value) {
                if (value == 'logout') {
                  Provider.of<AuthProvider>(context, listen: false).logout();
                  Navigator.pushReplacementNamed(context, '/login');
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'logout',
                  child: Row(
                    children: [
                      Icon(Icons.logout_rounded, color: AppTheme.danger, size: 20),
                      const SizedBox(width: 12),
                      Text('Logout', style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ],
              child: Container(
                width: 44, height: 44,
                decoration: AppTheme.machinedDecoration,
                child: const Icon(Icons.person, color: AppTheme.primary, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Glassmorphic stat pill for displaying a labeled value with blurred backdrop.
class GlassStatPill extends StatelessWidget {
  final String value;
  final String label;

  const GlassStatPill({super.key, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.5), width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFF64748B), letterSpacing: 0.5),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF4A5568)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sync indicator pill showing the last sync timestamp.
class SyncIndicator extends StatelessWidget {
  final DateTime? lastSync;

  const SyncIndicator({super.key, this.lastSync});

  @override
  Widget build(BuildContext context) {
    if (lastSync == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sync_rounded, size: 10, color: Colors.white70),
          const SizedBox(width: 4),
          Text(
            DateFormat('HH:mm').format(lastSync!),
            style: const TextStyle(fontSize: 10, color: Colors.white70, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
