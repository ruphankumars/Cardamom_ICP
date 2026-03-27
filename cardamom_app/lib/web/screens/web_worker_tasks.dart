import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../../models/task.dart';

/// Web-optimized Worker Tasks view.
/// Card grid layout with status tabs (Pending, In Progress, Completed).
class WebWorkerTasks extends StatefulWidget {
  const WebWorkerTasks({super.key});

  @override
  State<WebWorkerTasks> createState() => _WebWorkerTasksState();
}

class _WebWorkerTasksState extends State<WebWorkerTasks> with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _cardRadius = 12.0;

  final ApiService _apiService = ApiService();
  late TabController _tabController;
  List<Task> _tasks = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _fetchTasks();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _fetchTasks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final res = await _apiService.getTasks(assigneeId: auth.userId);
      final resData = res.data;
      final tasksList = (resData is Map && resData['data'] is List)
          ? List<dynamic>.from(resData['data'])
          : (resData is List ? List<dynamic>.from(resData) : <dynamic>[]);
      if (mounted) {
        setState(() {
          _tasks = tasksList.map((t) => Task.fromJson(t)).toList();
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

  Future<void> _updateTaskStatus(Task task, String newStatus) async {
    try {
      await _apiService.updateTask(task.id, {'status': newStatus});
      _fetchTasks();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  List<Task> _tasksForStatus(TaskStatus status) {
    return _tasks.where((t) => t.status == status).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          _buildSummaryCards(),
          _buildTabBar(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildErrorState()
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildTaskGrid(TaskStatus.pending),
                          _buildTaskGrid(TaskStatus.ongoing),
                          _buildTaskGrid(TaskStatus.completed),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('My Tasks',
                    style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
                const SizedBox(height: 4),
                Text('Track your daily progress',
                    style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: _primary),
            tooltip: 'Refresh',
            onPressed: _fetchTasks,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    final pending = _tasksForStatus(TaskStatus.pending).length;
    final ongoing = _tasksForStatus(TaskStatus.ongoing).length;
    final completed = _tasksForStatus(TaskStatus.completed).length;
    final urgent = _tasks.where((t) => t.isUrgent && t.status != TaskStatus.completed).length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        children: [
          _miniStat('To-Do', '$pending', const Color(0xFFF59E0B), Icons.inbox),
          _miniStat('In Progress', '$ongoing', const Color(0xFF3B82F6), Icons.trending_up),
          _miniStat('Done', '$completed', const Color(0xFF10B981), Icons.check_circle),
          _miniStat('Urgent', '$urgent', const Color(0xFFEF4444), Icons.bolt),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color, IconData icon) {
    return Container(
      width: 170,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
              Text(label, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF6B7280))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(32, 20, 32, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _primary.withOpacity(0.12)),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: _primary,
          borderRadius: BorderRadius.circular(8),
        ),
        labelColor: Colors.white,
        unselectedLabelColor: _primary,
        labelStyle: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700),
        unselectedLabelStyle: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w500),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerHeight: 0,
        tabs: [
          Tab(text: 'Pending (${_tasksForStatus(TaskStatus.pending).length})'),
          Tab(text: 'In Progress (${_tasksForStatus(TaskStatus.ongoing).length})'),
          Tab(text: 'Completed (${_tasksForStatus(TaskStatus.completed).length})'),
        ],
      ),
    );
  }

  Widget _buildTaskGrid(TaskStatus status) {
    final tasks = _tasksForStatus(status);
    if (tasks.isEmpty) return _buildEmptyTab(status);

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 900 ? 3 : (constraints.maxWidth > 600 ? 2 : 1);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(32, 12, 32, 32),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 1.6,
          ),
          itemCount: tasks.length,
          itemBuilder: (context, index) => _buildTaskCard(tasks[index]),
        );
      },
    );
  }

  Widget _buildTaskCard(Task task) {
    Color priorityColor;
    switch (task.priority) {
      case 'high':
        priorityColor = const Color(0xFFEF4444);
        break;
      case 'medium':
        priorityColor = const Color(0xFFF59E0B);
        break;
      case 'low':
        priorityColor = const Color(0xFF3B82F6);
        break;
      default:
        priorityColor = const Color(0xFF9CA3AF);
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: task.isUrgent ? Border.all(color: const Color(0xFFEF4444).withOpacity(0.4), width: 1.5) : null,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: priorityColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                task.priority.toUpperCase(),
                style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: priorityColor, letterSpacing: 0.5),
              ),
              if (task.isUrgent) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('URGENT',
                      style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: const Color(0xFFEF4444))),
                ),
              ],
              const Spacer(),
              _buildStatusAction(task),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            task.title,
            style: GoogleFonts.manrope(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF111827),
              decoration: task.status == TaskStatus.completed ? TextDecoration.lineThrough : null,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (task.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              task.description,
              style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const Spacer(),
          Row(
            children: [
              if (task.dueDate != null) ...[
                Icon(Icons.schedule, size: 14, color: const Color(0xFF9CA3AF)),
                const SizedBox(width: 4),
                Text(
                  DateFormat('MMM d').format(task.dueDate!),
                  style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280)),
                ),
              ],
              const Spacer(),
              if (task.subtasks.isNotEmpty)
                Text(
                  '${task.subtasks.where((s) => s.completed).length}/${task.subtasks.length}',
                  style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusAction(Task task) {
    switch (task.status) {
      case TaskStatus.pending:
        return _actionBtn('Start', Icons.play_arrow, const Color(0xFF3B82F6),
            () => _updateTaskStatus(task, 'in_progress'));
      case TaskStatus.ongoing:
        return _actionBtn('Done', Icons.check, const Color(0xFF10B981),
            () => _updateTaskStatus(task, 'completed'));
      case TaskStatus.completed:
        return Icon(Icons.check_circle, size: 20, color: const Color(0xFF10B981));
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _actionBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyTab(TaskStatus status) {
    String message;
    IconData icon;
    switch (status) {
      case TaskStatus.pending:
        message = 'No pending tasks';
        icon = Icons.inbox;
        break;
      case TaskStatus.ongoing:
        message = 'No tasks in progress';
        icon = Icons.trending_up;
        break;
      case TaskStatus.completed:
        message = 'No completed tasks yet';
        icon = Icons.check_circle_outline;
        break;
      default:
        message = 'No tasks';
        icon = Icons.list;
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: _primary.withOpacity(0.25)),
          const SizedBox(height: 12),
          Text(message, style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 56, color: Colors.red.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text('Failed to load tasks', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
          const SizedBox(height: 8),
          Text(_error ?? '', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _primary),
            onPressed: _fetchTasks,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Retry', style: GoogleFonts.inter()),
          ),
        ],
      ),
    );
  }
}
