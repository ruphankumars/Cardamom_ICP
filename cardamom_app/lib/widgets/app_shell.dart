import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:ui';
import '../theme/app_theme.dart';
import 'package:provider/provider.dart';
import '../services/auth_provider.dart';
import '../services/access_control_service.dart';
import '../services/notification_service.dart';
import 'offline_indicator.dart';
import 'sync_status_widget.dart';
import '../services/navigation_service.dart';

/// Data model for top bar actions - allows different rendering on mobile vs desktop
class TopBarAction {
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final Color? color;
  final LinearGradient? gradient;

  const TopBarAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.color,
    this.gradient,
  });
}

class AppShell extends StatefulWidget {
  final Widget content;
  final String title;
  final String? subtitle;
  final List<Widget>? topActions;
  final Widget? floatingActionButton;
  final bool disableInternalScrolling;
  final bool showAppBar;
  final bool showBottomNav;

  const AppShell({
    super.key,
    required this.content,
    required this.title,
    this.subtitle,
    this.topActions,
    this.floatingActionButton,
    this.disableInternalScrolling = false,
    this.showAppBar = true,
    this.showBottomNav = true,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int? _selectedIndex;

  int _getSelectedIndex(String routeName, String role) {
    // Extract base path (remove query parameters)
    String basePath = routeName;
    if (routeName.contains('?')) {
      final uri = Uri.tryParse(routeName);
      if (uri != null) {
        basePath = uri.path;
      }
    }
    
    final isStaff = role == 'superadmin' || role == 'admin' || role == 'ops' || role == 'employee' || role == 'user';
    final isClient = role == 'client';

    // Handle staff role (4 items: Dashboard, Requests, Orders, Cart)
    if (isStaff) {
      if (basePath == '/' || basePath.isEmpty || basePath.startsWith('/admin_dashboard')) return 0;
      if (basePath.startsWith('/order_requests')) return 1;
      if (basePath.startsWith('/view_orders')) return 2;
      if (basePath.startsWith('/daily_cart')) return 3;
    } 
    // Handle client role: Dashboard and My Requests only
    else {
      if (basePath == '/' || basePath.isEmpty || basePath.startsWith('/client_dashboard') || basePath.startsWith('/admin_dashboard')) return 0;
      if (basePath.startsWith('/my_requests')) return 1;
    }
    return 0;
  }

  /// Build the list of bottom nav items filtered by access control.
  List<Map<String, dynamic>> _buildBottomNavItems(AuthProvider auth) {
    final role = auth.role?.toLowerCase() ?? '';
    final isStaff = role == 'superadmin' || role == 'admin' || role == 'ops' || role == 'employee' || role == 'user';
    bool can(String pageKey) => AccessControlService.canAccess(auth.pageAccess, pageKey, userRole: auth.role);

    if (!isStaff) {
      return [
        {'icon': Icons.home_rounded, 'label': 'Home', 'route': '/client_dashboard'},
        {'icon': Icons.send_rounded, 'label': 'Requests', 'route': '/my_requests'},
      ];
    }

    return [
      {'icon': Icons.dashboard_rounded, 'label': 'Dash', 'route': '/admin_dashboard'},
      if (can('order_requests')) {'icon': Icons.mail_rounded, 'label': 'Requests', 'route': '/order_requests'},
      if (can('view_orders')) {'icon': Icons.list_alt_rounded, 'label': 'Orders', 'route': '/view_orders'},
      if (can('daily_cart')) {'icon': Icons.shopping_cart_rounded, 'label': 'Cart', 'route': '/daily_cart'},
    ];
  }

  void _onItemTapped(int index, String role) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final items = _buildBottomNavItems(auth);
    if (index >= items.length) return;

    final route = items[index]['route'] as String;

    debugPrint('🔐 Bottom Nav: Navigating to route: $route');
    // Skip if already on this route (avoid duplicate pushes)
    final currentRoute = ModalRoute.of(context)?.settings.name ?? '';
    if (currentRoute == route) return;
    // Only update index and navigate if access is allowed
    setState(() {
      _selectedIndex = index;
    });
    // Dashboard is the root — clear the stack so there's no back history
    final isDashboard = route == '/admin_dashboard' || route == '/client_dashboard';
    if (isDashboard) {
      Navigator.pushNamedAndRemoveUntil(context, route, (r) => false);
    } else {
      Navigator.pushNamed(context, route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        final role = auth.role?.toLowerCase() ?? '';
        final isStaff = role == 'superadmin' || role == 'admin' || role == 'ops' || role == 'employee' || role == 'user';
        final modalRoute = ModalRoute.of(context);
        String currentRoute = modalRoute?.settings.name ?? '';
        
        // Derive index from route name
        int selectedIndex = _getSelectedIndex(currentRoute, role);
        
        // If user just tapped (stored index exists) and route is empty/not yet updated,
        // use stored index temporarily, then sync when route is available
        if (_selectedIndex != null && currentRoute.isEmpty) {
          selectedIndex = _selectedIndex!;
          // Sync with route once it's available
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              final updatedRoute = ModalRoute.of(context)?.settings.name ?? '';
              if (updatedRoute.isNotEmpty) {
                final correctIndex = _getSelectedIndex(updatedRoute, role);
                if (_selectedIndex != correctIndex) {
                  setState(() {
                    _selectedIndex = correctIndex;
                  });
                }
              }
            }
          });
        } else {
          // Route is available, use route-based index
          _selectedIndex = selectedIndex;
        }

        return Scaffold(
          extendBody: true,
          body: Container(
            decoration: const BoxDecoration(
              gradient: AppTheme.backgroundGradient,
            ),
            child: SafeArea(
              bottom: false, // Let content extend behind floating dock
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Offline status banner (shows when offline)
                  const OfflineIndicator(),
                  // Sync status badge (pending writes / syncing indicator)
                  const SyncStatusWidget(),
                  if (widget.showAppBar)
                    TopBar(
                      title: widget.title,
                      subtitle: widget.subtitle,
                      actions: widget.topActions,
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final child = ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: constraints.maxWidth,
                            minHeight: constraints.maxHeight,
                          ),
                          child: Padding(
                            padding: EdgeInsets.only(bottom: widget.showBottomNav ? 100 : 0), // Space for nav only if shown
                            child: widget.content,
                          ),
                        );

                        if (widget.disableInternalScrolling) {
                          return child;
                        }

                        return SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: child,
                        );
                      }
                    ),
                  ),
                  // Content will flow behind the dock (extendBody: true)
                ],
              ),
            ),
          ),
          drawer: const SidePanel(),
          drawerEnableOpenDragGesture: false, // Disable swipe-from-left to open drawer; allows iOS back gesture
          floatingActionButton: widget.floatingActionButton,
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          bottomNavigationBar: widget.showBottomNav ? _buildGlassBottomBar(role, selectedIndex) : null,
        );
      }
    );
  }

  Widget _buildGlassBottomBar(String role, int selectedIndex) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final items = _buildBottomNavItems(auth);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      height: 64,
      constraints: const BoxConstraints(maxWidth: 500),
      decoration: BoxDecoration(
        color: AppTheme.titaniumMid,
        borderRadius: BorderRadius.circular(9999),
        border: Border.all(color: Colors.white.withOpacity(0.4), width: 1),
        boxShadow: [
          // Machined bevel shadow
          const BoxShadow(
            color: Colors.white70,
            blurRadius: 2,
            offset: Offset(-1, -1),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
          // Floating shadow
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 25,
            offset: const Offset(0, 10),
            spreadRadius: -5,
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: items.asMap().entries.map((entry) {
          final int idx = entry.key;
          final Map<String, dynamic> item = entry.value;
          final bool isSelected = selectedIndex == idx;

          return GestureDetector(
            onTap: () => _onItemTapped(idx, role),
            behavior: HitTestBehavior.opaque,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack,
                  width: 48,
                  height: 48,
                  decoration: isSelected
                      ? BoxDecoration(
                          color: AppTheme.primary,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withOpacity(0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        )
                      : const BoxDecoration(color: Colors.transparent),
                  child: Icon(
                    item['icon'] as IconData,
                    color: isSelected ? Colors.white : AppTheme.primary,
                    size: 22,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class SidePanel extends StatelessWidget {
  const SidePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    
    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppTheme.titaniumLight, AppTheme.titaniumMid],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
          boxShadow: [
            const BoxShadow(
              color: Colors.white,
              blurRadius: 4,
              offset: Offset(-2, -2),
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 12,
              offset: const Offset(4, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  // Logo container with machined style
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: AppTheme.titaniumMid,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        const BoxShadow(
                          color: Colors.white70,
                          blurRadius: 2,
                          offset: Offset(-1, -1),
                        ),
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 4,
                          offset: const Offset(2, 2),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(6),
                    child: Image.asset('assets/images/emperor-logo.png', errorBuilder: (c, e, s) => Icon(Icons.business, size: 28, color: AppTheme.primary)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cardamom',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.title, letterSpacing: -0.5),
                        ),
                        Text(
                          'Manager',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.primary),
                        ),
                      ],
                    ),
                  ),
                  // Close button - machined disc style
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.titaniumMid,
                        borderRadius: BorderRadius.circular(9999),
                        boxShadow: [
                          const BoxShadow(
                            color: Colors.white70,
                            blurRadius: 2,
                            offset: Offset(-1, -1),
                          ),
                          BoxShadow(
                            color: Colors.black.withOpacity(0.15),
                            blurRadius: 4,
                            offset: const Offset(2, 2),
                          ),
                        ],
                      ),
                      child: Icon(Icons.close_rounded, size: 18, color: AppTheme.primary),
                    ),
                  ),
                ],
              ),
            ),
            // Navigation links
            Expanded(
              child: Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  final role = auth.role?.toLowerCase();
                  final isStaff = role != 'client'; // superadmin, user, admin, ops all use admin dashboard
                  final isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
                  bool can(String pageKey) => AccessControlService.canAccess(auth.pageAccess, pageKey, userRole: auth.role);
                  debugPrint('🔐 [SidePanel] Role: "$role" -> isAdmin: $isAdmin, isStaff: $isStaff');
                  return ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    children: [
                      _buildSideLink(context, Icons.home_rounded, 'Dashboard', isStaff ? '/admin_dashboard' : '/client_dashboard', auth: auth),
                      if (isStaff && can('order_requests')) _buildSideLink(context, Icons.mail_rounded, 'Order Requests', '/order_requests', auth: auth),
                      if (isStaff && can('new_order')) _buildSideLink(context, Icons.add_circle_rounded, 'New Order', '/new_order', auth: auth),
                      if (isStaff && can('view_orders')) _buildSideLink(context, Icons.list_alt_rounded, 'View Orders', '/view_orders', auth: auth),
                      if (isStaff && can('ledger')) _buildSideLink(context, Icons.menu_book_rounded, 'Ledger', '/ledger', auth: auth),
                      if (isStaff && can('sales_summary')) _buildSideLink(context, Icons.analytics_rounded, 'Sales Summary', '/sales_summary', auth: auth),
                      if (isStaff && can('add_to_cart')) _buildSideLink(context, Icons.shopping_basket_rounded, 'Add To Cart', '/add_to_cart', auth: auth),
                      if (isStaff && can('daily_cart')) _buildSideLink(context, Icons.calendar_today_rounded, 'Daily Cart', '/daily_cart', auth: auth),
                      if (isStaff && can('grade_allocator')) _buildSideLink(context, Icons.vibration_rounded, 'Grade Allocator', '/grade_allocator', auth: auth),
                      if (isStaff && can('dispatch_documents')) _buildSideLink(context, Icons.local_shipping_rounded, 'Dispatch Docs', '/dispatch_documents', auth: auth),
                      if (isStaff && can('dispatch_documents')) _buildSideLink(context, Icons.fire_truck_rounded, 'Transport Docs', '/transport_list', auth: auth),
                      if (isStaff && can('stock_tools')) _buildSideLink(context, Icons.inventory_2_rounded, 'Stock Tools', '/stock_tools', auth: auth),
                      if (isStaff && can('packed_boxes')) _buildSideLink(context, Icons.inventory_2_rounded, 'Packed Box', '/packed_boxes', auth: auth),
                      if (isStaff && can('outstanding')) _buildSideLink(context, Icons.account_balance_wallet_rounded, 'Outstanding', '/outstanding', auth: auth),
                      if (isAdmin) _buildSideLink(context, Icons.message_rounded, 'WA Send Log', '/whatsapp_logs', auth: auth),
                      if (isStaff && can('task_management')) _buildSideLink(context, Icons.task_alt_rounded, 'My Tasks', '/worker_tasks', auth: auth),
                      if (isStaff && can('task_management')) _buildSideLink(context, Icons.assignment_ind_rounded, 'Task Allocator', '/task_management', auth: auth),
                      if (isStaff && can('attendance')) _buildSideLink(context, Icons.people_alt_rounded, 'Attendance', '/attendance', auth: auth),
                      if (isStaff && can('expenses')) _buildSideLink(context, Icons.receipt_long_rounded, 'Expense Recorder', '/expenses', auth: auth),
                      if (isStaff && can('gate_passes')) _buildSideLink(context, Icons.badge_rounded, 'Gate Pass', '/gate_passes', auth: auth),
                      if (isStaff && can('offer_price')) _buildSideLink(context, Icons.local_offer_rounded, 'Offer Price', '/offer_price', auth: auth),
                      if (isAdmin) _buildSideLink(context, Icons.send_rounded, 'My Requests', '/my_requests', auth: auth),
                      if (isAdmin) _buildSideLink(context, Icons.notifications_rounded, 'Notifications', '/notifications', auth: auth),
                      if (isStaff && can('admin')) _buildSideLink(context, Icons.settings_rounded, 'Admin Panel', '/admin', auth: auth),
                      if (isStaff && can('dropdown_manager')) _buildSideLink(context, Icons.tune_rounded, 'Dropdown Manager', '/dropdown_management', auth: auth),
                      const SizedBox(height: 8),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        height: 1,
                        color: AppTheme.titaniumBorder,
                      ),
                      const SizedBox(height: 8),
                      _buildSideLink(context, Icons.logout_rounded, 'Logout', '/login', isLogout: true),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSideLink(BuildContext context, IconData icon, String label, String route, {bool isLogout = false, AuthProvider? auth}) {
    final currentRoute = ModalRoute.of(context)?.settings.name ?? '';
    final isSelected = currentRoute == route ||
                       (route == '/client_dashboard' && currentRoute == '/') ||
                       currentRoute.startsWith(route);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: isSelected
            ? AppTheme.primary.withOpacity(0.15)
            : (isLogout ? AppTheme.danger.withOpacity(0.08) : Colors.transparent),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isLogout
                ? AppTheme.danger.withOpacity(0.12)
                : (isSelected ? AppTheme.primary.withOpacity(0.15) : AppTheme.titaniumDark.withOpacity(0.3)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 18,
            color: isLogout
                ? AppTheme.danger
                : (isSelected ? AppTheme.primary : AppTheme.primary),
          ),
        ),
        title: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            color: isLogout
                ? AppTheme.danger
                : (isSelected ? AppTheme.primary : AppTheme.title),
          ),
        ),
        onTap: () {
          if (isLogout) {
            Provider.of<AuthProvider>(context, listen: false).logout();
            Navigator.pop(context);
            Navigator.pushReplacementNamed(context, route);
          } else {
            // Access check before navigating
            final a = auth ?? Provider.of<AuthProvider>(context, listen: false);
            if (!AccessControlService.canAccessRoute(a.pageAccess, route, userRole: a.role)) {
              Navigator.pop(context);
              AccessControlService.showNoAccessDialog(context);
              return;
            }
            Navigator.pop(context);
            Navigator.pushNamed(context, route);
          }
        },
      ),
    );
  }
}

/// Permanent desktop sidebar — same navigation as SidePanel but without Drawer wrapper
class DesktopSidePanel extends StatelessWidget {
  final void Function(String route) onNavigate;
  const DesktopSidePanel({super.key, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.titaniumLight, AppTheme.titaniumMid],
        ),
        border: Border(
          right: BorderSide(color: Colors.white.withOpacity(0.3), width: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppTheme.titaniumMid,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        const BoxShadow(color: Colors.white70, blurRadius: 2, offset: Offset(-1, -1)),
                        BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 4, offset: const Offset(2, 2)),
                      ],
                    ),
                    padding: const EdgeInsets.all(6),
                    child: Image.asset('assets/images/emperor-logo.png', errorBuilder: (c, e, s) => Icon(Icons.business, size: 24, color: AppTheme.primary)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Cardamom', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.title, letterSpacing: -0.5)),
                        Text('Manager', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.primary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            // Navigation links
            Expanded(
              child: Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  final role = auth.role?.toLowerCase();
                  final isStaff = role != 'client';
                  final isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
                  bool can(String pageKey) => AccessControlService.canAccess(auth.pageAccess, pageKey, userRole: auth.role);
                  return ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    children: [
                      _buildNavItem(context, Icons.home_rounded, 'Dashboard', isStaff ? '/admin_dashboard' : '/client_dashboard'),
                      if (isStaff && can('order_requests')) _buildNavItem(context, Icons.mail_rounded, 'Order Requests', '/order_requests'),
                      if (isStaff && can('new_order')) _buildNavItem(context, Icons.add_circle_rounded, 'New Order', '/new_order'),
                      if (isStaff && can('view_orders')) _buildNavItem(context, Icons.list_alt_rounded, 'View Orders', '/view_orders'),
                      if (isStaff && can('ledger')) _buildNavItem(context, Icons.menu_book_rounded, 'Ledger', '/ledger'),
                      if (isStaff && can('sales_summary')) _buildNavItem(context, Icons.analytics_rounded, 'Sales Summary', '/sales_summary'),
                      if (isStaff && can('add_to_cart')) _buildNavItem(context, Icons.shopping_basket_rounded, 'Add To Cart', '/add_to_cart'),
                      if (isStaff && can('daily_cart')) _buildNavItem(context, Icons.calendar_today_rounded, 'Daily Cart', '/daily_cart'),
                      if (isStaff && can('grade_allocator')) _buildNavItem(context, Icons.vibration_rounded, 'Grade Allocator', '/grade_allocator'),
                      if (isStaff && can('dispatch_documents')) _buildNavItem(context, Icons.local_shipping_rounded, 'Dispatch Docs', '/dispatch_documents'),
                      if (isStaff && can('dispatch_documents')) _buildNavItem(context, Icons.fire_truck_rounded, 'Transport Docs', '/transport_list'),
                      if (isStaff && can('stock_tools')) _buildNavItem(context, Icons.inventory_2_rounded, 'Stock Tools', '/stock_tools'),
                      if (isStaff && can('packed_boxes')) _buildNavItem(context, Icons.inventory_2_rounded, 'Packed Box', '/packed_boxes'),
                      if (isStaff && can('outstanding')) _buildNavItem(context, Icons.account_balance_wallet_rounded, 'Outstanding', '/outstanding'),
                      if (isAdmin) _buildNavItem(context, Icons.message_rounded, 'WA Send Log', '/whatsapp_logs'),
                      if (isStaff && can('task_management')) _buildNavItem(context, Icons.task_alt_rounded, 'My Tasks', '/worker_tasks'),
                      if (isStaff && can('task_management')) _buildNavItem(context, Icons.assignment_ind_rounded, 'Task Allocator', '/task_management'),
                      if (isStaff && can('attendance')) _buildNavItem(context, Icons.people_alt_rounded, 'Attendance', '/attendance'),
                      if (isStaff && can('expenses')) _buildNavItem(context, Icons.receipt_long_rounded, 'Expense Recorder', '/expenses'),
                      if (isStaff && can('gate_passes')) _buildNavItem(context, Icons.badge_rounded, 'Gate Pass', '/gate_passes'),
                      if (isStaff && can('offer_price')) _buildNavItem(context, Icons.local_offer_rounded, 'Offer Price', '/offer_price'),
                      if (isAdmin) _buildNavItem(context, Icons.send_rounded, 'My Requests', '/my_requests'),
                      if (isAdmin) _buildNavItem(context, Icons.notifications_rounded, 'Notifications', '/notifications'),
                      if (isStaff && can('admin')) _buildNavItem(context, Icons.settings_rounded, 'Admin Panel', '/admin'),
                      if (isStaff && can('dropdown_manager')) _buildNavItem(context, Icons.tune_rounded, 'Dropdown Manager', '/dropdown_management'),
                      const SizedBox(height: 8),
                      Container(margin: const EdgeInsets.symmetric(horizontal: 8), height: 1, color: AppTheme.titaniumBorder),
                      const SizedBox(height: 8),
                      _buildNavItem(context, Icons.logout_rounded, 'Logout', '/login', isLogout: true),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, IconData icon, String label, String route, {bool isLogout = false}) {
    return ValueListenableBuilder<String>(
      valueListenable: currentRouteNotifier,
      builder: (context, currentRoute, _) {
        final isSelected = currentRoute == route ||
            (route == '/client_dashboard' && currentRoute == '/') ||
            (route == '/admin_dashboard' && (currentRoute == '/' || currentRoute.isEmpty)) ||
            (route.length > 1 && currentRoute.startsWith(route));

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: isSelected
                ? AppTheme.primary.withOpacity(0.15)
                : (isLogout ? AppTheme.danger.withOpacity(0.08) : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            leading: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isLogout
                    ? AppTheme.danger.withOpacity(0.12)
                    : (isSelected ? AppTheme.primary.withOpacity(0.15) : AppTheme.titaniumDark.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 16, color: isLogout ? AppTheme.danger : AppTheme.primary),
            ),
            title: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isLogout ? AppTheme.danger : (isSelected ? AppTheme.primary : AppTheme.title),
              ),
            ),
            onTap: () {
              if (isLogout) {
                Provider.of<AuthProvider>(context, listen: false).logout();
                navigatorKey.currentState?.pushReplacementNamed(route);
              } else {
                onNavigate(route);
              }
            },
          ),
        );
      },
    );
  }
}

class TopBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  const TopBar({super.key, required this.title, this.subtitle, this.actions});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 500;
    
    return Container(
      margin: EdgeInsets.fromLTRB(isMobile ? 12 : 20, 12, isMobile ? 12 : 20, 0),
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 10 : 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.titaniumLight, AppTheme.titaniumMid],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
        boxShadow: [
          // Bevel shadow
          const BoxShadow(
            color: Colors.white,
            blurRadius: 4,
            offset: Offset(-2, -2),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Menu button - machined disc style
          GestureDetector(
            onTap: () => Scaffold.of(context).openDrawer(),
            child: Container(
              width: isMobile ? 36 : 40,
              height: isMobile ? 36 : 40,
              decoration: BoxDecoration(
                color: AppTheme.titaniumMid,
                borderRadius: BorderRadius.circular(9999),
                boxShadow: [
                  const BoxShadow(
                    color: Colors.white70,
                    blurRadius: 2,
                    offset: Offset(-1, -1),
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 4,
                    offset: const Offset(2, 2),
                  ),
                ],
              ),
              child: Icon(Icons.menu_rounded, color: AppTheme.primary, size: isMobile ? 18 : 22),
            ),
          ),
          SizedBox(width: isMobile ? 8 : 12),
          // Title and subtitle - takes remaining space
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.manrope(
                    fontSize: isMobile ? 14 : 18,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.title,
                    letterSpacing: -0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                if (subtitle != null && !isMobile)
                  Text(
                    subtitle!,
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
              ],
            ),
          ),
          // Notification Bell with badge (for all users)
          Consumer2<AuthProvider, NotificationService>(
            builder: (context, auth, notifService, _) {
              final role = auth.role?.toLowerCase() ?? '';
              final isSuperadmin = role == 'superadmin';

              // Badge shows pending approvals (superadmin only) + my unread requests (for all users)
              final adminPending = isSuperadmin ? notifService.pendingApprovalCount : 0;
              final myUnread = notifService.myUnreadCount; // Total unread (pending + resolved not dismissed)
              final totalPending = adminPending + myUnread;
              
              // NOTE: Do NOT auto-fetch here. Polling is managed by NotificationService.initializeRealtime().
              // The previous auto-fetch caused an infinite loop when totalPending == 0:
              //   fetch → notifyListeners → rebuild → totalPending still 0 → fetch again → ∞
              
              return GestureDetector(
                onTap: () => _showNotificationPopup(context, notifService),
                child: Container(
                  width: isMobile ? 36 : 40,
                  height: isMobile ? 36 : 40,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.titaniumMid,
                    borderRadius: BorderRadius.circular(9999),
                    boxShadow: [
                      const BoxShadow(
                        color: Colors.white70,
                        blurRadius: 2,
                        offset: Offset(-1, -1),
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 4,
                        offset: const Offset(2, 2),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: Icon(
                          Icons.notifications_rounded,
                          color: AppTheme.primary,
                          size: isMobile ? 18 : 22,
                        ),
                      ),
                      if (totalPending > 0)
                        Positioned(
                          right: 2,
                          top: 2,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Color(0xFFEF4444),
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                            child: Text(
                              totalPending > 9 ? '9+' : '$totalPending',
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
              );
            },
          ),
          // Actions - render directly (each screen manages its own mobile layout)
          if (actions != null && actions!.isNotEmpty) ...[
            SizedBox(width: isMobile ? 2 : 8),
            ...actions!,
          ],
        ],
      ),
    );
  }
  
  void _showNotificationPopup(BuildContext context, NotificationService service) {
    final parentContext = context;
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Notifications',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return Align(
          alignment: Alignment.topCenter,
          child: Material(
            color: Colors.transparent,
            child: Container(
              margin: EdgeInsets.only(
                top: MediaQuery.of(dialogContext).padding.top + 10,
                left: 12,
                right: 12,
              ),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(dialogContext).size.height * 0.7,
              ),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB)],
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.notifications_active_rounded, color: Color(0xFFEF4444), size: 20),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text('Notifications', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            Navigator.pushNamed(parentContext, '/notifications');
                          },
                          child: const Text('View All', style: TextStyle(fontSize: 12, color: Color(0xFF10B981), fontWeight: FontWeight.w600)),
                        ),
                        TextButton(
                          onPressed: () {
                            service.markAllAsRead();
                            Navigator.pop(dialogContext);
                          },
                          child: const Text('Mark all as read', style: TextStyle(fontSize: 12, color: Color(0xFF5D6E7E))),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B), size: 20),
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                  // Scrollable content
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Approval Requests Section (superadmin only — they are the approver)
                          // Regular admin/ops see their own requests in "MY REQUESTS" with pending status
                          Consumer<NotificationService>(
                            builder: (ctx, notifService, _) {
                              final role = Provider.of<AuthProvider>(ctx, listen: false).role?.toLowerCase() ?? '';
                              final isSuperadmin = role == 'superadmin';
                              final pendingApprovals = notifService.pendingApprovals;

                              if (!isSuperadmin || pendingApprovals.isEmpty) {
                                return const SizedBox.shrink();
                              }

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                                    child: Row(
                                      children: [
                                        Text(
                                          'APPROVAL REQUESTS',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.grey[600],
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEF4444),
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            '${pendingApprovals.length}',
                                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ...pendingApprovals.map((request) {
                                    return _CompactApprovalCard(
                                      request: request,
                                      onAction: () => Navigator.pop(dialogContext),
                                    );
                                  }),
                                  const SizedBox(height: 8),
                                  Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 20),
                                    height: 1,
                                    color: const Color(0xFFE2E8F0),
                                  ),
                                ],
                              );
                            },
                          ),
                          // MY REQUESTS Section
                          Consumer<NotificationService>(
                            builder: (ctx, notifService, _) {
                              final myRequests = notifService.myRequestsUnread;
                              final role = Provider.of<AuthProvider>(ctx, listen: false).role?.toLowerCase() ?? '';
                              // Show action buttons for superadmin, admin, and ops roles
                              final isSuperadmin = role == 'superadmin' || role == 'admin' || role == 'ops';
                              debugPrint('[NotifPanel] MY REQUESTS role="$role" isSuperadmin=$isSuperadmin count=${myRequests.length}');

                              if (myRequests.isEmpty) {
                                return const SizedBox.shrink();
                              }

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                                    child: Row(
                                      children: [
                                        Text(
                                          'MY REQUESTS',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.grey[600],
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Icon(Icons.send, size: 14, color: Color(0xFF3B82F6)),
                                      ],
                                    ),
                                  ),
                                  ...myRequests.map((request) {
                                    final isPending = request.status == 'pending';
                                    final isApproved = request.status == 'approved';
                                    final canDismiss = !isPending;

                                    Color statusColor;
                                    IconData statusIcon;
                                    String statusText;
                                    Color bgColor;

                                    if (isPending) {
                                      statusColor = const Color(0xFFF59E0B);
                                      statusIcon = Icons.hourglass_top;
                                      statusText = 'Pending';
                                      bgColor = const Color(0xFFFEFCE8);
                                    } else if (isApproved) {
                                      statusColor = const Color(0xFF10B981);
                                      statusIcon = Icons.check_circle;
                                      statusText = 'Approved';
                                      bgColor = const Color(0xFFECFDF5);
                                    } else {
                                      statusColor = const Color(0xFFEF4444);
                                      statusIcon = Icons.cancel;
                                      statusText = 'Rejected';
                                      bgColor = const Color(0xFFFEF2F2);
                                    }

                                    final diff = DateTime.now().difference(request.createdAt);
                                    String timeAgo;
                                    if (diff.inMinutes < 1) {
                                      timeAgo = 'Just now';
                                    } else if (diff.inMinutes < 60) {
                                      timeAgo = '${diff.inMinutes}m ago';
                                    } else if (diff.inHours < 24) {
                                      timeAgo = '${diff.inHours}h ago';
                                    } else {
                                      timeAgo = '${diff.inDays}d ago';
                                    }

                                    // Always show action buttons on pending cards for admin roles
                                    final showActions = isPending;

                                    final cardWidget = GestureDetector(
                                      onTap: () {
                                        // Open detail dialog with approve/reject
                                        if (showActions) {
                                          _showMyRequestDetailDialog(ctx, request, notifService, dialogContext);
                                        }
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: bgColor,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: statusColor.withOpacity(0.3)),
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(
                                                color: statusColor.withOpacity(0.1),
                                                shape: BoxShape.circle,
                                              ),
                                              child: Icon(statusIcon, color: statusColor, size: 16),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    '${request.actionType.substring(0, 1).toUpperCase()}${request.actionType.substring(1)} ${request.resourceType}',
                                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                                                  ),
                                                  if (request.requesterName.isNotEmpty)
                                                    Text(
                                                      'From: ${request.requesterName}',
                                                      style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                                                    ),
                                                  Text(
                                                    timeAgo,
                                                    style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            // Approve/reject buttons on all pending cards
                                            if (showActions) ...[
                                              GestureDetector(
                                                onTap: () => _quickApproveRequest(ctx, request, notifService, dialogContext),
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
                                              const SizedBox(width: 6),
                                              GestureDetector(
                                                onTap: () => _quickRejectRequest(ctx, request, notifService, dialogContext),
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
                                            ] else
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: statusColor.withOpacity(0.1),
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border.all(color: statusColor.withOpacity(0.3)),
                                                ),
                                                child: Text(
                                                  statusText,
                                                  style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    );

                                    if (canDismiss) {
                                      return Dismissible(
                                        key: Key(request.id),
                                        direction: DismissDirection.endToStart,
                                        confirmDismiss: (direction) async {
                                          return await notifService.dismissRequest(request.id);
                                        },
                                        background: Container(
                                          alignment: Alignment.centerRight,
                                          padding: const EdgeInsets.only(right: 16),
                                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF94A3B8),
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: const Icon(Icons.check, color: Colors.white, size: 18),
                                        ),
                                        child: cardWidget,
                                      );
                                    }
                                    return cardWidget;
                                  }),
                                  const SizedBox(height: 8),
                                  Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 20),
                                    height: 1,
                                    color: const Color(0xFFE2E8F0),
                                  ),
                                ],
                              );
                            },
                          ),
                          // System Notifications / Alerts
                          Consumer<NotificationService>(
                            builder: (ctx, notifService, _) {
                              final notifications = notifService.notifications;
                              final myRequests = notifService.myRequestsUnread;
                              final role = Provider.of<AuthProvider>(ctx, listen: false).role?.toLowerCase() ?? '';
                              final isSuperadmin = role == 'superadmin';
                              final hasAdminApprovals = isSuperadmin && notifService.pendingApprovals.isNotEmpty;

                              // Show empty state if nothing at all
                              if (notifications.isEmpty && myRequests.isEmpty && !hasAdminApprovals) {
                                return Padding(
                                  padding: const EdgeInsets.all(40),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.notifications_off_outlined, size: 48, color: Colors.grey[300]),
                                      const SizedBox(height: 12),
                                      Text('No notifications', style: TextStyle(color: Colors.grey[500], fontSize: 14)),
                                    ],
                                  ),
                                );
                              }
                              if (notifications.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                                    child: Text(
                                      'ALERTS',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.grey[600],
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                  ),
                                  ...notifications.map((notification) {
                                    IconData icon;
                                    Color iconColor;
                                    Color bgColor;

                                    switch (notification.type) {
                                      case 'stock':
                                        icon = Icons.inventory_2_rounded;
                                        iconColor = const Color(0xFFEF4444);
                                        bgColor = const Color(0xFFFEE2E2);
                                        break;
                                      case 'orders':
                                        icon = Icons.shopping_cart_rounded;
                                        iconColor = const Color(0xFF5D6E7E);
                                        bgColor = const Color(0xFFE0E7FF);
                                        break;
                                      case 'sync':
                                        icon = Icons.sync_rounded;
                                        iconColor = const Color(0xFF10B981);
                                        bgColor = const Color(0xFFD1FAE5);
                                        break;
                                      case 'alert':
                                        icon = Icons.warning_amber_rounded;
                                        iconColor = const Color(0xFFF59E0B);
                                        bgColor = const Color(0xFFFEF3C7);
                                        break;
                                      default:
                                        icon = Icons.info_outline_rounded;
                                        iconColor = const Color(0xFF64748B);
                                        bgColor = const Color(0xFFF1F5F9);
                                    }

                                    final diff = DateTime.now().difference(notification.timestamp);
                                    String timeAgo;
                                    if (diff.inMinutes < 1) {
                                      timeAgo = 'Just now';
                                    } else if (diff.inMinutes < 60) {
                                      timeAgo = '${diff.inMinutes}m ago';
                                    } else if (diff.inHours < 24) {
                                      timeAgo = '${diff.inHours}h ago';
                                    } else {
                                      timeAgo = '${diff.inDays}d ago';
                                    }

                                    return Dismissible(
                                      key: Key(notification.id),
                                      direction: DismissDirection.endToStart,
                                      background: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.red[400],
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        alignment: Alignment.centerRight,
                                        padding: const EdgeInsets.only(right: 20),
                                        child: const Icon(Icons.delete_rounded, color: Colors.white),
                                      ),
                                      onDismissed: (_) {
                                        notifService.removeNotification(notification.id);
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: notification.isRead ? Colors.white : const Color(0xFFF8FAFC),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: const Color(0xFFE2E8F0)),
                                        ),
                                        child: ListTile(
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                          leading: Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(10)),
                                            child: Icon(icon, color: iconColor, size: 20),
                                          ),
                                          title: Text(
                                            notification.title,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: notification.isRead ? FontWeight.w500 : FontWeight.bold,
                                              color: const Color(0xFF4A5568),
                                            ),
                                          ),
                                          subtitle: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(notification.body, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                                              const SizedBox(height: 4),
                                              Text(timeAgo, style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                                            ],
                                          ),
                                          onTap: () {
                                            notifService.markAsRead(notification.id);
                                            Navigator.pop(dialogContext);
                                          },
                                        ),
                                      ),
                                    );
                                  }),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -1),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          )),
          child: child,
        );
      },
    );
  }

  // ── Helper: Quick approve from MY REQUESTS card ──
  Future<void> _quickApproveRequest(BuildContext context, ApprovalRequest request, NotificationService service, BuildContext panelContext) async {
    final adminId = Provider.of<AuthProvider>(context, listen: false).userId ?? '';
    final adminName = Provider.of<AuthProvider>(context, listen: false).username ?? 'Admin';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final success = await service.approveRequest(request.id, adminId, adminName);

      if (success) {
        service.removeApprovalRequest(request.id);
        service.fetchMyRequests();
        if (context.mounted) {
          Navigator.pop(panelContext); // Close notification panel
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Request approved'), backgroundColor: Color(0xFF10B981)),
          );
        }
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to approve request'), backgroundColor: Color(0xFFEF4444)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    } finally {
      if (context.mounted) Navigator.pop(context); // Close loading dialog
    }
  }

  // ── Helper: Quick reject from MY REQUESTS card ──
  Future<void> _quickRejectRequest(BuildContext context, ApprovalRequest request, NotificationService service, BuildContext panelContext) async {
    final reasonController = TextEditingController();

    try {
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
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
              child: const Text('Reject'),
            ),
          ],
        ),
      );

      if (confirmed != true || !context.mounted) return;

      final adminId = Provider.of<AuthProvider>(context, listen: false).userId ?? '';
      final adminName = Provider.of<AuthProvider>(context, listen: false).username ?? 'Admin';
      final reason = reasonController.text.isNotEmpty ? reasonController.text : 'No reason provided';

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      try {
        final success = await service.rejectRequest(request.id, adminId, adminName, reason);

        if (success) {
          service.removeApprovalRequest(request.id);
          service.fetchMyRequests();
          if (context.mounted) {
            Navigator.pop(panelContext); // Close notification panel
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Request rejected'), backgroundColor: Color(0xFFEF4444)),
            );
          }
        } else if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to reject request'), backgroundColor: Color(0xFFEF4444)),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFEF4444)),
          );
        }
      } finally {
        if (context.mounted) Navigator.pop(context); // Close loading dialog
      }
    } finally {
      reasonController.dispose();
    }
  }

  // ── Helper: Detail dialog for MY REQUESTS with approve/reject ──
  void _showMyRequestDetailDialog(BuildContext context, ApprovalRequest request, NotificationService service, BuildContext dialogContext) {
    final isDelete = request.actionType == 'delete';
    final actionColor = isDelete ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    final adminId = Provider.of<AuthProvider>(context, listen: false).userId ?? '';
    final adminName = Provider.of<AuthProvider>(context, listen: false).username ?? 'Admin';

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: actionColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isDelete ? Icons.delete_rounded : Icons.edit_rounded,
                      color: actionColor,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${request.actionType.toUpperCase()} Request',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'From: ${request.requesterName}',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('PENDING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFF59E0B))),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: const Icon(Icons.close, color: Color(0xFF64748B), size: 20),
                  ),
                ],
              ),
              const Divider(height: 24),
              // Resource details
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (request.resourceData != null && request.resourceData!.isNotEmpty) ...[
                        const Text('RESOURCE DETAILS:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            children: request.resourceData!.entries
                                .where((e) => e.value != null && e.value.toString().isNotEmpty)
                                .map((e) => Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(width: 80, child: Text('${e.key}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)))),
                                      Expanded(child: Text('${e.value}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
                                    ],
                                  ),
                                )).toList(),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (!isDelete && request.proposedChanges != null && request.proposedChanges!.isNotEmpty) ...[
                        const Text('PROPOSED CHANGES:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFD97706))),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFFCD34D)),
                          ),
                          child: Column(
                            children: request.proposedChanges!.entries
                                .where((e) => e.value != null && e.value.toString().isNotEmpty)
                                .map((e) => Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(width: 80, child: Text('${e.key}', style: const TextStyle(fontSize: 11, color: Color(0xFF92400E)))),
                                      Expanded(child: Text('${e.value}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFFD97706)))),
                                    ],
                                  ),
                                )).toList(),
                          ),
                        ),
                      ],
                      if (request.reason != null && request.reason!.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text('REASON:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                        const SizedBox(height: 4),
                        Text(request.reason!, style: const TextStyle(fontSize: 13)),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Approve / Reject buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        Navigator.pop(dialogContext); // Close notification panel

                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => const Center(child: CircularProgressIndicator()),
                        );

                        try {
                          final success = await service.approveRequest(request.id, adminId, adminName);

                          if (success) {
                            service.removeApprovalRequest(request.id);
                            service.fetchMyRequests();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Request approved'), backgroundColor: Color(0xFF10B981)),
                              );
                            }
                          } else if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Failed to approve request'), backgroundColor: Color(0xFFEF4444)),
                            );
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
                      },
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);

                        final reasonController = TextEditingController();
                        final reason = await showDialog<String>(
                          context: context,
                          builder: (dlg) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            title: const Text('Rejection Reason'),
                            content: TextField(
                              controller: reasonController,
                              decoration: InputDecoration(
                                labelText: 'Reason (optional)',
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              maxLines: 2,
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(dlg), child: const Text('Cancel')),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(dlg, reasonController.text),
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                                child: const Text('Reject'),
                              ),
                            ],
                          ),
                        );

                        if (reason == null || !context.mounted) {
                          reasonController.dispose();
                          return;
                        }

                        Navigator.pop(dialogContext); // Close notification panel
                        final rejectReason = reason.isNotEmpty ? reason : 'No reason provided';
                        reasonController.dispose();

                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => const Center(child: CircularProgressIndicator()),
                        );

                        try {
                          final success = await service.rejectRequest(request.id, adminId, adminName, rejectReason);

                          if (success) {
                            service.removeApprovalRequest(request.id);
                            service.fetchMyRequests();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Request rejected'), backgroundColor: Color(0xFFEF4444)),
                              );
                            }
                          } else if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Failed to reject request'), backgroundColor: Color(0xFFEF4444)),
                            );
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
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('Reject', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
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
}


/// Compact approval card for the notification popup.
/// Shows approve/reject buttons directly on the card, and opens a detail
/// dialog when tapped. Works from any page via the notification bell.
class _CompactApprovalCard extends StatelessWidget {
  final ApprovalRequest request;
  final VoidCallback onAction;

  const _CompactApprovalCard({required this.request, required this.onAction});

  // ── Helpers to read admin credentials from AuthProvider ──

  String _adminId(BuildContext context) {
    try {
      return Provider.of<AuthProvider>(context, listen: false).userId ?? '';
    } catch (_) {
      return '';
    }
  }

  String _adminName(BuildContext context) {
    try {
      return Provider.of<AuthProvider>(context, listen: false).username ?? 'Admin';
    } catch (_) {
      return 'Admin';
    }
  }

  // ── Quick approve (from card button) ──

  Future<void> _quickApprove(BuildContext context) async {
    final adminId = _adminId(context);
    final adminName = _adminName(context);
    final service = context.read<NotificationService>();

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final success = await service.approveRequest(request.id, adminId, adminName);

    if (context.mounted) Navigator.pop(context); // close loading

    if (success) {
      service.removeApprovalRequest(request.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request approved'), backgroundColor: Color(0xFF10B981)),
        );
      }
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to approve request'), backgroundColor: Color(0xFFEF4444)),
      );
    }
  }

  // ── Quick reject (from card button) — shows reason dialog first ──

  Future<void> _quickReject(BuildContext context) async {
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final adminId = _adminId(context);
    final adminName = _adminName(context);
    final reason = reasonController.text.isNotEmpty ? reasonController.text : 'No reason provided';
    final service = context.read<NotificationService>();

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final success = await service.rejectRequest(request.id, adminId, adminName, reason);

    if (context.mounted) Navigator.pop(context); // close loading

    if (success) {
      service.removeApprovalRequest(request.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request rejected'), backgroundColor: Color(0xFFEF4444)),
        );
      }
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to reject request'), backgroundColor: Color(0xFFEF4444)),
      );
    }
  }

  // ── Detail dialog (opened by tapping the card) ──

  void _showDetailDialog(BuildContext context) {
    final isDelete = request.actionType == 'delete';
    final actionColor = isDelete ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    // Capture credentials before opening dialog (context may change)
    final adminId = _adminId(context);
    final adminName = _adminName(context);

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: actionColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isDelete ? Icons.delete_rounded : Icons.edit_rounded,
                      color: actionColor,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${request.actionType.toUpperCase()} Request',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'By ${request.requesterName}',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(height: 24),

              // Resource details
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Resource data section
                      if (request.resourceData != null && request.resourceData!.isNotEmpty) ...[
                        const Text('RESOURCE DETAILS:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                        const SizedBox(height: 8),
                        ..._buildResourceData(request.resourceData),
                        const SizedBox(height: 12),
                      ],
                      // Proposed changes
                      if (!isDelete && request.proposedChanges != null) ...[
                        const Text('PROPOSED CHANGES:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                        const SizedBox(height: 8),
                        ..._buildChanges(request.resourceData, request.proposedChanges),
                      ] else if (isDelete && (request.resourceData == null || request.resourceData!.isEmpty)) ...[
                        const Text('ITEM TO DELETE:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFEF4444))),
                        const SizedBox(height: 8),
                        ..._buildResourceData(request.resourceData),
                      ],
                      if (request.reason != null && request.reason!.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text('REASON:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                        const SizedBox(height: 4),
                        Text(request.reason!, style: const TextStyle(fontSize: 13)),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
              // Action buttons — wired to real API endpoints
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        onAction();
                        final service = context.read<NotificationService>();

                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => const Center(child: CircularProgressIndicator()),
                        );

                        final success = await service.approveRequest(request.id, adminId, adminName);

                        if (context.mounted) Navigator.pop(context);

                        if (success) {
                          service.removeApprovalRequest(request.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Request approved'), backgroundColor: Color(0xFF10B981)),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Approve'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);

                        // Show rejection reason dialog
                        final reasonController = TextEditingController();
                        final reason = await showDialog<String>(
                          context: context,
                          builder: (dlg) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            title: const Text('Rejection Reason'),
                            content: TextField(
                              controller: reasonController,
                              decoration: InputDecoration(
                                labelText: 'Reason (optional)',
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              maxLines: 2,
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(dlg), child: const Text('Cancel')),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(dlg, reasonController.text),
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                                child: const Text('Reject'),
                              ),
                            ],
                          ),
                        );

                        if (reason == null || !context.mounted) return;

                        onAction();
                        final service = context.read<NotificationService>();
                        final rejectReason = reason.isNotEmpty ? reason : 'No reason provided';

                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => const Center(child: CircularProgressIndicator()),
                        );

                        final success = await service.rejectRequest(request.id, adminId, adminName, rejectReason);

                        if (context.mounted) Navigator.pop(context);

                        if (success) {
                          service.removeApprovalRequest(request.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Request rejected'), backgroundColor: Color(0xFFEF4444)),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Reject'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
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

  List<Widget> _buildChanges(Map<String, dynamic>? original, Map<String, dynamic>? proposed) {
    if (proposed == null) return [];
    final widgets = <Widget>[];

    proposed.forEach((key, newValue) {
      final oldValue = original?[key];
      final isChanged = oldValue?.toString() != newValue?.toString();

      if (isChanged && key != 'notes') {
        widgets.add(Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 70,
                child: Text(
                  key.toUpperCase(),
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF92400E)),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$oldValue -> $newValue', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ));
      }
    });

    if (widgets.isEmpty) {
      widgets.add(const Text('No field changes detected', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)));
    }
    return widgets;
  }

  List<Widget> _buildResourceData(Map<String, dynamic>? data) {
    if (data == null) return [const Text('No data available')];
    final widgets = <Widget>[];

    data.forEach((key, value) {
      if (value != null && value.toString().isNotEmpty && key != 'notes') {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                child: Text('$key:', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
              ),
              Expanded(
                child: Text('$value', style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ));
      }
    });
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final isDelete = request.actionType == 'delete';
    final actionColor = isDelete ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    final actionIcon = isDelete ? Icons.delete_rounded : Icons.edit_rounded;
    final actionLabel = isDelete ? 'Delete' : 'Edit';

    final diff = DateTime.now().difference(request.createdAt);
    String timeAgo;
    if (diff.inMinutes < 60) {
      timeAgo = '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      timeAgo = '${diff.inHours}h ago';
    } else {
      timeAgo = '${diff.inDays}d ago';
    }

    return GestureDetector(
      onTap: () => _showDetailDialog(context),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: actionColor.withOpacity(0.2)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Action type icon
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: actionColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(actionIcon, color: actionColor, size: 16),
            ),
            const SizedBox(width: 10),
            // Request info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: actionColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          actionLabel,
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: actionColor),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          request.requesterName,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _getResourceSummary(),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    timeAgo,
                    style: const TextStyle(fontSize: 9, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
            // Approve/Reject buttons
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () => _quickApprove(context),
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
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _quickReject(context),
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
    );
  }

  String _getResourceSummary() {
    final data = request.resourceData;
    if (data == null) return request.resourceType;

    // Try to build a summary from common fields
    final client = data['client'] ?? data['name'] ?? '';
    final grade = data['grade'] ?? '';
    final lot = data['lot'] ?? '';

    if (client.toString().isNotEmpty) {
      return '$client${lot.toString().isNotEmpty ? ' - $lot' : ''}${grade.toString().isNotEmpty ? ' ($grade...)' : ''}';
    }
    return request.resourceType;
  }
}

