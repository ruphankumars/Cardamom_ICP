import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/api_service.dart';

class WebAdminScreen extends StatefulWidget {
  const WebAdminScreen({super.key});

  @override
  State<WebAdminScreen> createState() => _WebAdminScreenState();
}

class _WebAdminScreenState extends State<WebAdminScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _users = [];
  Map<String, dynamic>? _selectedUser;
  String _searchQuery = '';
  String _roleFilter = '';

  // Form controllers
  final _usernameController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String _selectedRole = 'employee';
  bool _isEditing = false;
  bool _isSaving = false;

  Map<String, bool> _pageAccess = {};

  static const Map<String, String> _pageLabels = {
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
  };

  static const Map<String, bool> _defaultAdminAccess = {
    'new_order': true, 'view_orders': true, 'sales_summary': true,
    'grade_allocator': true, 'daily_cart': true, 'add_to_cart': true,
    'stock_tools': true, 'order_requests': true, 'pending_approvals': true,
    'task_management': true, 'attendance': true, 'expenses': true,
    'gate_passes': true, 'admin': true, 'dropdown_manager': true,
    'edit_orders': true, 'delete_orders': true,
  };

  static const Map<String, bool> _defaultUserAccess = {
    'new_order': true, 'view_orders': true, 'sales_summary': false,
    'grade_allocator': false, 'daily_cart': true, 'add_to_cart': true,
    'stock_tools': false, 'order_requests': false, 'pending_approvals': false,
    'task_management': true, 'attendance': true, 'expenses': true,
    'gate_passes': true, 'admin': false, 'dropdown_manager': false,
    'edit_orders': false, 'delete_orders': false,
  };

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
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

  List<dynamic> get _filteredUsers {
    return _users.where((u) {
      final name = (u['fullName'] ?? '').toString().toLowerCase();
      final username = (u['username'] ?? '').toString().toLowerCase();
      final email = (u['email'] ?? '').toString().toLowerCase();
      final role = (u['role'] ?? '').toString().toLowerCase();
      final query = _searchQuery.toLowerCase();
      final matchesSearch = query.isEmpty ||
          name.contains(query) ||
          username.contains(query) ||
          email.contains(query);
      final matchesRole = _roleFilter.isEmpty || role == _roleFilter;
      return matchesSearch && matchesRole;
    }).toList();
  }

  void _selectUser(Map<String, dynamic> user) {
    setState(() {
      _selectedUser = user;
      _isEditing = true;
      _usernameController.text = user['username'] ?? '';
      _nameController.text = user['fullName'] ?? '';
      _emailController.text = user['email'] ?? '';
      _passwordController.clear();
      _selectedRole = user['role'] ?? 'employee';
      if (_selectedRole == 'user') _selectedRole = 'employee';
      if (user['pageAccess'] != null) {
        _pageAccess = Map<String, bool>.from(
          ((user['pageAccess'] as Map?) ?? {}).map(
            (k, v) => MapEntry(k.toString(), v == true),
          ),
        );
      } else {
        _pageAccess = Map<String, bool>.from(
          (_selectedRole == 'admin' || _selectedRole == 'superadmin' || _selectedRole == 'ops')
              ? _defaultAdminAccess
              : _defaultUserAccess,
        );
      }
    });
  }

  void _newUser() {
    setState(() {
      _selectedUser = null;
      _isEditing = true;
      _usernameController.clear();
      _nameController.clear();
      _emailController.clear();
      _passwordController.clear();
      _selectedRole = 'employee';
      _pageAccess = Map<String, bool>.from(_defaultUserAccess);
    });
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _selectedUser = null;
    });
  }

  Future<void> _saveUser() async {
    if (_usernameController.text.isEmpty) {
      _showSnackBar('Username is required', isError: true);
      return;
    }
    if (_selectedUser == null && _passwordController.text.isEmpty) {
      _showSnackBar('Password is required for new users', isError: true);
      return;
    }

    setState(() => _isSaving = true);
    try {
      final data = <String, dynamic>{
        'username': _usernameController.text,
        'email': _emailController.text,
        'role': _selectedRole,
        'fullName': _nameController.text,
      };
      if (_passwordController.text.isNotEmpty) {
        data['password'] = _passwordController.text;
      }
      if (_selectedRole != 'client') {
        data['pageAccess'] = _pageAccess;
      }

      if (_selectedUser != null) {
        await _apiService.updateUser(_selectedUser!['id'].toString(), data);
        _showSnackBar('User updated successfully');
      } else {
        await _apiService.addUser(data);
        _showSnackBar('User created successfully');
      }
      _cancelEdit();
      await _loadUsers();
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete User'),
        content: Text('Are you sure you want to delete "${user['fullName'] ?? user['username']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444), foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _apiService.deleteUser(user['id'].toString());
      _showSnackBar('User deleted');
      if (_selectedUser?['id'] == user['id']) _cancelEdit();
      await _loadUsers();
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF5D6E7E)))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth > 900) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 3, child: _buildUserTable()),
                            if (_isEditing)
                              Expanded(flex: 2, child: _buildEditPanel()),
                          ],
                        );
                      }
                      return _isEditing ? _buildEditPanel() : _buildUserTable();
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
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
              Text('User Management', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
              const SizedBox(height: 4),
              Text('${_users.length} users registered', style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
            ],
          ),
          const Spacer(),
          _buildFilterDropdown(),
          const SizedBox(width: 12),
          SizedBox(
            width: 260,
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search users...',
                hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                filled: true,
                fillColor: const Color(0xFFF3F4F6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _newUser,
            icon: const Icon(Icons.add, size: 18),
            label: Text('Add User', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5D6E7E),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _roleFilter,
          icon: const Icon(Icons.expand_more, size: 18),
          style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
          items: const [
            DropdownMenuItem(value: '', child: Text('All Roles')),
            DropdownMenuItem(value: 'superadmin', child: Text('Super Admin')),
            DropdownMenuItem(value: 'admin', child: Text('Admin')),
            DropdownMenuItem(value: 'ops', child: Text('Ops')),
            DropdownMenuItem(value: 'employee', child: Text('Employee')),
            DropdownMenuItem(value: 'client', child: Text('Client')),
          ],
          onChanged: (v) => setState(() => _roleFilter = v ?? ''),
        ),
      ),
    );
  }

  Widget _buildUserTable() {
    final users = _filteredUsers;
    return Container(
      margin: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      child: Column(
        children: [
          // Table header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F5F9),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            ),
            child: Row(
              children: [
                _tableHeader('Name', flex: 3),
                _tableHeader('Username', flex: 2),
                _tableHeader('Email', flex: 3),
                _tableHeader('Role', flex: 2),
                _tableHeader('Actions', flex: 2),
              ],
            ),
          ),
          Expanded(
            child: users.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_outline, size: 48, color: Colors.grey[300]),
                        const SizedBox(height: 12),
                        Text('No users found', style: GoogleFonts.inter(color: const Color(0xFF9CA3AF))),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: users.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                    itemBuilder: (context, index) => _buildUserRow(users[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tableHeader(String text, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Text(text, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280))),
    );
  }

  Widget _buildUserRow(Map<String, dynamic> user) {
    final isSelected = _selectedUser?['id'] == user['id'];
    final role = user['role']?.toString() ?? 'employee';
    final fullName = user['fullName'] ?? '';
    final username = user['username'] ?? '';
    final email = user['email'] ?? '';

    return InkWell(
      onTap: () => _selectUser(user),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        color: isSelected ? const Color(0xFF5D6E7E).withOpacity(0.06) : null,
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: _getRoleColor(role).withOpacity(0.12),
                    child: Text(
                      (fullName.isNotEmpty ? fullName : username).substring(0, 1).toUpperCase(),
                      style: TextStyle(color: _getRoleColor(role), fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      fullName.isNotEmpty ? fullName : username,
                      style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF111827)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(username, style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
            ),
            Expanded(
              flex: 3,
              child: Text(email.isNotEmpty ? email : '--', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
            ),
            Expanded(
              flex: 2,
              child: _buildRoleBadge(role),
            ),
            Expanded(
              flex: 2,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    color: const Color(0xFF5D6E7E),
                    tooltip: 'Edit',
                    onPressed: () => _selectUser(user),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    color: const Color(0xFFEF4444),
                    tooltip: 'Delete',
                    onPressed: () => _deleteUser(user),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleBadge(String role) {
    final color = _getRoleColor(role);
    String display = role;
    if (role == 'superadmin') display = 'Super Admin';
    if (role == 'employee') display = 'Employee';

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          display.toUpperCase(),
          style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.5),
        ),
      ),
    );
  }

  Color _getRoleColor(String role) {
    switch (role.toLowerCase()) {
      case 'superadmin': return const Color(0xFF7C3AED);
      case 'admin': return const Color(0xFFDC2626);
      case 'ops': return const Color(0xFFEA580C);
      case 'client': return const Color(0xFF4A5568);
      default: return const Color(0xFF5D6E7E);
    }
  }

  Widget _buildEditPanel() {
    final isNew = _selectedUser == null;
    final showPageAccess = _selectedRole != 'client';

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 24, 24, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Panel header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F5F9),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Text(
                  isNew ? 'New User' : 'Edit User',
                  style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700, color: const Color(0xFF111827)),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: _cancelEdit,
                  color: const Color(0xFF6B7280),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildFormField('Full Name', _nameController, 'Enter full name'),
                  const SizedBox(height: 16),
                  _buildFormField('Username *', _usernameController, 'Enter username'),
                  const SizedBox(height: 16),
                  _buildFormField('Email', _emailController, 'Enter email'),
                  const SizedBox(height: 16),
                  Text('Role *', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF374151))),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFD1D5DB)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedRole,
                        isExpanded: true,
                        style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF111827)),
                        items: ['employee', 'admin', 'superadmin', 'ops', 'client'].map((r) {
                          String label = r;
                          if (r == 'employee') label = 'Employee';
                          if (r == 'superadmin') label = 'Super Admin';
                          if (r == 'admin') label = 'Admin';
                          if (r == 'ops') label = 'Ops';
                          if (r == 'client') label = 'Client';
                          return DropdownMenuItem(value: r, child: Text(label));
                        }).toList(),
                        onChanged: (val) {
                          setState(() {
                            _selectedRole = val ?? 'employee';
                            if (_selectedRole == 'superadmin' || _selectedRole == 'admin' || _selectedRole == 'ops') {
                              _pageAccess = Map<String, bool>.from(_defaultAdminAccess);
                            } else {
                              _pageAccess = Map<String, bool>.from(_defaultUserAccess);
                            }
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildFormField(
                    isNew ? 'Password *' : 'Password (leave empty to keep)',
                    _passwordController,
                    'Enter password',
                    obscure: true,
                  ),
                  if (showPageAccess) ...[
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        const Icon(Icons.security, size: 16, color: Color(0xFF5D6E7E)),
                        const SizedBox(width: 8),
                        Text('Page Access', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: const Color(0xFF374151))),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setState(() { for (var k in _pageAccess.keys) _pageAccess[k] = true; }),
                          child: Text('All', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600)),
                        ),
                        TextButton(
                          onPressed: () => setState(() { for (var k in _pageAccess.keys) _pageAccess[k] = false; }),
                          child: Text('None', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _pageLabels.entries.map((entry) {
                        final enabled = _pageAccess[entry.key] ?? false;
                        return InkWell(
                          onTap: () => setState(() => _pageAccess[entry.key] = !enabled),
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: enabled ? const Color(0xFF22C55E).withOpacity(0.1) : const Color(0xFFEF4444).withOpacity(0.08),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: enabled ? const Color(0xFF22C55E).withOpacity(0.3) : const Color(0xFFEF4444).withOpacity(0.2),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  enabled ? Icons.check_circle : Icons.cancel,
                                  size: 13,
                                  color: enabled ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  entry.value,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: enabled ? const Color(0xFF166534) : const Color(0xFF991B1B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _saveUser,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5D6E7E),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                      child: _isSaving
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(isNew ? 'Create User' : 'Save Changes', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormField(String label, TextEditingController controller, String hint, {bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF374151))),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: GoogleFonts.inter(fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
            filled: true,
            fillColor: const Color(0xFFF9FAFB),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF5D6E7E), width: 2)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
      ],
    );
  }
}
