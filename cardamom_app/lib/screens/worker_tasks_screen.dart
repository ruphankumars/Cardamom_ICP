import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/cache_manager.dart';
import '../models/task.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/offline_indicator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

class WorkerTasksScreen extends StatefulWidget {
  const WorkerTasksScreen({super.key});

  @override
  State<WorkerTasksScreen> createState() => _WorkerTasksScreenState();
}

class _WorkerTasksScreenState extends State<WorkerTasksScreen> with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;
  List<Task> _tasks = [];
  bool _isLoading = true;
  bool _isFromCache = false;
  String _cacheAge = '';

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
    setState(() => _isLoading = true);
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final cacheManager = context.read<CacheManager>();
      final result = await cacheManager.fetchWithCache<List<dynamic>>(
        apiCall: () async {
          final res = await _apiService.getTasks(assigneeId: auth.userId);
          // Handle paginated response: { data: [...], pagination: {...} }
          final resData = res.data;
          final tasksList = (resData is Map && resData['data'] is List)
              ? List<dynamic>.from(resData['data'])
              : List<dynamic>.from(resData);
          return tasksList;
        },
        cache: cacheManager.taskCache,
      );
      if (!mounted) return;
      setState(() {
        _tasks = result.data.map((t) => Task.fromJson(t)).toList();
        _isFromCache = result.fromCache;
        _cacheAge = result.ageString;
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('Error fetching worker tasks: $e');
      debugPrint('Stack trace: $stackTrace');
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('🔍🔍🔍 WorkerTasksScreen.build() called');
    return AppShell(
      title: 'My Daily Tasks',
      subtitle: 'Track your progress',
      disableInternalScrolling: true, // Required for TabBarView
      content: Column(
        children: [
          if (_isFromCache)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 16),
              child: CachedDataChip(ageString: _cacheAge),
            ),
          _buildTabHeader(),
          Expanded(
            child: _isLoading 
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTaskList(TaskStatus.pending),
                    _buildTaskList(TaskStatus.ongoing),
                    _buildTaskList(TaskStatus.completed),
                  ],
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabHeader() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.titaniumMid.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: AppTheme.primary,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: AppTheme.primary.withOpacity(0.3), blurRadius: 4, offset: const Offset(0, 2)),
          ],
        ),
        labelColor: Colors.white,
        unselectedLabelColor: AppTheme.title.withOpacity(0.6),
        labelStyle: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.bold),
        tabs: const [
          Tab(text: 'To-do'),
          Tab(text: 'Progress'),
          Tab(text: 'Done'),
        ],
      ),
    );
  }

  Widget _buildTaskList(TaskStatus status) {
    final filteredTasks = _tasks.where((t) => t.status == status).toList();

    if (filteredTasks.isEmpty) {
      return _buildEmptyState(status);
    }

    return RefreshIndicator(
      onRefresh: _fetchTasks,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: filteredTasks.length,
        itemBuilder: (context, index) => _buildTaskItem(filteredTasks[index]),
      ),
    );
  }

  Widget _buildTaskItem(Task task) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.titaniumBorder),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.title,
                  style: GoogleFonts.manrope(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.title),
                ),
              ),
              _buildSmallBadge(task.priority.toUpperCase(), _getPriorityColor(task.priority)),
            ],
          ),
          const SizedBox(height: 8),
          Text(task.description, style: TextStyle(fontSize: 14, color: AppTheme.title.withOpacity(0.7))),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.calendar_month_outlined, size: 14, color: AppTheme.primary.withOpacity(0.5)),
                  const SizedBox(width: 4),
                  Text(
                    DateFormat('MMM dd, hh:mm a').format(task.deadline ?? task.dueDate ?? DateTime.now()),
                    style: TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
              _buildStatusAction(task),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusAction(Task task) {
    if (task.status == TaskStatus.pending) {
      return _buildActionButton('Start Now', Icons.play_arrow_rounded, Colors.blue, () => _updateStatus(task, TaskStatus.ongoing));
    } else if (task.status == TaskStatus.ongoing) {
      return _buildActionButton('Mark Done', Icons.check_circle_outline_rounded, Colors.green, () => _updateStatus(task, TaskStatus.completed));
    }
    return _buildSmallBadge('COMPLETED', Colors.green);
  }

  Widget _buildActionButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildSmallBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
    );
  }

  Color _getPriorityColor(String priority) {
    switch (priority.toLowerCase()) {
      case 'high': return Colors.red;
      case 'medium': return Colors.orange;
      case 'low': return Colors.blue;
      default: return Colors.grey;
    }
  }

  Widget _buildEmptyState(TaskStatus status) {
    String message = 'No tasks in this category';
    IconData icon = Icons.assignment_turned_in_outlined;
    if (status == TaskStatus.pending) {
      message = 'All caught up! No to-do items.';
      icon = Icons.celebration_rounded;
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: AppTheme.titaniumDark.withOpacity(0.2)),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: AppTheme.titaniumDark.withOpacity(0.4))),
        ],
      ),
    );
  }

  Future<void> _updateStatus(Task task, TaskStatus newStatus) async {
    try {
      await _apiService.updateTask(task.id, {'status': newStatus == TaskStatus.ongoing ? 'in_progress' : newStatus.name});
      _fetchTasks();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }
}
