import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/auth_provider.dart';
import '../services/access_control_service.dart';
import '../services/api_service.dart';

/// A widget that wraps a screen and checks access permissions
/// before allowing the user to view the content.
/// Supports both page-level access control and role-based access,
/// with JWT token expiry validation.
class ProtectedRoute extends StatelessWidget {
  final String pageKey;
  final Widget child;
  final List<String>? requiredRoles;

  const ProtectedRoute({
    super.key,
    required this.pageKey,
    required this.child,
    this.requiredRoles,
  });

  /// Check if the stored JWT token is still valid (not expired).
  Future<bool> _isTokenValid() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    return !AccessControlService.isTokenExpired(token);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        // Check if user has access to this page (admins always have full access)
        if (!AccessControlService.canAccess(auth.pageAccess, pageKey, userRole: auth.role)) {
          _notifyAdminOfRestriction(auth);
          return _buildAccessDeniedScreen(context);
        }

        // Check role-based access if requiredRoles is specified
        if (requiredRoles != null && requiredRoles!.isNotEmpty) {
          final userRole = auth.role?.toLowerCase() ?? '';
          if (!requiredRoles!.any((r) => r.toLowerCase() == userRole)) {
            _notifyAdminOfRestriction(auth);
            return _buildAccessDeniedScreen(context);
          }
        }

        // Check JWT token expiry asynchronously
        return FutureBuilder<bool>(
          future: _isTokenValid(),
          builder: (context, snapshot) {
            // While checking token, show loading indicator to prevent data flash
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            // If token is expired, redirect to login
            if (snapshot.hasData && snapshot.data == false) {
              // Schedule navigation after build completes
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _redirectToLogin(context);
              });
              return const Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFF185A9D)),
                      SizedBox(height: 16),
                      Text('Session expired. Redirecting to login...',
                        style: TextStyle(fontSize: 14, color: Color(0xFF64748B))),
                    ],
                  ),
                ),
              );
            }

            return child;
          },
        );
      },
    );
  }

  /// L1433: Notify admin when a user hits access restriction
  void _notifyAdminOfRestriction(AuthProvider auth) {
    try {
      ApiService().logAccessRestriction(
        userId: auth.userId ?? '',
        userName: auth.username ?? '',
        userRole: auth.role ?? '',
        pageKey: pageKey,
      );
    } catch (_) {
      // Non-blocking — don't fail the UI if notification fails
    }
  }

  /// Redirect user to login screen and clear session.
  void _redirectToLogin(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    auth.logout();
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  Widget _buildAccessDeniedScreen(BuildContext context) {
    void goToDashboard() {
      // Get the user's role to navigate to the correct dashboard
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final role = auth.role?.toLowerCase() ?? '';
      final dashboardRoute = role == 'client' ? '/client_dashboard' : '/admin_dashboard';

      // Use pushNamedAndRemoveUntil to clear stack and go to dashboard
      Navigator.of(context).pushNamedAndRemoveUntil(
        dashboardRoute,
        (route) => false,
      );
    }

    return Scaffold(
      body: GestureDetector(
        onTap: goToDashboard, // Tapping anywhere goes to dashboard
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF1F5F9), Color(0xFFE2E8F0)],
            ),
          ),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // Prevent tap from propagating through panel
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.lock_outline,
                        size: 48,
                        color: Color(0xFFEF4444),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Access Restricted',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'You do not have permission to access this page.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please contact your administrator to request access.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton.icon(
                      onPressed: goToDashboard,
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Go Back'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0F172A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
