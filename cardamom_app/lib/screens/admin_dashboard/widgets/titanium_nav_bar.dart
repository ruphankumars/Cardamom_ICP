/// Titanium-styled floating bottom navigation bar for the admin dashboard.
///
/// A pill-shaped, blurred navigation bar positioned at the bottom of the screen
/// with machined-look active state indicators.
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_theme.dart';

/// Floating titanium navigation bar positioned at the bottom of the mobile layout.
class TitaniumNavBar extends StatelessWidget {
  /// The current active route for highlighting.
  final String currentRoute;

  const TitaniumNavBar({
    super.key,
    this.currentRoute = '/admin_dashboard',
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 20,
      left: 20,
      right: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: AppTheme.titaniumMid.withOpacity(0.9),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: Colors.white.withOpacity(0.4), width: 1),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 25, offset: const Offset(0, 12)),
                BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 4)),
                BoxShadow(color: Colors.white.withOpacity(0.05), blurRadius: 1, offset: const Offset(0, -1)),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(context, Icons.dashboard_rounded, currentRoute == '/admin_dashboard', '/admin_dashboard'),
                _buildNavItem(context, Icons.mail_rounded, currentRoute == '/order_requests', '/order_requests'),
                _buildNavItem(context, Icons.list_alt_rounded, currentRoute == '/view_orders', '/view_orders'),
                _buildNavItem(context, Icons.shopping_cart_rounded, currentRoute == '/daily_cart', '/daily_cart'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, IconData icon, bool isActive, String route) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        if (route == currentRoute) return; // Already here
        Navigator.pushReplacementNamed(context, route);
      },
      child: Container(
        width: 48, height: 48,
        decoration: isActive ? BoxDecoration(
          color: AppTheme.primary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: AppTheme.primary.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4)),
          ],
        ) : null,
        child: Icon(icon, color: isActive ? Colors.white : AppTheme.primary, size: 24),
      ),
    );
  }
}
