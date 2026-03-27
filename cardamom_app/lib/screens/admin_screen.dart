import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/navigation_service.dart';
import '../services/liveness_detection_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import 'liveness_check_screen.dart';
import 'face_enroll_screen.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> with RouteAware {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _users = [];

  // Notification numbers state
  List<String> _notifPhones = [];
  bool _notifLoading = true;

  // Face enrollment state
  bool _hasFaceEnrolled = false;
  bool _faceEnrollLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _loadNotificationNumbers();
    _checkFaceEnrollment();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    _loadUsers();
    _loadNotificationNumbers();
  }

  Future<void> _loadNotificationNumbers() async {
    try {
      final resp = await _apiService.getNotificationNumbers();
      if (resp.data['success'] == true && resp.data['phones'] is List) {
        setState(() {
          _notifPhones = (resp.data['phones'] as List)
              .map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
          _notifLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading notification numbers: $e');
      setState(() => _notifLoading = false);
    }
  }

  Future<void> _saveNotificationNumbers(List<String> phones) async {
    try {
      await _apiService.updateNotificationNumbers(phones);
      setState(() => _notifPhones = phones);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notification numbers updated'), backgroundColor: Color(0xFF22C55E)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _checkFaceEnrollment() async {
    try {
      final resp = await _apiService.getUserFaceData();
      if (mounted) {
        setState(() {
          _hasFaceEnrolled = resp.data['faceData'] != null;
          _faceEnrollLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error checking face enrollment: $e');
      if (mounted) setState(() => _faceEnrollLoading = false);
    }
  }

  Future<void> _enrollMyFace() async {
    // Step 1: Liveness verification
    final livenessResult = await Navigator.push<LivenessResult>(
      context,
      MaterialPageRoute(builder: (context) => const LivenessCheckScreen()),
    );

    if (livenessResult == null || !mounted) return;

    if (!livenessResult.isLive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Liveness check failed: ${livenessResult.message}'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // Step 2: Face capture (modern enroll screen)
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => const FaceEnrollScreen(enrollLabel: 'My Face'),
      ),
    );

    if (result == null || !mounted) return;

    final rawLandmarks = result['landmarks'];
    if (rawLandmarks == null) return;

    // Sanitize: remove NaN/Infinity values
    final landmarks = Map<String, double>.from(rawLandmarks)
      ..removeWhere((_, v) => v.isNaN || v.isInfinite);
    if (landmarks.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Face capture failed. No valid landmarks extracted.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // Step 3: Store face data for current user
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final success = await auth.enrollFaceForCurrentUser(landmarks);

    if (!mounted) return;

    if (success) {
      setState(() => _hasFaceEnrolled = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Face enrolled successfully! You can now use face login.'),
          backgroundColor: Color(0xFF22C55E),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Face enrollment failed. Please try again.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _deleteMyFaceData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => _buildGlassDialog(
        title: 'Delete Face Data',
        content: const Text(
          'Delete your face data? You\'ll need to re-enroll to use face login.',
          style: TextStyle(color: Color(0xFF64748B), height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Delete', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await _apiService.deleteMyFaceData();
      if (!mounted) return;
      setState(() => _hasFaceEnrolled = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Face data deleted'), backgroundColor: Color(0xFF22C55E)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _deleteFaceForUser(Map<String, dynamic> user) async {
    final userId = user['id']?.toString();
    final userName = user['fullName']?.toString().isNotEmpty == true
        ? user['fullName']
        : user['username'] ?? 'User';
    if (userId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => _buildGlassDialog(
        title: 'Delete Face Data',
        content: Text(
          'Delete face data for $userName? They\'ll need to re-enroll to use face login.',
          style: const TextStyle(color: Color(0xFF64748B), height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Delete', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await _apiService.deleteUserFaceDataById(userId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Face data deleted for $userName'),
          backgroundColor: const Color(0xFF22C55E),
        ),
      );
      _loadUsers();
      _checkFaceEnrollment();
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('404')
          ? 'User face data not found'
          : 'Failed to delete face data';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _enrollFaceForUser(Map<String, dynamic> user) async {
    final userId = user['id']?.toString();
    final userName = user['fullName']?.toString().isNotEmpty == true
        ? user['fullName']
        : user['username'] ?? 'User';
    if (userId == null) return;

    // Step 1: Liveness verification
    final livenessResult = await Navigator.push<LivenessResult>(
      context,
      MaterialPageRoute(builder: (context) => const LivenessCheckScreen()),
    );

    if (livenessResult == null || !mounted) return;

    if (!livenessResult.isLive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Liveness check failed: ${livenessResult.message}'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // Step 2: Face capture (modern enroll screen)
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => FaceEnrollScreen(enrollLabel: userName),
      ),
    );

    if (result == null || !mounted) return;

    final rawLandmarks = result['landmarks'];
    if (rawLandmarks == null) return;

    final landmarks = Map<String, double>.from(rawLandmarks)
      ..removeWhere((_, v) => v.isNaN || v.isInfinite);
    if (landmarks.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Face capture failed. No valid landmarks.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // Step 3: Store face data for this specific user
    try {
      final resp = await _apiService.storeUserFaceDataById(userId, landmarks);
      if (!mounted) return;
      if (resp.data is Map && resp.data['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Face enrolled for $userName!'),
            backgroundColor: const Color(0xFF22C55E),
          ),
        );
        // Also refresh own enrollment status in case it was the current user
        _checkFaceEnrollment();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Enrollment failed: ${resp.data}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  String _formatNotifPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      return '+91 ${digits.substring(2)}';
    }
    if (digits.length == 10) {
      return '+91 $digits';
    }
    return '+$digits';
  }

  void _showAddNotifNumberDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Add Notification Number', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: InputDecoration(
            prefixText: '+91 ',
            hintText: '9876543210',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final digits = controller.text.trim().replaceAll(RegExp(r'\D'), '');
              if (digits.length != 10) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter a valid 10-digit number'), backgroundColor: Colors.orange),
                );
                return;
              }
              final full = '91$digits';
              if (_notifPhones.contains(full)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Number already exists'), backgroundColor: Colors.orange),
                );
                return;
              }
              Navigator.pop(ctx);
              final updated = [..._notifPhones, full];
              _saveNotificationNumbers(updated);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF22C55E),
              foregroundColor: Colors.white,
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getUsers();
      setState(() {
        _users = response.data['users'] ?? [];
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading users: $e');
      setState(() => _isLoading = false);
    }
  }

  void _showUserModal([Map<String, dynamic>? user]) {
    final isEdit = user != null;
    final usernameController = TextEditingController(text: user?['username'] ?? '');
    final nameController = TextEditingController(text: user?['fullName'] ?? '');
    final emailController = TextEditingController(text: user?['email'] ?? '');
    String selectedRole = user?['role'] ?? 'employee';
    // Normalize 'user' to 'employee' for backward compatibility
    if (selectedRole == 'user') selectedRole = 'employee';
    final passwordController = TextEditingController();
    
    // Initialize page access with defaults or existing values
    Map<String, bool> pageAccess = {};
    const defaultAdminAccess = {
      'new_order': true, 'view_orders': true, 'sales_summary': true,
      'grade_allocator': true, 'daily_cart': true, 'add_to_cart': true,
      'stock_tools': true, 'order_requests': true, 'pending_approvals': true,
      'task_management': true, 'attendance': true, 'expenses': true,
      'gate_passes': true, 'admin': true, 'dropdown_manager': true,
      'edit_orders': true, 'delete_orders': true,
      'packed_boxes': true, 'ledger': true, 'whatsapp_logs': true,
    };
    const defaultUserAccess = {
      'new_order': true, 'view_orders': true, 'sales_summary': false,
      'grade_allocator': false, 'daily_cart': true, 'add_to_cart': true,
      'stock_tools': false, 'order_requests': false, 'pending_approvals': false,
      'task_management': true, 'attendance': true, 'expenses': true,
      'gate_passes': true, 'admin': false, 'dropdown_manager': false,
      'edit_orders': false, 'delete_orders': false,
      'packed_boxes': false, 'ledger': false, 'whatsapp_logs': false,
    };
    
    if (user?['pageAccess'] != null) {
      pageAccess = Map<String, bool>.from(
        ((user!['pageAccess'] as Map?) ?? {}).map((k, v) => MapEntry(k.toString(), v == true))
      );
    } else {
      pageAccess = Map<String, bool>.from(
        (selectedRole == 'admin' || selectedRole == 'superadmin' || selectedRole == 'ops') ? defaultAdminAccess : defaultUserAccess
      );
    }

    const pageLabels = {
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
      'packed_boxes': 'Packed Box',
      'ledger': 'Ledger',
      'whatsapp_logs': 'WA Send Log',
    };

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final showPageAccess = selectedRole == 'superadmin' || selectedRole == 'admin' || selectedRole == 'ops' || selectedRole == 'employee' || selectedRole == 'user';
          
          return _buildGlassDialog(
            title: isEdit ? 'Edit User' : 'Add User',
            content: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(dialogContext).size.height * 0.65),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(controller: nameController, decoration: _inputDecoration('Full Name')),
                    const SizedBox(height: 16),
                    TextField(controller: usernameController, decoration: _inputDecoration('Username *')),
                    const SizedBox(height: 16),
                    TextField(controller: emailController, decoration: _inputDecoration('Email')),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: selectedRole,
                      decoration: _inputDecoration('Role *'),
                      borderRadius: BorderRadius.circular(20),
                      items: ['employee', 'admin', 'superadmin', 'ops', 'client'].map((r) => DropdownMenuItem(
                        value: r,
                        child: Text(r == 'employee' ? 'Employee' : r == 'superadmin' ? 'Super Admin' : r[0].toUpperCase() + r.substring(1)),
                      )).toList(),
                      onChanged: (val) {
                        setDialogState(() {
                          selectedRole = val ?? 'employee';
                          // Reset page access to defaults when role changes
                          if (selectedRole == 'superadmin' || selectedRole == 'admin' || selectedRole == 'ops') {
                            pageAccess = Map<String, bool>.from(defaultAdminAccess);
                          } else if (selectedRole == 'employee' || selectedRole == 'user') {
                            pageAccess = Map<String, bool>.from(defaultUserAccess);
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: passwordController,
                      decoration: _inputDecoration(isEdit ? 'Password (leave empty to keep current)' : 'Password *'),
                      obscureText: true,
                    ),
                    
                    // Page Access Section - only for admin/user roles
                    if (showPageAccess) ...[
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.security, size: 18, color: Color(0xFF5D6E7E)),
                                const SizedBox(width: 8),
                                const Text('Page Access', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                                const Spacer(),
                                TextButton(
                                  onPressed: () => setDialogState(() {
                                    for (var key in pageAccess.keys) {
                                      pageAccess[key] = true;
                                    }
                                  }),
                                  child: const Text('All', style: TextStyle(fontSize: 11)),
                                ),
                                TextButton(
                                  onPressed: () => setDialogState(() {
                                    for (var key in pageAccess.keys) {
                                      pageAccess[key] = false;
                                    }
                                  }),
                                  child: const Text('None', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: pageLabels.entries.map((entry) {
                                final isEnabled = pageAccess[entry.key] ?? false;
                                return GestureDetector(
                                  onTap: () => setDialogState(() {
                                    pageAccess[entry.key] = !isEnabled;
                                  }),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: isEnabled ? const Color(0xFF22C55E).withOpacity(0.15) : const Color(0xFFEF4444).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: isEnabled ? const Color(0xFF22C55E).withOpacity(0.4) : const Color(0xFFEF4444).withOpacity(0.3),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isEnabled ? Icons.check_circle : Icons.cancel,
                                          size: 14,
                                          color: isEnabled ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          entry.value,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                            color: isEnabled ? const Color(0xFF166534) : const Color(0xFF991B1B),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async {
                  if (usernameController.text.isEmpty) return;
                  // Validate email format if provided
                  final emailText = emailController.text.trim();
                  if (emailText.isNotEmpty) {
                    final emailRegex = RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
                    if (!emailRegex.hasMatch(emailText)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a valid email address'), backgroundColor: Colors.redAccent),
                      );
                      return;
                    }
                  }
                  final data = <String, dynamic>{
                    'username': usernameController.text,
                    'email': emailText,
                    'role': selectedRole,
                    'fullName': nameController.text,
                  };
                  if (passwordController.text.isNotEmpty) {
                    data['password'] = passwordController.text;
                  }
                  // Include pageAccess for all roles that have configurable access
                  if (selectedRole != 'client') {
                    data['pageAccess'] = pageAccess;
                  }

                  if (!isEdit && passwordController.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password is required for new users')));
                    return;
                  }
                  Navigator.pop(ctx);
                  
                  // Show loading popup
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (loadingCtx) => AlertDialog(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      contentPadding: const EdgeInsets.all(24),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(color: Color(0xFF5D6E7E)),
                          const SizedBox(height: 16),
                          Text(
                            isEdit
                              ? ((selectedRole == 'superadmin' || selectedRole == 'admin' || selectedRole == 'ops')
                                  ? 'Updating Admin Access...'
                                  : 'Updating User Access...')
                              : 'Creating User...',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  );
                  
                  try {
                    if (isEdit) {
                      await _apiService.updateUser(user['id'].toString(), data);
                    } else {
                      await _apiService.addUser(data);
                    }
                    if (!mounted) return;
                    Navigator.of(context, rootNavigator: true).pop(); // Close loading popup
                    _loadUsers();
                  } catch (e) {
                    if (!mounted) return;
                    try { Navigator.of(context, rootNavigator: true).pop(); } catch (_) {}
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                child: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteUser(dynamic id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => _buildGlassDialog(
        title: 'Delete User',
        content: const Text('Are you sure you want to remove this user? This action cannot be undone.', style: TextStyle(color: Color(0xFF64748B), height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No, Keep')),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('Yes, Delete', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      // Show loading popup
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (loadingCtx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          contentPadding: const EdgeInsets.all(24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFFEF4444)),
              const SizedBox(height: 16),
              const Text('Deleting User...', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );
      
      try {
        await _apiService.deleteUser(id.toString());
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pop(); // Close loading popup
        _loadUsers();
      } catch (e) {
        if (!mounted) return;
        try { Navigator.of(context, rootNavigator: true).pop(); } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      disableInternalScrolling: true,
      title: '⚙️ Admin Center',
      subtitle: 'Manage system users and access levels.',
      topActions: [
        LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = MediaQuery.of(context).size.width < 600;
            if (isMobile) {
              return SizedBox.shrink(); // Mobile actions handled by AppShell's popup menu logic which needs flat list
            }
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildNavBtn(label: 'Dashboard', onPressed: () => Navigator.pushReplacementNamed(context, '/admin_dashboard'), color: const Color(0xFF5D6E7E)),
                const SizedBox(width: 8),
                _buildNavBtn(label: 'Add User', onPressed: () => _showUserModal(), color: const Color(0xFF22C55E)),
              ],
            );
          }
        ),
        // Pass buttons directly for Mobile Popup Menu (AppShell picks these up)
        _buildNavBtn(label: 'Dashboard', onPressed: () => Navigator.pushReplacementNamed(context, '/admin_dashboard'), color: const Color(0xFF5D6E7E)),
        _buildNavBtn(label: 'Add User', onPressed: () => _showUserModal(), color: const Color(0xFF22C55E)),
      ],
      content: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(vertical: 20, horizontal: isMobile ? 12 : 16),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          decoration: AppTheme.glassDecoration.copyWith(
                            borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                          ),
                          padding: EdgeInsets.all(isMobile ? 14 : 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isMobile ? 'User Management' : '👥 User Management',
                                style: TextStyle(fontSize: isMobile ? 18 : 22, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A), letterSpacing: -0.5),
                              ),
                              SizedBox(height: isMobile ? 20 : 32),
                              _isLoading
                                  ? const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
                                  : ListView.builder(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      itemCount: _users.length,
                                      itemBuilder: (context, idx) => _buildUserCard(_users[idx], isMobile),
                                    ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Notification Numbers Section
                    ClipRRect(
                      borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          decoration: AppTheme.glassDecoration.copyWith(
                            borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                          ),
                          padding: EdgeInsets.all(isMobile ? 14 : 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      isMobile ? 'Notification Numbers' : '📱 Order Notification Numbers',
                                      style: TextStyle(fontSize: isMobile ? 18 : 22, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A), letterSpacing: -0.5),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: _showAddNotifNumberDialog,
                                    icon: const Icon(Icons.add_circle, color: Color(0xFF22C55E)),
                                    tooltip: 'Add number',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'These numbers receive all new order confirmations alongside the client.',
                                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                              ),
                              const SizedBox(height: 16),
                              _notifLoading
                                  ? const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
                                  : _notifPhones.isEmpty
                                      ? Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(20),
                                            child: Column(
                                              children: [
                                                Icon(Icons.phone_disabled, size: 32, color: Colors.grey[400]),
                                                const SizedBox(height: 8),
                                                Text('No notification numbers set', style: TextStyle(color: Colors.grey[500])),
                                              ],
                                            ),
                                          ),
                                        )
                                      : Column(
                                          children: _notifPhones.map((phone) => Container(
                                            margin: const EdgeInsets.only(bottom: 8),
                                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(alpha: 0.85),
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(color: const Color(0xFFE2E8F0)),
                                            ),
                                            child: Row(
                                              children: [
                                                const Icon(Icons.phone, size: 18, color: Color(0xFF25D366)),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Text(
                                                    _formatNotifPhone(phone),
                                                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                                                  ),
                                                ),
                                                IconButton(
                                                  icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFEF4444)),
                                                  tooltip: 'Remove',
                                                  onPressed: () {
                                                    final updated = _notifPhones.where((p) => p != phone).toList();
                                                    _saveNotificationNumbers(updated);
                                                  },
                                                ),
                                              ],
                                            ),
                                          )).toList(),
                                        ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Face Login Enrollment Section
                    ClipRRect(
                      borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          decoration: AppTheme.glassDecoration.copyWith(
                            borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                          ),
                          padding: EdgeInsets.all(isMobile ? 14 : 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isMobile ? 'Face Login' : '🔐 Face Login',
                                style: TextStyle(fontSize: isMobile ? 18 : 22, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A), letterSpacing: -0.5),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Enroll your face to login without typing credentials after fresh install.',
                                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                              ),
                              const SizedBox(height: 16),
                              _faceEnrollLoading
                                  ? const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
                                  : Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.85),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: const Color(0xFFE2E8F0)),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 48,
                                            height: 48,
                                            decoration: BoxDecoration(
                                              color: _hasFaceEnrolled
                                                  ? const Color(0xFF22C55E).withValues(alpha: 0.1)
                                                  : Colors.grey.withValues(alpha: 0.1),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              _hasFaceEnrolled ? Icons.face_rounded : Icons.face_outlined,
                                              color: _hasFaceEnrolled ? const Color(0xFF22C55E) : Colors.grey,
                                              size: 28,
                                            ),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  _hasFaceEnrolled ? 'Face Enrolled' : 'Not Enrolled',
                                                  style: GoogleFonts.manrope(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w700,
                                                    color: const Color(0xFF0F172A),
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  _hasFaceEnrolled
                                                      ? 'You can use face recognition to login'
                                                      : 'Enroll to enable face login',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: _hasFaceEnrolled ? const Color(0xFF22C55E) : Colors.grey[500],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (_hasFaceEnrolled)
                                            GestureDetector(
                                              onTap: _deleteMyFaceData,
                                              child: Container(
                                                padding: const EdgeInsets.all(10),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                                                  borderRadius: BorderRadius.circular(12),
                                                ),
                                                child: const Icon(
                                                  Icons.delete_outline,
                                                  size: 18,
                                                  color: Color(0xFFEF4444),
                                                ),
                                              ),
                                            ),
                                          if (_hasFaceEnrolled) const SizedBox(width: 8),
                                          GestureDetector(
                                            onTap: _enrollMyFace,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                              decoration: BoxDecoration(
                                                color: _hasFaceEnrolled
                                                    ? const Color(0xFF185A9D).withValues(alpha: 0.1)
                                                    : const Color(0xFF185A9D),
                                                borderRadius: BorderRadius.circular(12),
                                              ),
                                              child: Text(
                                                _hasFaceEnrolled ? 'Re-enroll' : 'Enroll Face',
                                                style: GoogleFonts.manrope(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w700,
                                                  color: _hasFaceEnrolled ? const Color(0xFF185A9D) : Colors.white,
                                                ),
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
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildNavBtn({required String label, required VoidCallback onPressed, required Color color, bool isMobile = false}) {
    return Container(
      height: isMobile ? 36 : 40,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: color,
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: Text(label, style: TextStyle(fontSize: isMobile ? 11 : 12, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildGlassDialog({required String title, required Widget content, required List<Widget> actions}) {
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;
          return Container(
            width: isMobile ? double.infinity : 450,
            margin: EdgeInsets.all(isMobile ? 16 : 24),
            decoration: AppTheme.glassDecoration.copyWith(
              borderRadius: BorderRadius.circular(20),
              color: Colors.white.withOpacity(0.95),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Material(
                    color: Colors.transparent,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                        const SizedBox(height: 12),
                        content,
                        const SizedBox(height: 16),
                        Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
      fillColor: Colors.white.withOpacity(0.8),
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    );
  }

  Widget _buildUserCard(dynamic user, bool isMobile) {
    final role = user['role']?.toString() ?? 'user';
    final username = user['username'] ?? '';
    final fullName = user['fullName'] ?? '';
    final displayName = fullName.isNotEmpty ? '$fullName ($username)' : username;
    final email = user['email'] ?? 'No email';
    final id = user['id'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: ListTile(
        contentPadding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: 4),
        leading: CircleAvatar(
          radius: isMobile ? 18 : 22,
          backgroundColor: AppTheme.primary.withOpacity(0.1),
          child: Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: isMobile ? 14 : 16)),
        ),
        title: Text(displayName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: isMobile ? 14 : 16)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(email, style: TextStyle(fontSize: isMobile ? 11 : 12, color: const Color(0xFF64748B))),
            const SizedBox(height: 4),
            _buildRoleBadge(role, isMobile),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<String>(
              icon: Icon(
                Icons.face_retouching_natural,
                size: 20,
                color: user['faceData'] != null ? const Color(0xFF22C55E) : const Color(0xFF94A3B8),
              ),
              tooltip: 'Face options',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onSelected: (value) {
                if (value == 'enroll') {
                  _enrollFaceForUser(user);
                } else if (value == 'delete') {
                  _deleteFaceForUser(user);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'enroll',
                  child: Row(
                    children: [
                      Icon(Icons.face_retouching_natural, size: 18, color: const Color(0xFF185A9D)),
                      const SizedBox(width: 8),
                      Text(user['faceData'] != null ? 'Re-enroll Face' : 'Enroll Face'),
                    ],
                  ),
                ),
                if (user['faceData'] != null)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, size: 18, color: Color(0xFFEF4444)),
                        SizedBox(width: 8),
                        Text('Delete Face', style: TextStyle(color: Color(0xFFEF4444))),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20, color: Color(0xFF5D6E7E)),
              onPressed: () => _showUserModal(user),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFEF4444)),
              onPressed: () => _deleteUser(id),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleBadge(String role, bool isMobile) {
    Color color;
    String displayRole = role;
    switch (role.toLowerCase()) {
      case 'superadmin':
        color = const Color(0xFF7C3AED); // Purple for super admin
        displayRole = 'SUPER ADMIN';
        break;
      case 'admin':
        color = const Color(0xFFDC2626);
        break;
      case 'ops':
        color = const Color(0xFFEA580C); // Orange for ops
        break;
      case 'client':
        color = const Color(0xFF4A5568);
        break;
      default:
        color = const Color(0xFF64748B);
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 10, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        displayRole.toUpperCase(),
        style: TextStyle(color: color, fontSize: isMobile ? 9 : 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
      ),
    );
  }
}
