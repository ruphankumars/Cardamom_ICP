import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';
import '../../models/task.dart';

/// Web-optimized Task Management screen for admins.
/// Provides a data table of tasks with create/edit functionality.
class WebTaskManagement extends StatefulWidget {
  const WebTaskManagement({super.key});

  @override
  State<WebTaskManagement> createState() => _WebTaskManagementState();
}

class _WebTaskManagementState extends State<WebTaskManagement> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _headerBg = Color(0xFFF1F5F9);
  static const _cardRadius = 12.0;

  final ApiService _apiService = ApiService();
  List<Task> _tasks = [];
  Map<String, dynamic> _stats = {};
  List<dynamic> _availableUsers = [];
  bool _isLoading = true;
  String? _error;
  String _filterStatus = 'all';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchData();
    _fetchUsers();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final tasksRes = await _apiService.getTasks();
      final statsRes = await _apiService.getTaskStats();
      final tasksData = tasksRes.data;
      final tasksList = (tasksData is Map && tasksData['data'] is List)
          ? tasksData['data'] as List
          : (tasksData is List ? tasksData : []);
      if (mounted) {
        setState(() {
          _tasks = tasksList.map((t) => Task.fromJson(t)).toList();
          _stats = statsRes.data is Map<String, dynamic>
              ? statsRes.data as Map<String, dynamic>
              : {};
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchUsers() async {
    try {
      final res = await _apiService.getUsers();
      if (mounted && res.data is Map) {
        final list = (res.data as Map)['users'];
        if (list is List) {
          final filtered =
              list.where((u) => u['role'] != 'client' && u['role'] != 'Client').toList();
          setState(() => _availableUsers = filtered);
        }
      }
    } catch (_) {}
  }

  List<Task> get _filteredTasks {
    List<Task> result = _tasks;
    if (_filterStatus == 'urgent') {
      result = result.where((t) => t.isUrgent).toList();
    } else if (_filterStatus == 'pending') {
      result = result.where((t) => t.status == TaskStatus.pending).toList();
    } else if (_filterStatus == 'ongoing') {
      result = result.where((t) => t.status == TaskStatus.ongoing).toList();
    } else if (_filterStatus == 'completed') {
      result = result.where((t) => t.status == TaskStatus.completed).toList();
    }
    final query = _searchCtrl.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      result = result
          .where((t) =>
              t.title.toLowerCase().contains(query) ||
              t.assigneeName.toLowerCase().contains(query))
          .toList();
    }
    return result;
  }

  Future<void> _deleteTask(Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Task', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Delete "${task.title}"?', style: GoogleFonts.inter()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await _apiService.deleteTask(task.id);
        _fetchData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  void _showTaskDialog({Task? existing}) {
    final isEdit = existing != null;
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final notesCtrl = TextEditingController(text: existing?.notes ?? '');
    String selectedAssigneeId = existing?.assigneeId ?? '';
    String selectedPriority = existing?.priority ?? 'none';
    bool isUrgent = existing?.isUrgent ?? false;
    DateTime? dueDate = existing?.dueDate;
    String selectedStatus = existing?.status.name ?? 'pending';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Text(
              isEdit ? 'Edit Task' : 'Create Task',
              style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: _primary),
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _dialogField('Title', titleCtrl),
                    const SizedBox(height: 12),
                    _dialogField('Description', descCtrl, maxLines: 3),
                    const SizedBox(height: 12),
                    _dialogField('Notes', notesCtrl, maxLines: 2),
                    const SizedBox(height: 12),
                    Text('Assign To', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                    const SizedBox(height: 4),
                    DropdownButtonFormField<String>(
                      value: selectedAssigneeId.isNotEmpty ? selectedAssigneeId : null,
                      decoration: _dropdownDecoration(),
                      items: _availableUsers.map<DropdownMenuItem<String>>((u) {
                        return DropdownMenuItem(
                          value: u['id']?.toString() ?? '',
                          child: Text(u['username']?.toString() ?? u['name']?.toString() ?? '',
                              style: GoogleFonts.inter(fontSize: 14)),
                        );
                      }).toList(),
                      onChanged: (v) => setDialogState(() => selectedAssigneeId = v ?? ''),
                    ),
                    const SizedBox(height: 12),
                    Text('Priority', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                    const SizedBox(height: 4),
                    DropdownButtonFormField<String>(
                      value: selectedPriority,
                      decoration: _dropdownDecoration(),
                      items: ['none', 'low', 'medium', 'high']
                          .map((p) => DropdownMenuItem(value: p, child: Text(p.toUpperCase(), style: GoogleFonts.inter(fontSize: 14))))
                          .toList(),
                      onChanged: (v) => setDialogState(() => selectedPriority = v ?? 'none'),
                    ),
                    if (isEdit) ...[
                      const SizedBox(height: 12),
                      Text('Status', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<String>(
                        value: selectedStatus,
                        decoration: _dropdownDecoration(),
                        items: ['pending', 'ongoing', 'completed']
                            .map((s) => DropdownMenuItem(value: s, child: Text(s.toUpperCase(), style: GoogleFonts.inter(fontSize: 14))))
                            .toList(),
                        onChanged: (v) => setDialogState(() => selectedStatus = v ?? 'pending'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: ctx,
                                initialDate: dueDate ?? DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2030),
                              );
                              if (picked != null) setDialogState(() => dueDate = picked);
                            },
                            child: InputDecorator(
                              decoration: _dropdownDecoration().copyWith(
                                labelText: 'Due Date',
                                labelStyle: GoogleFonts.inter(fontSize: 13),
                                suffixIcon: const Icon(Icons.calendar_today, size: 18),
                              ),
                              child: Text(
                                dueDate != null ? DateFormat('MMM d, yyyy').format(dueDate!) : 'Select date',
                                style: GoogleFonts.inter(fontSize: 14),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Row(
                          children: [
                            Checkbox(
                              value: isUrgent,
                              onChanged: (v) => setDialogState(() => isUrgent = v ?? false),
                              activeColor: Colors.red,
                            ),
                            Text('Urgent', style: GoogleFonts.inter(fontSize: 14, color: Colors.red)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: GoogleFonts.inter(color: _primary)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _primary),
                onPressed: () async {
                  if (titleCtrl.text.trim().isEmpty) return;
                  final assigneeName = _availableUsers
                      .where((u) => (u['id']?.toString() ?? '') == selectedAssigneeId)
                      .map((u) => u['username']?.toString() ?? u['name']?.toString() ?? '')
                      .firstOrNull ?? '';
                  final data = {
                    'title': titleCtrl.text.trim(),
                    'description': descCtrl.text.trim(),
                    'notes': notesCtrl.text.trim(),
                    'assigneeId': selectedAssigneeId,
                    'assigneeName': assigneeName,
                    'priority': selectedPriority,
                    'isUrgent': isUrgent,
                    if (dueDate != null) 'dueDate': dueDate!.toIso8601String(),
                    if (dueDate != null) 'hasDueDate': true,
                    if (isEdit) 'status': selectedStatus == 'ongoing' ? 'in_progress' : selectedStatus,
                  };
                  try {
                    if (isEdit) {
                      await _apiService.updateTask(existing.id, data);
                    } else {
                      await _apiService.createTask(data);
                    }
                    if (mounted) Navigator.pop(ctx);
                    _fetchData();
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
                child: Text(isEdit ? 'Update' : 'Create', style: GoogleFonts.inter()),
              ),
            ],
          );
        },
      ),
    );
  }

  InputDecoration _dropdownDecoration() {
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _primary.withOpacity(0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _primary.withOpacity(0.2)),
      ),
    );
  }

  Widget _dialogField(String label, TextEditingController ctrl, {int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.inter(fontSize: 13, color: _primary)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          maxLines: maxLines,
          style: GoogleFonts.inter(fontSize: 14),
          decoration: _dropdownDecoration(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          _buildStatsRow(),
          _buildFiltersRow(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildErrorState()
                    : _filteredTasks.isEmpty
                        ? _buildEmptyState()
                        : _buildTaskTable(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Task Management',
                    style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
                const SizedBox(height: 4),
                Text('Allocate and track team tasks',
                    style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
              ],
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _primary,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => _showTaskDialog(),
            icon: const Icon(Icons.add, size: 18),
            label: Text('New Task', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final total = _stats['total'] ?? _tasks.length;
    final pending = _stats['pending'] ?? _tasks.where((t) => t.status == TaskStatus.pending).length;
    final completed = _stats['completed'] ?? _tasks.where((t) => t.status == TaskStatus.completed).length;
    final urgent = _tasks.where((t) => t.isUrgent).length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        children: [
          _statCard('Total', '$total', Icons.list_alt, _primary),
          _statCard('Pending', '$pending', Icons.pending_actions, const Color(0xFFF59E0B)),
          _statCard('Completed', '$completed', Icons.check_circle, const Color(0xFF10B981)),
          _statCard('Urgent', '$urgent', Icons.priority_high, const Color(0xFFEF4444)),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Container(
      width: 180,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: GoogleFonts.manrope(fontSize: 22, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
              Text(label, style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersRow() {
    final filters = [
      ('all', 'All'),
      ('pending', 'Pending'),
      ('ongoing', 'In Progress'),
      ('completed', 'Completed'),
      ('urgent', 'Urgent'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 12),
      child: Row(
        children: [
          ...filters.map((f) {
            final isActive = _filterStatus == f.$1;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.$2, style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isActive ? Colors.white : _primary,
                )),
                selected: isActive,
                selectedColor: _primary,
                backgroundColor: Colors.white,
                side: BorderSide(color: _primary.withOpacity(0.2)),
                onSelected: (_) => setState(() => _filterStatus = f.$1),
              ),
            );
          }),
          const Spacer(),
          SizedBox(
            width: 260,
            height: 40,
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              style: GoogleFonts.inter(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search tasks...',
                hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _primary.withOpacity(0.15)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _primary.withOpacity(0.15)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh, color: _primary),
            tooltip: 'Refresh',
            onPressed: _fetchData,
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTable() {
    final tasks = _filteredTasks;
    return Container(
      margin: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_cardRadius),
        child: SingleChildScrollView(
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(_headerBg),
            headingTextStyle: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: _primary, letterSpacing: 0.5),
            dataTextStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
            columnSpacing: 24,
            horizontalMargin: 20,
            columns: const [
              DataColumn(label: Text('TITLE')),
              DataColumn(label: Text('ASSIGNEE')),
              DataColumn(label: Text('PRIORITY')),
              DataColumn(label: Text('STATUS')),
              DataColumn(label: Text('DUE DATE')),
              DataColumn(label: Text('ACTIONS')),
            ],
            rows: tasks.map((t) {
              return DataRow(cells: [
                DataCell(Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t.isUrgent)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(Icons.bolt, size: 16, color: Colors.red.shade400),
                      ),
                    Flexible(
                      child: Text(t.title, overflow: TextOverflow.ellipsis, maxLines: 1),
                    ),
                  ],
                )),
                DataCell(Text(t.assigneeName.isNotEmpty ? t.assigneeName : '-')),
                DataCell(_priorityChip(t.priority)),
                DataCell(_statusChip(t.status)),
                DataCell(Text(
                  t.dueDate != null ? DateFormat('MMM d').format(t.dueDate!) : '-',
                  style: GoogleFonts.inter(fontSize: 13),
                )),
                DataCell(Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.edit_outlined, size: 18, color: _primary.withOpacity(0.7)),
                      tooltip: 'Edit',
                      onPressed: () => _showTaskDialog(existing: t),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.withOpacity(0.6)),
                      tooltip: 'Delete',
                      onPressed: () => _deleteTask(t),
                    ),
                  ],
                )),
              ]);
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _priorityChip(String priority) {
    Color color;
    switch (priority) {
      case 'high':
        color = const Color(0xFFEF4444);
        break;
      case 'medium':
        color = const Color(0xFFF59E0B);
        break;
      case 'low':
        color = const Color(0xFF3B82F6);
        break;
      default:
        color = const Color(0xFF9CA3AF);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
      child: Text(
        priority.toUpperCase(),
        style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Widget _statusChip(TaskStatus status) {
    Color color;
    String label;
    switch (status) {
      case TaskStatus.pending:
        color = const Color(0xFFF59E0B);
        label = 'PENDING';
        break;
      case TaskStatus.ongoing:
        color = const Color(0xFF3B82F6);
        label = 'IN PROGRESS';
        break;
      case TaskStatus.completed:
        color = const Color(0xFF10B981);
        label = 'COMPLETED';
        break;
      case TaskStatus.overdue:
        color = const Color(0xFFEF4444);
        label = 'OVERDUE';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.task_alt, size: 64, color: _primary.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('No tasks found', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w700, color: _primary)),
          const SizedBox(height: 8),
          Text('Create a new task to get started',
              style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text('Failed to load tasks', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w700, color: _primary)),
          const SizedBox(height: 8),
          Text(_error ?? '', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _primary),
            onPressed: _fetchData,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Retry', style: GoogleFonts.inter()),
          ),
        ],
      ),
    );
  }
}
