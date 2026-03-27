import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/cache_manager.dart';
import '../services/connectivity_service.dart';
import '../services/persistent_operation_queue.dart';
import '../models/task.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/offline_indicator.dart';

class TaskManagementScreen extends StatefulWidget {
  const TaskManagementScreen({super.key});

  @override
  State<TaskManagementScreen> createState() => _TaskManagementScreenState();
}

class _TaskManagementScreenState extends State<TaskManagementScreen> {
  final ApiService _apiService = ApiService();
  List<Task> _tasks = [];
  Map<String, dynamic> _stats = {};
  bool _isLoading = true;
  List<dynamic> _availableUsers = [];
  String _filterStatus = 'all'; // all, pending, completed, urgent
  bool _isFromCache = false;
  String _cacheAge = '';

  @override
  void initState() {
    super.initState();
    _fetchData();
    _fetchUsers();
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final cacheManager = context.read<CacheManager>();
      final result = await cacheManager.fetchWithCache<List<dynamic>>(
        apiCall: () async {
          final tasksRes = await _apiService.getTasks();
          final statsRes = await _apiService.getTaskStats();
          // Handle paginated response: { data: [...], pagination: {...} }
          final tasksData = tasksRes.data;
          final tasksList = (tasksData is Map && tasksData['data'] is List)
              ? tasksData['data']
              : (tasksData is List ? tasksData : []);
          return [tasksList, statsRes.data ?? {}];
        },
        cache: cacheManager.taskCache,
      );
      if (mounted) {
        final taskList = result.data[0] as List;
        final statsData = result.data[1];
        setState(() {
          _tasks = taskList.map((t) => Task.fromJson(t)).toList();
          _stats = statsData is Map<String, dynamic> ? statsData : {};
          _isFromCache = result.fromCache;
          _cacheAge = result.ageString;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchUsers() async {
    try {
      final res = await _apiService.getUsers();
      if (mounted && res.data is Map) {
        final list = (res.data as Map)['users'];
        if (list is List) {
          // Filter out clients - only allow task assignment to users and admins
          final filtered = list.where((u) => 
            u['role'] != 'client' && u['role'] != 'Client'
          ).toList();
          setState(() => _availableUsers = filtered);
        }
      }
    } catch (_) {}
  }

  List<Task> get _filteredTasks {
    if (_filterStatus == 'all') return _tasks;
    if (_filterStatus == 'urgent') return _tasks.where((t) => t.isUrgent).toList();
    if (_filterStatus == 'pending') return _tasks.where((t) => t.status != TaskStatus.completed).toList();
    if (_filterStatus == 'completed') return _tasks.where((t) => t.status == TaskStatus.completed).toList();
    return _tasks;
  }

  @override
  Widget build(BuildContext context) {
    // Role guard: allow admin roles and employees (Issue #15 fix)
    final role = Provider.of<AuthProvider>(context, listen: false).role?.toLowerCase();
    if (role != 'superadmin' && role != 'admin' && role != 'ops' && role != 'user') {
      return Scaffold(
        body: Container(
          color: AppTheme.titaniumLight,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline, size: 64, color: AppTheme.danger.withOpacity(0.5)),
                const SizedBox(height: 16),
                Text('Access Denied', style: GoogleFonts.outfit(
                  fontSize: 24, fontWeight: FontWeight.bold, color: AppTheme.danger)),
                const SizedBox(height: 8),
                Text('Admin access required', style: TextStyle(color: AppTheme.muted)),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Go Back'),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
      );
    }
    
    return AppShell(
      title: 'Task Allocator',
      showAppBar: false,
      showBottomNav: false,
      disableInternalScrolling: true,
      content: Container(
        color: AppTheme.titaniumMid, // SOLID BACKGROUND
        child: Stack(
          children: [
            // BLOBS REMOVED FOR DEPTH FOCUS
            SafeArea(
              child: Column(
                children: [
                  _buildTitaniumHeader(),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(top: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.titaniumLight, // SOLID SURFACE
                        borderRadius: const BorderRadius.only(topLeft: Radius.circular(40), topRight: Radius.circular(40)),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20, offset: const Offset(0, -10)), // DEPTH SHADOW
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: RefreshIndicator(
                        onRefresh: _fetchData,
                        color: AppTheme.primary,
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 120, top: 20),
                          children: [
                            if (_isFromCache)
                              Padding(
                                padding: const EdgeInsets.only(left: 20, bottom: 8),
                                child: CachedDataChip(ageString: _cacheAge),
                              ),
                            _buildHeroCard(),
                            const SizedBox(height: 24),
                            _buildPrecisionTools(),
                            const SizedBox(height: 32),
                            _buildSectionHeader('TASK QUEUE - ${_filterStatus.toUpperCase()}'),
                            ..._filteredTasks.map((t) => _buildGlassTaskItem(t)),
                            if (_filteredTasks.isEmpty && !_isLoading) _buildEmptyState(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  Widget _buildTitaniumHeader() {
    return Builder(builder: (ctx) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _machinedBtn(Icons.menu_rounded, () => Scaffold.of(ctx).openDrawer()),
          Text('TITANIUM ALLOCATOR', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 2.5)),
          _machinedBtn(Icons.person_rounded, () => _showAIIntel()),
        ],
      ),
    ));
  }

  Widget _machinedBtn(IconData icon, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44, height: 44,
      decoration: AppTheme.machinedDecoration, // SYNCED WITH DASHBOARD
      child: Icon(icon, color: AppTheme.primary, size: 22),
    ),
  );

  Widget _buildHeroCard() {
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: AppTheme.titaniumMid, 
      borderRadius: BorderRadius.circular(28),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 15, offset: const Offset(6, 6)), // BASE CAST
        BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(3, 3)),   // SECONDARY
      ],
      border: Border.all(color: AppTheme.titaniumDark.withOpacity(0.5), width: 1), // DARK BORDER
    ),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STATUS: RESOURCE OPTIMIZATION', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.primary, letterSpacing: 1.5)),
          const SizedBox(height: 4),
          Text('Mission Central', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w900, color: AppTheme.title, height: 1.1)),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.sync_rounded, size: 10, color: AppTheme.primary),
              const SizedBox(width: 4),
              Text(DateFormat('HH:mm').format(DateTime.now()), style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.primary)),
            ],
          ),
          const SizedBox(height: 24),
          // 4-Stat Grid with clickable boxes
          Row(
            children: [
              Expanded(child: _clickableStat('TOTAL', '${_stats['total'] ?? 0}', 'All', null)),
              const SizedBox(width: 8),
              Expanded(child: _clickableStat('ONGOING', '${_stats['inProgress'] ?? 0}', 'Active', Colors.blue)),
              const SizedBox(width: 8),
              Expanded(child: _clickableStat('PENDING', '${_stats['pending'] ?? 0}', 'Action', Colors.orange)),
              const SizedBox(width: 8),
              Expanded(child: _clickableStat('DONE', '${_stats['completed'] ?? 0}', 'Sync', Colors.green)),
            ],
          ),
        ],
      ),
    ),
  );
}

Widget _clickableStat(String label, String value, String hint, Color? accentColor) {
  return GestureDetector(
    onTap: () => _showTasksByStatus(label.toLowerCase()),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: AppTheme.titaniumLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor?.withOpacity(0.3) ?? Colors.white.withOpacity(0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(2, 2)),
        ],
      ),
      child: Column(
        children: [
          Text(
            value,
            style: GoogleFonts.manrope(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: accentColor ?? AppTheme.title,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.manrope(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: AppTheme.primary,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    ),
  );
}

void _showTasksByStatus(String status) {
  List<Task> filteredTasks;
  String title;
  Color accentColor;
  
  switch (status) {
    case 'total':
      filteredTasks = _tasks;
      title = 'ALL TASKS';
      accentColor = AppTheme.primary;
      break;
    case 'ongoing':
      filteredTasks = _tasks.where((t) => t.status == TaskStatus.ongoing).toList();
      title = 'IN PROGRESS';
      accentColor = Colors.blue;
      break;
    case 'pending':
      filteredTasks = _tasks.where((t) => t.status == TaskStatus.pending).toList();
      title = 'PENDING TASKS';
      accentColor = Colors.orange;
      break;
    case 'done':
    case 'completed':
      filteredTasks = _tasks.where((t) => t.status == TaskStatus.completed).toList();
      title = 'COMPLETED';
      accentColor = Colors.green;
      break;
    default:
      filteredTasks = _tasks;
      title = 'TASKS';
      accentColor = AppTheme.primary;
  }
  
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: AppTheme.titaniumLight,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.titaniumDark, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(color: accentColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 12),
                Text(title, style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w900, color: AppTheme.title, letterSpacing: 2.0)),
                const Spacer(),
                Text('${filteredTasks.length} items', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.primary)),
              ],
            ),
          ),
          Expanded(
            child: filteredTasks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline, size: 48, color: AppTheme.titaniumDark.withOpacity(0.3)),
                      const SizedBox(height: 12),
                      Text('No tasks in this category', style: TextStyle(color: AppTheme.titaniumDark.withOpacity(0.5))),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: filteredTasks.length,
                  itemBuilder: (context, index) {
                    final task = filteredTasks[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.titaniumBorder),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(
                              color: accentColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              task.isUrgent ? Icons.bolt : Icons.task_alt,
                              color: accentColor,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(task.title, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14)),
                                if (task.assigneeName != null && task.assigneeName!.isNotEmpty)
                                  Text('Assigned to: ${task.assigneeName}', style: TextStyle(fontSize: 12, color: AppTheme.primary)),
                              ],
                            ),
                          ),
                          if (task.isUrgent)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                              child: const Text('URGENT', style: TextStyle(fontSize: 10, color: Colors.red, fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                    );
                  },
                ),
          ),
        ],
      ),
    ),
  );
}
  Widget _headerStat(String label, String value, String trend, {bool isWarning = false, bool isSuccess = false}) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppTheme.titaniumLight, 
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 4, offset: const Offset(2, 2)),
      ],
      border: Border.all(color: AppTheme.titaniumDark.withOpacity(0.3), width: 0.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: AppTheme.primary)),
        const SizedBox(height: 4),
        Text(value, style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w900, color: AppTheme.title)),
        Text(trend, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: isWarning ? AppTheme.warning : (isSuccess ? AppTheme.success : AppTheme.primary))),
      ],
    ),
  );

  Widget _buildPrecisionTools() {
    return GridView.count(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: 4,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      mainAxisSpacing: 16, crossAxisSpacing: 16, childAspectRatio: 0.85,
      children: [
        _toolItem(Icons.add_task_rounded, 'Add Task', () => _showTaskSheet()),
        _toolItem(Icons.analytics_outlined, 'Analysis', () => _showAnalysis()),
        _toolItem(Icons.groups_outlined, 'Teams', () => _showTeams()),
        _toolItem(Icons.sync_rounded, 'Refresh', () { HapticFeedback.mediumImpact(); _fetchData(); }),
        _toolItem(Icons.tune_rounded, 'Filters', () => _showFilters()),
        _toolItem(Icons.history_rounded, 'Audit', () => _showAudit()),
        _toolItem(Icons.lightbulb_outline_rounded, 'AI Intel', () => _showAIIntel()),
        _toolItem(Icons.settings_outlined, 'Config', () => _showConfig()),
      ],
    );
  }

  Widget _toolItem(IconData icon, String label, VoidCallback onTap) => GestureDetector(
    onTap: () { HapticFeedback.lightImpact(); onTap(); },
    child: Column(
      children: [
        Container(
          width: 50, height: 50,
          decoration: AppTheme.machinedDecoration, // SYNCED WITH DASHBOARD
          child: Icon(icon, color: AppTheme.title, size: 20),
        ),
        const SizedBox(height: 6),
        Text(label.toUpperCase(), textAlign: TextAlign.center, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: AppTheme.primary)),
      ],
    ),
  );

  Widget _buildSectionHeader(String title) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: Text(title, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 2.0)),
  );

  Widget _buildGlassTaskItem(Task t) {
    final userRole = Provider.of<AuthProvider>(context, listen: false).role?.toLowerCase() ?? 'user';
    final canDelete = userRole == 'superadmin' || userRole == 'admin' || userRole == 'ops';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                  child: Icon(t.status == TaskStatus.completed ? Icons.check_circle_rounded : Icons.pending_rounded, color: AppTheme.primary, size: 20),
                ),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.title)),
                  Text(t.assigneeName.isEmpty ? 'UNASSIGNED' : t.assigneeName.toUpperCase(), style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.muted)),
                ])),
                if (t.isUrgent) const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.bolt_rounded, color: AppTheme.danger, size: 20)),
                if (canDelete) _machinedBtn(Icons.delete_outline_rounded, () => _deleteTask(t)),
                const SizedBox(width: 8),
                _machinedBtn(Icons.chevron_right_rounded, () => _showTaskSheet(t)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() => Container(
    margin: const EdgeInsets.all(32), padding: const EdgeInsets.all(40),
    decoration: BoxDecoration(color: AppTheme.titaniumMid.withOpacity(0.4), borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.white.withOpacity(0.2), width: 1)),
    child: Column(children: [
      const Icon(Icons.assignment_turned_in_rounded, size: 48, color: AppTheme.titaniumDark),
      const SizedBox(height: 16),
      Text('QUEUE SECURED', style: GoogleFonts.manrope(fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 1.0)),
    ]),
  );

  Widget _buildBottomNav() => Positioned(
    bottom: 20, left: 20, right: 20,
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
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 25, offset: const Offset(0, 12))],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navIcon(Icons.dashboard_rounded, false, () { if (Navigator.canPop(context)) Navigator.pop(context); else Navigator.pushReplacementNamed(context, '/'); }),
              _navIcon(Icons.assignment_rounded, true, () {}), // current page — no-op
              _navIcon(Icons.list_alt_rounded, false, () => Navigator.pushNamed(context, '/view_orders')),
              _navIcon(Icons.settings_rounded, false, () => _showConfig()),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _navIcon(IconData icon, bool active, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44, height: 44,
      decoration: active ? BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle) : null,
      child: Icon(icon, color: active ? Colors.white : AppTheme.primary, size: 22),
    ),
  );

  // Functionalities
  void _showAnalysis() {
    // #75: Use real stats instead of hardcoded data
    final total = (_stats['total'] ?? 0) as int;
    final completed = (_stats['completed'] ?? 0) as int;
    final pending = (_stats['pending'] ?? 0) as int;
    final overdue = (_stats['overdue'] ?? 0) as int;
    final efficiency = total > 0 ? ((completed / total) * 100).round() : 0;
    final effColor = efficiency >= 80 ? AppTheme.success : (efficiency >= 50 ? Colors.orange : AppTheme.danger);
    showDialog(context: context, builder: (_) => _GlassDialog(
      title: 'TASK ANALYSIS',
      child: Column(children: [
        _analysisRow('EFFICIENCY', '$efficiency%', effColor),
        _analysisRow('OVERDUE', overdue > 0 ? '$overdue TASKS' : 'NONE', overdue > 0 ? AppTheme.danger : AppTheme.success),
        _analysisRow('TOTAL TASKS', '$total', AppTheme.primary),
        const SizedBox(height: 20),
        SizedBox(height: 100, child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _statCircle('DONE', completed, AppTheme.success),
          _statCircle('TODO', pending, AppTheme.danger),
        ])),
      ]),
    ));
  }

  Widget _analysisRow(String l, String v, Color c) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
    Text(l, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w900, color: AppTheme.primary)),
    Text(v, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w900, color: c)),
  ]));

  Widget _statCircle(String l, dynamic v, Color c) => Column(children: [
    Container(width: 50, height: 50, decoration: BoxDecoration(border: Border.all(color: c, width: 3), shape: BoxShape.circle), child: Center(child: Text('$v', style: GoogleFonts.manrope(fontWeight: FontWeight.w900)))),
    const SizedBox(height: 4), Text(l, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary)),
  ]);

  void _showTeams() {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent, builder: (_) => Container(
      height: 400, decoration: const BoxDecoration(color: AppTheme.titaniumLight, borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      child: Column(children: [
        const SizedBox(height: 12), Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.titaniumDark, borderRadius: BorderRadius.circular(2))),
        Padding(padding: const EdgeInsets.all(24), child: Text('TEAM OPERATIVES', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 2.0))),
        Expanded(child: ListView(children: _availableUsers.map((u) => ListTile(
          leading: CircleAvatar(backgroundColor: AppTheme.primary.withOpacity(0.2), child: Text(u['username']?[0].toUpperCase() ?? 'U', style: const TextStyle(color: AppTheme.primary))),
          title: Text(u['username'] ?? '', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          subtitle: Text(u['role']?.toUpperCase() ?? 'OPERATIVE', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.muted)),
          trailing: const Icon(Icons.chevron_right_rounded),
        )).toList())),
      ]),
    ));
  }

  void _showFilters() {
    showDialog(context: context, builder: (_) => _GlassDialog(
      title: 'MASTER FILTERS',
      child: Column(children: ['all', 'pending', 'completed', 'urgent'].map((f) => ListTile(
        title: Text(f.toUpperCase(), style: GoogleFonts.manrope(fontWeight: FontWeight.w900, color: _filterStatus == f ? AppTheme.primary : AppTheme.title)),
        trailing: _filterStatus == f ? const Icon(Icons.check_circle_rounded, color: AppTheme.primary) : null,
        onTap: () { setState(() => _filterStatus = f); Navigator.pop(context); },
      )).toList()),
    ));
  }

  void _showAIIntel() {
    // #75: Use real task data for insights
    final overdue = (_stats['overdue'] ?? 0) as int;
    final inProgress = (_stats['inProgress'] ?? 0) as int;
    final pending = (_stats['pending'] ?? 0) as int;
    final urgentTasks = _tasks.where((t) => t.priority == 'high' && t.status != 'completed').toList();
    showDialog(context: context, builder: (_) => _GlassDialog(
      title: 'TASK INSIGHTS',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.auto_awesome_rounded, color: AppTheme.primary, size: 32),
        const SizedBox(height: 16),
        Text('Task queue summary based on current data.', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        _intelPoint('$inProgress tasks currently in progress.'),
        _intelPoint('$pending tasks waiting to be started.'),
        if (overdue > 0) _intelPoint('$overdue tasks are overdue — need attention.'),
        if (urgentTasks.isNotEmpty) _intelPoint('${urgentTasks.length} high-priority tasks pending.'),
        if (overdue == 0 && urgentTasks.isEmpty) _intelPoint('All tasks are on track.'),
      ]),
    ));
  }

  Widget _intelPoint(String text) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
    const Icon(Icons.arrow_right_rounded, color: AppTheme.primary),
    Expanded(child: Text(text, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.muted))),
  ]));

  void _showAudit() {
    showDialog(context: context, builder: (_) => _GlassDialog(
      title: 'SYSTEM AUDIT',
      child: SizedBox(height: 200, child: ListView(children: [
        _auditItem('TASK CREATED', '10:15 AM', 'SYSTEM'),
        _auditItem('STATUS UPDATED', '09:42 AM', 'ADMIN'),
        _auditItem('TEAM SYNC', '09:00 AM', 'AUTO'),
      ])),
    ));
  }

  Widget _auditItem(String l, String t, String a) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
    Text(t, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.muted)),
    const SizedBox(width: 12),
    Expanded(child: Text(l, style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w900))),
    Text(a, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.primary)),
  ]));

  void _showConfig() {
    showDialog(context: context, builder: (_) => _GlassDialog(
      title: 'MACHINE CONFIG',
      child: Column(children: [
        SwitchListTile(title: Text('AUTO-OPTIMIZE', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w900)), value: true, onChanged: (v) {}),
        SwitchListTile(title: Text('PUSH NOTIFICATIONS', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w900)), value: false, onChanged: (v) {}),
        SwitchListTile(title: Text('AI ASSIST', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w900)), value: true, onChanged: (v) {}),
      ]),
    ));
  }

  void _showTaskSheet([Task? task]) {
    HapticFeedback.mediumImpact();
    final userRole = Provider.of<AuthProvider>(context, listen: false).role?.toLowerCase() ?? 'user';
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _TitaniumTaskSheet(
        task: task, users: _availableUsers,
        allTasks: _tasks,
        userRole: userRole,
        onSave: (data) async {
          final connectivity = context.read<ConnectivityService>();
          if (!connectivity.isOnline && task == null) {
            // Offline: queue task creation for later sync
            final persistentQueue = context.read<PersistentOperationQueue>();
            await persistentQueue.enqueue(PendingOperation(
              id: 'task_${DateTime.now().millisecondsSinceEpoch}',
              type: 'create_task',
              method: 'POST',
              endpoint: '/tasks',
              payload: data,
            ));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Task queued — will sync when online'),
                  backgroundColor: Colors.orange,
                ),
              );
              Navigator.pop(context);
            }
            return;
          }
          if (task == null) await _apiService.createTask(data);
          else await _apiService.updateTask(task.id, data);
          if (mounted) { Navigator.pop(context); _fetchData(); }
        },
      ),
    );
  }

  Future<void> _deleteTask(Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: Colors.white.withOpacity(0.95),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.delete_outline_rounded, color: AppTheme.danger, size: 22),
              ),
              const SizedBox(width: 12),
              Text('DELETE TASK', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w900, color: AppTheme.title, letterSpacing: 1.0)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Are you sure you want to delete this task?', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.muted)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppTheme.titaniumMid.withOpacity(0.5), borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    if (task.isUrgent) const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.bolt_rounded, color: AppTheme.danger, size: 18)),
                    Expanded(child: Text(task.title, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.title))),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text('This action cannot be undone.', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.danger, fontWeight: FontWeight.w600)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('CANCEL', style: GoogleFonts.manrope(fontWeight: FontWeight.w900, color: AppTheme.primary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: Text('DELETE', style: GoogleFonts.manrope(fontWeight: FontWeight.w900)),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      await _apiService.deleteTask(task.id);
      HapticFeedback.mediumImpact();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Task "${task.title}" deleted', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        _fetchData();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete task: $e', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }
}

class _GlassDialog extends StatelessWidget {
  final String title;
  final Widget child;
  const _GlassDialog({required this.title, required this.child});
  @override Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: Center( // CENTERED
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320), // COMPACT WIDTH
          margin: const EdgeInsets.symmetric(horizontal: 24),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.85),
                borderRadius: BorderRadius.circular(32), // ROUNDED
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, 10))],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min, // COMPACT HEIGHT
                children: [
                  Text(title, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 1.5)),
                  const SizedBox(height: 20),
                  child,
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () => Navigator.pop(context), 
                    child: Text('CLOSE', style: GoogleFonts.manrope(fontWeight: FontWeight.w900, color: AppTheme.primary))
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TitaniumTaskSheet extends StatefulWidget {
  final Task? task;
  final List<dynamic> users;
  final List<Task> allTasks;
  final String userRole;
  final Function(Map<String, dynamic>) onSave;
  const _TitaniumTaskSheet({this.task, required this.users, required this.onSave, this.allTasks = const [], this.userRole = 'user'});
  @override State<_TitaniumTaskSheet> createState() => _TitaniumTaskSheetState();
}

class _TitaniumTaskSheetState extends State<_TitaniumTaskSheet> {
  late TextEditingController _title, _notes;
  String? _userId, _userName;
  bool _hasDate = false, _hasTime = true, _urgent = false;
  String _priority = 'medium', _repeat = 'daily';
  int _remYr = 0, _remMo = 0, _remDay = 2, _remHr = 8, _remMin = 30;
  DateTime? _reminderDate; // Reminder date when DATE toggle is on
  // Dependencies removed - replaced by Assign To

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _title = TextEditingController(text: t?.title ?? '');
    _notes = TextEditingController(text: t?.notes ?? '');
    if (t != null) {
      _userId = t.assigneeId; _userName = t.assigneeName;
      _hasDate = t.hasDueDate || t.deadline != null; _hasTime = t.hasDueTime;
      _urgent = t.isUrgent; _priority = t.priority.toLowerCase(); _repeat = t.repeatType.name.toLowerCase();
      if (t.deadline != null) _reminderDate = t.deadline;
      // dependsOn removed - replaced by Assign To
    }
  }

  @override Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(color: AppTheme.titaniumLight, borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      child: Column(children: [
        Padding(padding: const EdgeInsets.all(24), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _sheetBtn(Icons.close_rounded, () => Navigator.pop(context)),
          Text(widget.task == null ? 'NEW ALLOCATION' : 'EDIT MISSION', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w900, color: AppTheme.title, letterSpacing: 2.0)),
          _sheetBtn(Icons.check_rounded, _handleSave, color: AppTheme.success),
        ])),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(children: [
          _inputWell('TITLE', TextField(
            controller: _title, 
            style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w900), 
            decoration: const InputDecoration(border: InputBorder.none, filled: false),
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: true,
          )),
          const SizedBox(height: 16),
          _inputWell('NOTES', Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _notes, 
                minLines: 1,
                maxLines: 3, // Allow expansion but...
                keyboardType: TextInputType.text, // Forces standard keyboard with done button
                style: GoogleFonts.manrope(fontSize: 14), 
                decoration: InputDecoration(
                  border: InputBorder.none, 
                  filled: false,
                  hintText: 'Add notes...',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.keyboard_hide, size: 20, color: AppTheme.primary),
                    onPressed: () => FocusScope.of(context).unfocus(),
                  ),
                ),
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: true,
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
              ),
            ],
          )),
          const SizedBox(height: 24),
          _buildToggles(),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: _dropdown('PRIORITY', _priority, ['none','low','medium','high','critical'], (v) => setState(() => _priority = v!))),
            const SizedBox(width: 12),
            Expanded(child: _dropdown('REPEAT', _repeat, ['none','daily','weekly','monthly','yearly'], (v) => setState(() => _repeat = v!))),
          ]),
          const SizedBox(height: 24),
          _reminderWell(),
          const SizedBox(height: 24),
          _assigneeWell(),
          const SizedBox(height: 40),
        ]))),
      ]),
    );
  }

  Widget _sheetBtn(IconData icon, VoidCallback onTap, {Color? color}) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 48, height: 48,
      decoration: BoxDecoration(
        color: AppTheme.titaniumMid,
        shape: BoxShape.circle,
        boxShadow: [
          const BoxShadow(color: Colors.white70, blurRadius: 2, offset: Offset(-1, -1)),
          BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 4, offset: const Offset(2, 2)),
        ],
      ),
      child: Icon(icon, color: color ?? AppTheme.primary, size: 24),
    ),
  );

  Widget _inputWell(String label, Widget child) => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: AppTheme.titaniumMid.withOpacity(0.4), borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.white.withOpacity(0.2), width: 1)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w900, color: AppTheme.primary)), child]));
  
  Widget _buildToggles() => Column(
    children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: AppTheme.titaniumCardDecoration,
        child: Row(children: [
          _toggle(Icons.event_rounded, 'DATE', _hasDate, () async {
            if (!_hasDate) {
              // Show date picker when toggling on
              final picked = await showDatePicker(
                context: context,
                initialDate: _reminderDate ?? DateTime.now().add(const Duration(days: 1)),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) {
                setState(() {
                  _hasDate = true;
                  _reminderDate = picked;
                });
              }
            } else {
              setState(() {
                _hasDate = false;
                _reminderDate = null;
              });
            }
          }),
          _toggle(Icons.schedule_rounded, 'TIME', _hasTime, () => setState(() => _hasTime = !_hasTime)),
          _toggle(Icons.bolt_rounded, 'URGENT', _urgent, () => setState(() => _urgent = !_urgent)),
        ]),
      ),
      // Show selected date when DATE toggle is on
      if (_hasDate && _reminderDate != null)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.calendar_today, size: 18, color: AppTheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('REMINDER DATE', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary)),
                    Text(DateFormat('EEEE, MMM d, yyyy').format(_reminderDate!), style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _reminderDate ?? DateTime.now(),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setState(() => _reminderDate = picked);
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.edit, size: 16, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _toggle(IconData icon, String label, bool val, VoidCallback onTap) => Expanded(child: GestureDetector(onTap: onTap, child: Column(children: [
    const SizedBox(height: 12), Icon(icon, color: val ? AppTheme.primary : AppTheme.titaniumDark, size: 20),
    Text(label, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary)),
    const SizedBox(height: 8), Container(width: 36, height: 18, padding: const EdgeInsets.all(2), decoration: BoxDecoration(color: val ? AppTheme.primary : AppTheme.titaniumMid, borderRadius: BorderRadius.circular(10)), child: AnimatedAlign(alignment: val ? Alignment.centerRight : Alignment.centerLeft, duration: const Duration(milliseconds: 200), child: Container(width: 14, height: 14, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)))),
    const SizedBox(height: 12),
  ])));

  Widget _dropdown(String label, String val, List<String> items, ValueChanged<String?> onCh) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    decoration: BoxDecoration(
      color: AppTheme.titaniumLight,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: Colors.white.withOpacity(0.5), width: 0.5),
      boxShadow: [
        const BoxShadow(color: Colors.white, blurRadius: 4, offset: Offset(-2,-2)),
        BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2,2)),
      ]
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary)),
        DropdownButton<String>(
          value: val, 
          borderRadius: BorderRadius.circular(20), // CURVED EDGES FOR MENU
          items: items.map((e) => DropdownMenuItem(value: e, child: Text(e.toUpperCase(), style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w900)))).toList(), 
          onChanged: onCh, 
          isExpanded: true, 
          underline: const SizedBox(), 
          isDense: true, 
          icon: const Icon(Icons.expand_more_rounded, size: 18)
        ),
      ],
    ),
  );

  Widget _reminderWell() => Container(padding: const EdgeInsets.all(20), decoration: AppTheme.titaniumCardDecoration, child: Column(children: [
    Row(children: [const Icon(Icons.notifications_active_rounded, size: 18, color: AppTheme.primary), const SizedBox(width: 8), Text('EARLY REMINDER', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w900, color: AppTheme.primary))]),
    const SizedBox(height: 16), Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: AppTheme.titaniumDark.withOpacity(0.3), borderRadius: BorderRadius.circular(24)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [ _remDigit('YR', _remYr), _remDigit('MO', _remMo), _remDigit('DAY', _remDay), Container(width: 1, height: 30, color: Colors.white24), _remDigit('HR', _remHr), _remDigit('MIN', _remMin) ])),
  ]));

  Widget _remDigit(String l, int v) => GestureDetector(onTap: () => _pickRem(l.toLowerCase()), child: Column(children: [Text(l, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: AppTheme.primary)), Text(v.toString().padLeft(2,'0'), style: GoogleFonts.manrope(fontSize: 22, fontWeight: FontWeight.w900))]));

  void _pickRem(String type) async {
    int max = type == 'yr' ? 10 : type == 'mo' ? 12 : type == 'day' ? 31 : type == 'hr' ? 24 : 60;
    int cur = type == 'yr' ? _remYr : type == 'mo' ? _remMo : type == 'day' ? _remDay : type == 'hr' ? _remHr : _remMin;
    await showModalBottomSheet(context: context, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))), builder: (_) => Container(height: 250, decoration: const BoxDecoration(color: AppTheme.titaniumLight, borderRadius: BorderRadius.vertical(top: Radius.circular(32))), child: CupertinoPicker(itemExtent: 44, onSelectedItemChanged: (v) => setState(() { if(type=='yr')_remYr=v; else if(type=='mo')_remMo=v; else if(type=='day')_remDay=v; else if(type=='hr')_remHr=v; else _remMin=v; }), children: List.generate(max, (i) => Center(child: Text('$i', style: GoogleFonts.manrope(fontWeight: FontWeight.w900)))))));
  }

  Widget _assigneeWell() => GestureDetector(
    onTap: _pickUser, 
    child: Container(
      padding: const EdgeInsets.all(16), 
      decoration: BoxDecoration(
        color: AppTheme.titaniumLight, 
        borderRadius: BorderRadius.circular(24), 
        border: Border.all(color: Colors.white.withOpacity(0.5), width: 0.5), 
        boxShadow: [
          const BoxShadow(color: Colors.white, blurRadius: 4, offset: Offset(-2,-2)), 
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: Offset(2,2))
        ]
      ), 
      child: Row(
        children: [
          const Icon(Icons.person_add_rounded, color: AppTheme.primary), 
          const SizedBox(width: 12), 
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, 
              children: [
                Text('ASSIGN TO', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary)),
                Text(_userName ?? 'Select User', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w900))
              ]
            )
          ), 
          const Icon(Icons.arrow_drop_down_rounded)
        ]
      )
    )
  );

  void _pickUser() => showModalBottomSheet(
    context: context, 
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => Container(
      height: 450,
      decoration: const BoxDecoration(
        color: AppTheme.titaniumLight, 
        borderRadius: BorderRadius.vertical(top: Radius.circular(32))
      ), 
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.titaniumDark, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('ASSIGN TO', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 2.0)),
          ),
          Expanded(
            child: ListView(
              children: widget.users.map((u) => ListTile(
                leading: CircleAvatar(backgroundColor: AppTheme.primary.withOpacity(0.2), child: Text(u['username']?[0].toUpperCase() ?? 'U', style: const TextStyle(color: AppTheme.primary))),
                title: Text(u['username'] ?? '', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
                subtitle: Text((u['role'] ?? '').toString().toUpperCase(), style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.muted)),
                trailing: _userId == u['id'].toString() ? const Icon(Icons.check_circle, color: AppTheme.success, size: 22) : null,
                onTap: () { setState(() { _userId = u['id'].toString(); _userName = u['username']; }); Navigator.pop(context); }
              )).toList()
            ),
          ),
        ],
      )
    )
  );

  // Dependencies picker removed - replaced by Assign To (using _assigneeWell)

  void _handleSave() {
    if (_title.text.isEmpty) return;
    widget.onSave({
      'title': _title.text, 'notes': _notes.text, 'assigneeId': _userId ?? '', 'assigneeName': _userName ?? '',
      'isUrgent': _urgent, 'priority': _priority, 'repeatType': _repeat,
      'earlyReminder': '${_remYr}y${_remMo}m${_remDay}d${_remHr}h${_remMin}min',
      'hasDueDate': _hasDate,
      'reminderDate': _reminderDate?.toIso8601String(),
      'dependsOn': <String>[],
    });
  }
}
