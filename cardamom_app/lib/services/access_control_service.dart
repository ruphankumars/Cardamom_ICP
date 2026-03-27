import 'dart:convert';
import 'package:flutter/material.dart';

/// Service to manage page access control based on user permissions
class AccessControlService {
  /// Map of page keys to their display names
  static const Map<String, String> pageLabels = {
    'new_order': 'New Order',
    'view_orders': 'View Orders',
    'sales_summary': 'Sales Summary',
    'grade_allocator': 'Grade Allocator',
    'daily_cart': 'Daily Cart',
    'add_to_cart': 'Add to Cart',
    'stock_tools': 'Stock Tools',
    'order_requests': 'Order Requests',
    'pending_approvals': 'Pending Approvals',
    'task_management': 'Task Management',
    'attendance': 'Attendance',
    'expenses': 'Expenses',
    'gate_passes': 'Gate Passes',
    'admin': 'Admin Panel',
    'dropdown_manager': 'Dropdown Manager',
    'edit_orders': 'Edit Orders',
    'delete_orders': 'Delete Orders',
    'offer_price': 'Offer Price',
    'outstanding': 'Outstanding Payments',
    'dispatch_documents': 'Dispatch Documents',
    'transport_list': 'Transport Documents',
    'transport_send': 'Transport Send',
    'transport_history': 'Transport History',
    'ledger': 'Ledger',
    'ai_overlay': 'AI Assistant',
    'packed_boxes': 'Packed Box',
    'whatsapp_logs': 'WA Send Log',
  };

  /// Map of route names to page keys
  static const Map<String, String> routeToPageKey = {
    '/new_order': 'new_order',
    '/view_orders': 'view_orders',
    '/sales_summary': 'sales_summary',
    '/grade_allocator': 'grade_allocator',
    '/daily_cart': 'daily_cart',
    '/add_to_cart': 'add_to_cart',
    '/stock_tools': 'stock_tools',
    '/order_requests': 'order_requests',
    '/pending_approvals': 'pending_approvals',
    '/task_management': 'task_management',
    '/worker_tasks': 'task_management',
    '/attendance': 'attendance',
    '/attendance/calendar': 'attendance',
    '/expenses': 'expenses',
    '/gate_passes': 'gate_passes',
    '/admin': 'admin',
    '/dropdown_manager': 'dropdown_manager',
    '/offer_price': 'offer_price',
    '/dropdown_management': 'dropdown_manager',
    '/outstanding': 'outstanding',
    '/dispatch_documents': 'dispatch_documents',
    '/transport_list': 'dispatch_documents',
    '/transport_send': 'dispatch_documents',
    '/transport_history': 'dispatch_documents',
    '/reports': 'sales_summary',
    '/report_filter': 'sales_summary',
    '/face_attendance': 'attendance',
    '/face_enroll': 'attendance',
    '/face_management': 'attendance',
    '/ledger': 'ledger',
    '/ai_overlay': 'ai_overlay',
    '/packed_boxes': 'packed_boxes',
    '/whatsapp_logs': 'whatsapp_logs',
  };

  /// Check if the user role is an admin role (superadmin, admin or ops)
  static bool _isAdminRole(String? role) {
    final normalizedRole = role?.toLowerCase() ?? '';
    return normalizedRole == 'superadmin' || normalizedRole == 'admin' || normalizedRole == 'ops';
  }

  /// Check if the user can access a specific page
  /// Admins (admin or ops roles) always have full access regardless of pageAccess map.
  static bool canAccess(Map<String, dynamic>? pageAccess, String pageKey, {String? userRole}) {
    if (_isAdminRole(userRole)) return true;
    if (pageAccess == null) return false;
    return pageAccess[pageKey] == true;
  }

  /// Check if the user can access a route
  static bool canAccessRoute(Map<String, dynamic>? pageAccess, String routeName, {String? userRole}) {
    if (_isAdminRole(userRole)) return true;
    final pageKey = routeToPageKey[routeName];
    if (pageKey == null) return false;
    return canAccess(pageAccess, pageKey, userRole: userRole);
  }

  /// Check if a JWT token is expired by decoding the payload.
  /// Returns true if token is null, malformed, or expired.
  static bool isTokenExpired(String? token) {
    if (token == null) return true;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))
      );
      final exp = payload['exp'] as int?;
      if (exp == null) return true;
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000).isBefore(DateTime.now());
    } catch (_) {
      return true;
    }
  }

  /// Show the "Contact Admin for access" dialog
  static void showNoAccessDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.lock_outline, color: Colors.red.shade400, size: 28),
            const SizedBox(width: 12),
            const Text('Access Restricted', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: const Text(
          'You do not have permission to access this page.\n\nPlease contact your administrator to request access.',
          style: TextStyle(fontSize: 15, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Navigate to a route with access check
  static void navigateWithAccessCheck(
    BuildContext context,
    String routeName,
    Map<String, dynamic>? pageAccess, {
    Object? arguments,
    bool replacement = false,
    String? userRole,
  }) {
    if (!canAccessRoute(pageAccess, routeName, userRole: userRole)) {
      showNoAccessDialog(context);
      return;
    }

    if (replacement) {
      Navigator.pushReplacementNamed(context, routeName, arguments: arguments);
    } else {
      Navigator.pushNamed(context, routeName, arguments: arguments);
    }
  }
}
