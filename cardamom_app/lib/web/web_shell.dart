import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/auth_provider.dart';
import '../services/access_control_service.dart';
import '../services/notification_service.dart';

/// Navigation item model for the sidebar.
class _NavItem {
  final IconData icon;
  final String label;
  final String route;
  final String? pageKey;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.route,
    this.pageKey,
  });
}

/// Navigation section model grouping items under a header.
class _NavSection {
  final String header;
  final List<_NavItem> items;

  const _NavSection({required this.header, required this.items});
}

/// The main web layout shell with a persistent sidebar and top bar.
class WebShell extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<Widget>? topActions;
  final Widget? floatingActionButton;
  final Widget child;

  const WebShell({
    super.key,
    required this.title,
    this.subtitle,
    this.topActions,
    this.floatingActionButton,
    required this.child,
  });

  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  String? _hoveredRoute;

  // ── Navigation structure ──────────────────────────────────────────────

  List<_NavSection> _buildSections({
    required bool isStaff,
    required bool isClient,
    required bool isAdmin,
    required String role,
    required Map<String, dynamic>? pageAccess,
  }) {
    bool _canAccess(String? pageKey) {
      if (pageKey == null) return true;
      return AccessControlService.canAccess(pageAccess, pageKey, userRole: role);
    }

    final sections = <_NavSection>[];

    // MAIN
    {
      final items = <_NavItem>[];
      items.add(_NavItem(
        icon: Icons.dashboard_rounded,
        label: 'Dashboard',
        route: isClient ? '/client_dashboard' : '/admin_dashboard',
      ));
      if (_canAccess('order_requests')) {
        items.add(const _NavItem(
          icon: Icons.mail_rounded,
          label: 'Order Requests',
          route: '/order_requests',
          pageKey: 'order_requests',
        ));
      }
      sections.add(_NavSection(header: 'MAIN', items: items));
    }

    // ORDERS (staff only)
    if (isStaff) {
      final items = <_NavItem>[];
      if (_canAccess('view_orders')) {
        items.add(const _NavItem(
          icon: Icons.list_alt_rounded,
          label: 'View Orders',
          route: '/view_orders',
          pageKey: 'view_orders',
        ));
      }
      if (_canAccess('new_order')) {
        items.add(const _NavItem(
          icon: Icons.add_circle_rounded,
          label: 'New Order',
          route: '/new_order',
          pageKey: 'new_order',
        ));
      }
      if (_canAccess('sales_summary')) {
        items.add(const _NavItem(
          icon: Icons.analytics_rounded,
          label: 'Sales Summary',
          route: '/sales_summary',
          pageKey: 'sales_summary',
        ));
      }
      if (items.isNotEmpty) {
        sections.add(_NavSection(header: 'ORDERS', items: items));
      }
    }

    // CART (staff only)
    if (isStaff) {
      final items = <_NavItem>[];
      if (_canAccess('daily_cart')) {
        items.add(const _NavItem(
          icon: Icons.calendar_today_rounded,
          label: 'Daily Cart',
          route: '/daily_cart',
          pageKey: 'daily_cart',
        ));
      }
      if (_canAccess('add_to_cart')) {
        items.add(const _NavItem(
          icon: Icons.shopping_basket_rounded,
          label: 'Add to Cart',
          route: '/add_to_cart',
          pageKey: 'add_to_cart',
        ));
      }
      if (items.isNotEmpty) {
        sections.add(_NavSection(header: 'CART', items: items));
      }
    }

    // OPERATIONS (staff only)
    if (isStaff) {
      final items = <_NavItem>[];
      if (_canAccess('grade_allocator')) {
        items.add(const _NavItem(
          icon: Icons.vibration_rounded,
          label: 'Grade Allocator',
          route: '/grade_allocator',
          pageKey: 'grade_allocator',
        ));
      }
      if (_canAccess('stock_tools')) {
        items.add(const _NavItem(
          icon: Icons.inventory_2_rounded,
          label: 'Stock Tools',
          route: '/stock_tools',
          pageKey: 'stock_tools',
        ));
      }
      if (_canAccess('task_management')) {
        items.add(const _NavItem(
          icon: Icons.assignment_ind_rounded,
          label: 'Task Allocator',
          route: '/task_management',
          pageKey: 'task_management',
        ));
      }
      items.add(const _NavItem(
        icon: Icons.task_alt_rounded,
        label: 'My Tasks',
        route: '/worker_tasks',
      ));
      if (items.isNotEmpty) {
        sections.add(_NavSection(header: 'OPERATIONS', items: items));
      }
    }

    // WORKFORCE (staff only)
    if (isStaff) {
      final items = <_NavItem>[];
      if (_canAccess('attendance')) {
        items.add(const _NavItem(
          icon: Icons.people_alt_rounded,
          label: 'Attendance',
          route: '/attendance',
          pageKey: 'attendance',
        ));
      }
      if (_canAccess('expenses')) {
        items.add(const _NavItem(
          icon: Icons.receipt_long_rounded,
          label: 'Expenses',
          route: '/expenses',
          pageKey: 'expenses',
        ));
      }
      if (_canAccess('gate_passes')) {
        items.add(const _NavItem(
          icon: Icons.badge_rounded,
          label: 'Gate Passes',
          route: '/gate_passes',
          pageKey: 'gate_passes',
        ));
      }
      if (items.isNotEmpty) {
        sections.add(_NavSection(header: 'WORKFORCE', items: items));
      }
    }

    // CLIENT (clients only)
    if (isClient) {
      sections.add(const _NavSection(
        header: 'CLIENT',
        items: [
          _NavItem(
            icon: Icons.send_rounded,
            label: 'My Requests',
            route: '/my_requests',
          ),
        ],
      ));
    }

    // SYSTEM (admin only)
    if (isAdmin) {
      final items = <_NavItem>[];
      if (_canAccess('pending_approvals')) {
        items.add(const _NavItem(
          icon: Icons.approval_rounded,
          label: 'Pending Approvals',
          route: '/pending_approvals',
          pageKey: 'pending_approvals',
        ));
      }
      items.add(const _NavItem(
        icon: Icons.notifications_rounded,
        label: 'Notifications',
        route: '/notifications',
      ));
      if (_canAccess('sales_summary')) {
        items.add(const _NavItem(
          icon: Icons.bar_chart_rounded,
          label: 'Reports',
          route: '/reports',
          pageKey: 'sales_summary',
        ));
      }
      if (_canAccess('admin')) {
        items.add(const _NavItem(
          icon: Icons.settings_rounded,
          label: 'Admin Panel',
          route: '/admin',
          pageKey: 'admin',
        ));
        items.add(const _NavItem(
          icon: Icons.tune_rounded,
          label: 'Dropdown Manager',
          route: '/dropdown_management',
          pageKey: 'admin',
        ));
      }
      if (items.isNotEmpty) {
        sections.add(_NavSection(header: 'SYSTEM', items: items));
      }
    }

    return sections;
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  bool _isActiveRoute(String itemRoute, String currentRoute) {
    if (currentRoute == itemRoute) return true;
    if (itemRoute == '/admin_dashboard' &&
        (currentRoute == '/' || currentRoute.isEmpty)) return true;
    if (itemRoute == '/client_dashboard' &&
        (currentRoute == '/' || currentRoute.isEmpty)) return true;
    if (currentRoute.startsWith(itemRoute) && itemRoute != '/') return true;
    return false;
  }

  String _roleBadgeLabel(String role) {
    switch (role) {
      case 'superadmin':
        return 'Super Admin';
      case 'admin':
        return 'Admin';
      case 'ops':
        return 'Operations';
      case 'employee':
        return 'Employee';
      case 'user':
        return 'User';
      case 'client':
        return 'Client';
      default:
        return role.isNotEmpty
            ? '${role[0].toUpperCase()}${role.substring(1)}'
            : 'User';
    }
  }

  Color _roleBadgeColor(String role) {
    switch (role) {
      case 'superadmin':
        return const Color(0xFFEF4444);
      case 'admin':
        return AppTheme.secondary;
      case 'ops':
        return const Color(0xFFF59E0B);
      case 'client':
        return const Color(0xFF10B981);
      default:
        return AppTheme.primary;
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final currentRoute = ModalRoute.of(context)?.settings.name ?? '';

    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        final role = auth.role?.toLowerCase() ?? '';
        final isClient = role == 'client';
        final isAdmin =
            role == 'superadmin' || role == 'admin' || role == 'ops';
        final isStaff = !isClient;

        final sections = _buildSections(
          isStaff: isStaff,
          isClient: isClient,
          isAdmin: isAdmin,
          role: role,
          pageAccess: auth.pageAccess,
        );

        return Scaffold(
          backgroundColor: const Color(0xFFF8F9FA),
          floatingActionButton: widget.floatingActionButton,
          body: Row(
            children: [
              // ── Sidebar ──────────────────────────────────────────
              _buildSidebar(context, auth, role, sections, currentRoute),

              // ── Main content area ────────────────────────────────
              Expanded(
                child: Column(
                  children: [
                    _buildTopBar(context),
                    Expanded(
                      child: Container(
                        color: const Color(0xFFF8F9FA),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          physics: const BouncingScrollPhysics(),
                          child: widget.child,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Sidebar ────────────────────────────────────────────────────────────

  Widget _buildSidebar(
    BuildContext context,
    AuthProvider auth,
    String role,
    List<_NavSection> sections,
    String currentRoute,
  ) {
    return Container(
      width: 260,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(color: Color(0xFFE5E7EB), width: 1),
        ),
      ),
      child: Column(
        children: [
          // ── Logo area ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.dashboard_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'EMPEROR CARDAMOM',
                    style: GoogleFonts.manrope(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.title,
                      letterSpacing: 0.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // ── Navigation ──
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                for (int si = 0; si < sections.length; si++) ...[
                  if (si > 0) const SizedBox(height: 8),
                  _buildSectionHeader(sections[si].header),
                  for (final item in sections[si].items)
                    _buildNavItem(context, item, currentRoute),
                ],
              ],
            ),
          ),

          // ── User profile section ──
          _buildUserSection(context, auth, role),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String header) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Text(
        header,
        style: GoogleFonts.manrope(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppTheme.muted,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    _NavItem item,
    String currentRoute,
  ) {
    final isActive = _isActiveRoute(item.route, currentRoute);
    final isHovered = _hoveredRoute == item.route;

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredRoute = item.route),
      onExit: (_) => setState(() => _hoveredRoute = null),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          Navigator.pushReplacementNamed(context, item.route);
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
          decoration: BoxDecoration(
            color: isActive
                ? AppTheme.primary.withOpacity(0.08)
                : isHovered
                    ? const Color(0xFFF3F4F6)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: isActive
                ? const Border(
                    left: BorderSide(color: AppTheme.primary, width: 3),
                  )
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                item.icon,
                size: 18,
                color: isActive ? AppTheme.primary : AppTheme.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.label,
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight:
                        isActive ? FontWeight.w600 : FontWeight.w500,
                    color: isActive ? AppTheme.primary : AppTheme.title,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserSection(
    BuildContext context,
    AuthProvider auth,
    String role,
  ) {
    final badgeColor = _roleBadgeColor(role);
    final badgeLabel = _roleBadgeLabel(role);
    final displayName = auth.username ?? 'User';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFE5E7EB), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Avatar circle
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.primary.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                displayName.isNotEmpty
                    ? displayName[0].toUpperCase()
                    : 'U',
                style: GoogleFonts.manrope(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Name + role badge
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.title,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badgeLabel,
                    style: GoogleFonts.manrope(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: badgeColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Logout button
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () {
                auth.logout();
                Navigator.pushReplacementNamed(context, '/login');
              },
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppTheme.danger.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.logout_rounded,
                  size: 16,
                  color: AppTheme.danger,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Top bar ────────────────────────────────────────────────────────────

  Widget _buildTopBar(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Page title
          Expanded(
            child: Text(
              widget.title,
              style: GoogleFonts.manrope(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.title,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Top actions from the page
          if (widget.topActions != null && widget.topActions!.isNotEmpty) ...[
            ...widget.topActions!,
            const SizedBox(width: 12),
          ],

          // Notification bell with badge
          Consumer2<AuthProvider, NotificationService>(
            builder: (context, auth, notifService, _) {
              final role = auth.role?.toLowerCase() ?? '';
              final isSuperadmin = role == 'superadmin';

              final adminPending =
                  isSuperadmin ? notifService.pendingApprovalCount : 0;
              final myUnread = notifService.myUnreadCount;
              final totalPending = adminPending + myUnread;

              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    Navigator.pushNamed(context, '/notifications');
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Stack(
                      children: [
                        const Center(
                          child: Icon(
                            Icons.notifications_outlined,
                            color: AppTheme.muted,
                            size: 22,
                          ),
                        ),
                        if (totalPending > 0)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: Color(0xFFEF4444),
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 16,
                                minHeight: 16,
                              ),
                              child: Text(
                                totalPending > 9
                                    ? '9+'
                                    : '$totalPending',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
