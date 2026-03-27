/// Precision tools grid widget for the admin dashboard.
///
/// Displays a 2x4 grid of navigation action buttons for key app features
/// in a machined titanium style.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../../services/access_control_service.dart';
import '../../../services/auth_provider.dart';
import '../../../theme/app_theme.dart';

/// A grid of precision tool action buttons for quick navigation.
/// Automatically filters items based on user's pageAccess permissions.
class PrecisionToolsGrid extends StatelessWidget {
  final BuildContext navContext;

  const PrecisionToolsGrid({
    super.key,
    required this.navContext,
  });

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    bool can(String pageKey) => AccessControlService.canAccess(auth.pageAccess, pageKey, userRole: auth.role);

    final items = <Widget>[
      if (can('new_order')) _buildPrecisionItem(Icons.add_circle_outline, 'NEW ORDER', () => Navigator.pushNamed(navContext, '/new_order')),
      if (can('view_orders')) _buildPrecisionItem(Icons.list_alt_rounded, 'ORDERS', () => Navigator.pushNamed(navContext, '/view_orders')),
      if (can('daily_cart')) _buildPrecisionItem(Icons.shopping_cart_outlined, 'CART', () => Navigator.pushNamed(navContext, '/daily_cart')),
      if (can('stock_tools')) _buildPrecisionItem(Icons.inventory_2_outlined, 'STOCK', () => Navigator.pushNamed(navContext, '/stock_tools')),
      if (can('dispatch_documents')) _buildPrecisionItem(Icons.local_shipping_outlined, 'DISPATCH', () => Navigator.pushNamed(navContext, '/dispatch_documents')),
      if (can('ledger')) _buildPrecisionItem(Icons.menu_book_outlined, 'LEDGER', () => Navigator.pushNamed(navContext, '/ledger')),
      if (can('sales_summary')) _buildPrecisionItem(Icons.bar_chart_rounded, 'SALES', () => Navigator.pushNamed(navContext, '/sales_summary')),
      if (can('order_requests')) _buildPrecisionItem(Icons.mail_outlined, 'REQUESTS', () => Navigator.pushNamed(navContext, '/order_requests')),
      if (can('pending_approvals')) _buildPrecisionItem(Icons.check_circle_outline, 'APPROVALS', () => Navigator.pushNamed(navContext, '/pending_approvals')),
      if (can('admin')) _buildPrecisionItem(Icons.settings_outlined, 'ADMIN', () => Navigator.pushNamed(navContext, '/admin')),
    ];

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 4,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 0.95,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: items,
    );
  }

  Widget _buildPrecisionItem(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB)],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 3, offset: const Offset(2, 2)),
            const BoxShadow(color: Colors.white70, blurRadius: 3, offset: Offset(-1, -1)),
          ],
          border: Border.all(color: Colors.white.withOpacity(0.4), width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppTheme.primary, size: 24),
            const SizedBox(height: 6),
            Text(
              label,
              style: GoogleFonts.manrope(
                fontSize: 8,
                fontWeight: FontWeight.w900,
                color: AppTheme.primary,
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Section header label widget used across the dashboard.
class DashboardSectionHeader extends StatelessWidget {
  final String title;

  const DashboardSectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(
        title.toUpperCase(),
        style: GoogleFonts.manrope(
          fontSize: 12,
          fontWeight: FontWeight.w900,
          color: AppTheme.primary,
          letterSpacing: 2.0,
        ),
      ),
    );
  }
}
