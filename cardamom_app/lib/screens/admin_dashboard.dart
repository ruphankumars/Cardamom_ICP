import 'dart:io';
import 'dart:ui';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/analytics_service.dart';
import '../services/access_control_service.dart';
import '../services/navigation_service.dart';
import '../services/operation_queue.dart';
import '../services/sync_manager.dart';
import '../mixins/optimistic_action_mixin.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/status_indicator.dart';
import '../widgets/calendar_strip.dart';
import '../widgets/skeleton_loader.dart';
import '../widgets/donut_chart.dart';
import 'client_ledger_detail_screen.dart';
import '../widgets/segmented_tabs.dart';
import '../widgets/filter_chips.dart';
import '../widgets/transaction_list.dart';
import '../widgets/stock_forecast_card.dart';
import '../widgets/insight_card.dart';
import '../widgets/client_leaderboard.dart';
import '../widgets/demand_trends_card.dart';
import '../services/persistence_service.dart';
import '../services/cache_manager.dart';
import '../services/notification_service.dart';
import '../widgets/offline_indicator.dart';
import '../widgets/stock_accordion.dart';
import '../widgets/dismissible_bottom_sheet.dart';
import '../widgets/ai_briefing_card.dart';
import '../widgets/grade_grouped_dropdown.dart';
import '../models/task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_dashboard/widgets/mini_charts.dart';
import 'admin_dashboard/widgets/titanium_hero_card.dart';
import 'admin_dashboard/widgets/frosted_header.dart';
import 'admin_dashboard/widgets/titanium_nav_bar.dart';
import 'admin_dashboard/widgets/ghost_suggestion.dart';
import 'admin_dashboard/widgets/intent_prompt.dart';
import 'admin_dashboard/widgets/intelligence_card.dart';
import 'admin_dashboard/widgets/glass_carousel.dart';
import 'admin_dashboard/widgets/evening_summary_card.dart';

// Extracted widget modules (admin_dashboard refactoring)
import 'admin_dashboard/widgets/precision_tools_grid.dart';
import 'admin_dashboard/widgets/draggable_action_arc.dart';
import 'admin_dashboard/widgets/draggable_cart_button.dart';
import 'admin_dashboard/widgets/user_task_panel.dart';
import 'admin_dashboard/widgets/offline_indicator.dart';
import 'admin_dashboard/widgets/daily_cart_modal.dart';
import 'admin_dashboard/widgets/available_stock_modal.dart';
import 'admin_dashboard/widgets/request_details_popup.dart';
import 'admin_dashboard/controllers/dashboard_data_controller.dart';
import 'admin_dashboard/controllers/dashboard_animation_controller.dart';


class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> with TickerProviderStateMixin, RouteAware, OptimisticActionMixin {
  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();

  final ApiService _apiService = ApiService();
  final AnalyticsService _analyticsService = AnalyticsService();
  bool _isLoading = true;
  Map<String, dynamic>? _dashboardData;
  List<dynamic> _pendingOrders = [];
  List<dynamic> _todayCart = [];
  
  // Phase 3: Analytics data
  List<StockForecast> _stockForecasts = [];
  List<Insight> _insights = [];
  List<ClientScore> _clientScores = [];
  List<DemandTrend> _demandTrends = [];
  
  final PersistenceService _persistenceService = PersistenceService();
  DateTime? _lastSync;
  bool _isOffline = false;
  
  // V6: State tracking for advanced features
  num _previousSalesValue = 0;
  num _previousStockValue = 0;
  num _previousPendingValue = 0;
  int _lastMilestoneReached = 0; // Track ₹1L, ₹2L milestones
  DateTime _lastSyncTime = DateTime.now();
  int _pendingViewCount = 0; // Intent detection
  
  // Filters and Selection
  String _billingFilter = 'all';
  final Set<int> _selectedPackingIndices = {};
  final Set<int> _selectedUrgencyIndices = {};
  DateTime _selectedDate = DateTime.now(); // Calendar strip selection
  
  // Sticky Scroll Controllers
  final ScrollController _stockHeaderController = ScrollController();
  final ScrollController _stockBodyController = ScrollController();
  bool _isSyncingScroll = false;
  
  // Animation Controller for Background Blobs
  late AnimationController _bgAnimationController;
  late AnimationController _shimmerAnimationController;
  late AnimationController _pulseController;

  // V9: Floating Action Button Position
  Offset _fabPosition = const Offset(20, 100); 
  Offset _arcFabPosition = const Offset(300, 600); // Dedicated position for Thunder FAB

  // User Task Panel
  List<Task> _userTasks = [];
  bool _hasNewTasks = false;
  int _lastSeenTaskCount = 0;
  late AnimationController _notificationBlinkController;

  /// Navigate with page-access check. Shows "Access Restricted" dialog if denied.
  void _nav(String route, {Object? arguments, bool replacement = false}) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    AccessControlService.navigateWithAccessCheck(
      context, route, auth.pageAccess,
      arguments: arguments, replacement: replacement, userRole: auth.role,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCache();
    // Trigger background sync on dashboard load (after auth)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SyncManager>().syncAll();
    });
    _bgAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat(reverse: true);
    
    _shimmerAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _stockHeaderController.addListener(() {
      if (_isSyncingScroll) return;
      _isSyncingScroll = true;
      _stockBodyController.jumpTo(_stockHeaderController.offset);
      _isSyncingScroll = false;
    });
    _stockBodyController.addListener(() {
      if (_isSyncingScroll) return;
      _isSyncingScroll = true;
      _stockHeaderController.jumpTo(_stockBodyController.offset);
      _isSyncingScroll = false;
    });
    
    // Notification blink animation
    _notificationBlinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    
    _loadData();
    _loadUserTasks();
    
    // Start real-time notifications (WebSocket primary, polling fallback)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final auth = Provider.of<AuthProvider>(context, listen: false);
        final role = auth.role?.toLowerCase() ?? '';
        final userId = auth.userId ?? '';
        if (userId.isNotEmpty && (role == 'superadmin' || role == 'admin' || role == 'ops' || role == 'employee' || role == 'user')) {
          context.read<NotificationService>().initializeRealtime(userId: userId, role: role);
        }
      }
    });
  }

  Future<void> _loadCache() async {
    final cachedData = await _persistenceService.getDashboardData();
    final cachedAnalytics = await _persistenceService.getAnalyticsData();
    final lastSync = await _persistenceService.getLastSyncTime();

    if (cachedData != null && mounted) {
      setState(() {
        _dashboardData = cachedData['dashboard'];
        _pendingOrders = cachedData['pendingOrders'] ?? [];
        _todayCart = cachedData['todayCart'] ?? [];
        _lastSync = lastSync;
        _isLoading = false;
      });
    }

    if (cachedAnalytics != null && mounted) {
      setState(() {
        _stockForecasts = (cachedAnalytics['forecasts'] as List? ?? []).map((e) => StockForecast.fromJson(e)).toList();
        _insights = (cachedAnalytics['insights'] as List? ?? []).map((e) => Insight.fromJson(e)).toList();
        _clientScores = (cachedAnalytics['clients'] as List? ?? []).map((e) => ClientScore.fromJson(e)).toList();
        _demandTrends = (cachedAnalytics['trends'] as List? ?? []).map((e) => DemandTrend.fromJson(e)).toList();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _bgAnimationController.dispose();
    _shimmerAnimationController.dispose();
    _pulseController.dispose();
    _notificationBlinkController.dispose();
    _stockHeaderController.dispose();
    _stockBodyController.dispose();
    super.dispose();
  }

  @override
  void didPopNext() => _loadData();

  /// Show full request details popup (for admin to verify before approving)
  void _showRequestDetailsPopup(
    BuildContext context,
    ApprovalRequest request, {
    bool isAdmin = false,
    NotificationService? notifService,
    BuildContext? dialogContext,
  }) {
    final isDelete = request.actionType == 'delete';
    final actionColor = isDelete ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    final actionLabel = request.actionType.toUpperCase();
    
    // Format status color
    Color statusColor;
    String statusText;
    if (request.status == 'approved') {
      statusColor = const Color(0xFF10B981);
      statusText = 'APPROVED';
    } else if (request.status == 'rejected') {
      statusColor = const Color(0xFFEF4444);
      statusText = 'REJECTED';
    } else {
      statusColor = const Color(0xFFF59E0B);
      statusText = 'PENDING';
    }
    
    showDialog(
      context: dialogContext ?? context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          constraints: const BoxConstraints(maxHeight: 500),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: actionColor.withOpacity(0.1),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: actionColor.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isDelete ? Icons.delete_rounded : Icons.edit_rounded,
                        color: actionColor,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$actionLabel Request',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: actionColor),
                          ),
                          Text(
                            'From: ${request.requesterName}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(statusText, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor)),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              // Content
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Resource info
                      _buildDetailRow('Resource Type', request.resourceType.toUpperCase()),
                      _buildDetailRow('Resource ID', request.resourceId.toString()),
                      if (request.reason != null && request.reason!.isNotEmpty)
                        _buildDetailRow('Reason', request.reason!),
                      
                      if (request.resourceData != null) ...[
                        const SizedBox(height: 12),
                        const Text('CURRENT DATA:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _buildDataRows(request.resourceData!),
                          ),
                        ),
                      ],
                      
                      if (request.proposedChanges != null) ...[
                        const SizedBox(height: 12),
                        const Text('PROPOSED CHANGES:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF3B82F6))),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFBFDBFE)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _buildDataRows(request.proposedChanges!),
                          ),
                        ),
                      ],
                      
                      if (request.adminName != null) ...[
                        const SizedBox(height: 12),
                        _buildDetailRow('Processed By', request.adminName!),
                      ],
                      if (request.rejectReason != null && request.rejectReason!.isNotEmpty)
                        _buildDetailRow('Rejection Reason', request.rejectReason!),
                    ],
                  ),
                ),
              ),
              // Actions for admin (approve/reject buttons)
              if (isAdmin && request.status == 'pending' && notifService != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            // Show reject dialog
                            final reasonController = TextEditingController();
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (rctx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                title: const Text('Reject Request'),
                                content: TextField(
                                  controller: reasonController,
                                  decoration: InputDecoration(
                                    labelText: 'Reason (optional)',
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  maxLines: 2,
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(rctx, false), child: const Text('Cancel')),
                                  ElevatedButton(
                                    onPressed: () => Navigator.pop(rctx, true),
                                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                                    child: const Text('Reject'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true) {
                              final prefs = await SharedPreferences.getInstance();
                              final adminId = prefs.getString('userId') ?? '';
                              final adminName = prefs.getString('username') ?? 'Admin';
                              final reason = reasonController.text.isNotEmpty ? reasonController.text : 'No reason provided';
                              final success = await notifService.rejectRequest(request.id, adminId, adminName, reason);
                              if (success) notifService.removeApprovalRequest(request.id);
                            }
                          },
                          icon: const Icon(Icons.close, color: Color(0xFFEF4444)),
                          label: const Text('Reject', style: TextStyle(color: Color(0xFFEF4444))),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFFEF4444)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            final prefs = await SharedPreferences.getInstance();
                            final adminId = prefs.getString('userId') ?? '';
                            final adminName = prefs.getString('username') ?? 'Admin';
                            final success = await notifService.approveRequest(request.id, adminId, adminName);
                            if (success) {
                              notifService.removeApprovalRequest(request.id);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('✅ Request approved'), backgroundColor: Color(0xFF10B981)),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.check),
                          label: const Text('Approve'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF0F172A)))),
        ],
      ),
    );
  }

  List<Widget> _buildDataRows(Map<String, dynamic> data) {
    return data.entries.map((e) {
      final value = e.value;
      String displayValue;
      if (value == null) {
        displayValue = '-';
      } else if (value is Map || value is List) {
        displayValue = value.toString();
      } else {
        displayValue = value.toString();
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 80,
              child: Text(e.key, style: const TextStyle(fontSize: 10, color: Color(0xFF64748B))),
            ),
            Expanded(child: Text(displayValue, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500))),
          ],
        ),
      );
    }).toList();
  }
  // Load user's assigned tasks
  Future<void> _loadUserTasks() async {
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      debugPrint('🔍 _loadUserTasks - auth.userId: ${auth.userId}');
      debugPrint('🔍 _loadUserTasks - auth.role: ${auth.role}');
      
      if (auth.userId == null) {
        debugPrint('🔍 _loadUserTasks - userId is null, returning');
        return;
      }
      
      final res = await _apiService.getTasks(assigneeId: auth.userId);
      debugPrint('🔍 _loadUserTasks - API response: ${res.data}');
      
      final rawData = res.data;
      final taskList = rawData is List ? rawData : (rawData is Map ? (rawData['tasks'] ?? rawData['data'] ?? []) : []);
      final tasks = (taskList as List).map((t) => Task.fromJson(t)).toList();
      debugPrint('🔍 _loadUserTasks - Parsed ${tasks.length} tasks');
      
      // Check for new tasks
      final prefs = await SharedPreferences.getInstance();
      final lastCount = prefs.getInt('lastSeenTaskCount_${auth.userId}') ?? 0;
      
      if (!mounted) return;
      setState(() {
        _userTasks = tasks;
        _hasNewTasks = tasks.length > lastCount;
        _lastSeenTaskCount = lastCount;
      });
      debugPrint('🔍 _loadUserTasks - Set ${_userTasks.length} tasks in state');
    } catch (e, stackTrace) {
      debugPrint('❌ Error loading user tasks: $e');
      debugPrint('❌ Stack trace: $stackTrace');
    }
  }

  // Mark tasks as seen
  void _markTasksAsSeen() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.userId == null) return;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lastSeenTaskCount_${auth.userId}', _userTasks.length);
    
    if (!mounted) return;
    setState(() {
      _hasNewTasks = false;
      _lastSeenTaskCount = _userTasks.length;
    });
  }

  // Mark task as complete
  Future<void> _markTaskComplete(Task task) async {
    try {
      await _apiService.updateTask(task.id, {'status': 'completed'});
      await _loadUserTasks();
      HapticFeedback.mediumImpact();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Task "${task.title}" completed!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error marking task complete: $e');
    }
  }

  // Build User Task Panel Widget
  Widget _buildUserTaskPanel() {
    final ongoingTasks = _userTasks.where((t) => t.status == TaskStatus.ongoing).toList();
    final pendingTasks = _userTasks.where((t) => t.status == TaskStatus.pending).toList();
    final activeTasks = [...ongoingTasks, ...pendingTasks];
    
    if (activeTasks.isEmpty) {
      return const SizedBox.shrink();
    }
    
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5D6E7E).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.task_alt, color: Color(0xFF5D6E7E), size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'My Tasks',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1A1A1A),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: ongoingTasks.isNotEmpty 
                          ? Colors.orange.withOpacity(0.15)
                          : Colors.blue.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${activeTasks.length} active',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: ongoingTasks.isNotEmpty ? Colors.orange[700] : Colors.blue[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            // Task List - Scrollable
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                itemCount: activeTasks.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final task = activeTasks[index];
                  final isOngoing = task.status == TaskStatus.ongoing;
                  
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isOngoing 
                          ? Colors.orange.withOpacity(0.08)
                          : Colors.grey.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isOngoing 
                            ? Colors.orange.withOpacity(0.3)
                            : Colors.grey.withOpacity(0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        // Status indicator
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: isOngoing ? Colors.orange : Colors.blue,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 12),
                        
                        // Task info - 2 lines
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                task.title,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF1A1A1A),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  if (task.dueDate != null) ...[
                                    Icon(Icons.schedule, size: 12, color: Colors.grey[500]),
                                    const SizedBox(width: 4),
                                    Text(
                                      DateFormat('MMM d').format(task.dueDate!),
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  if (task.priority != 'none') ...[
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: _getPriorityColor(task.priority).withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        task.priority.toUpperCase(),
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w600,
                                          color: _getPriorityColor(task.priority),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        
                        // Complete button
                        GestureDetector(
                          onTap: () => _markTaskComplete(task),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.check_circle_outline,
                              color: Colors.green,
                              size: 20,
                            ),
                          ),
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

  Color _getPriorityColor(String priority) {
    switch (priority.toLowerCase()) {
      case 'high':
        return Colors.red;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  /// Sort orders by daysSinceOrder descending (oldest/most urgent first)
  List<dynamic> _sortByUrgency(List<dynamic> orders) {
    final sorted = List<dynamic>.from(orders);
    sorted.sort((a, b) {
      final daysA = (a is Map ? (a['daysSinceOrder'] ?? 0) : 0) as num;
      final daysB = (b is Map ? (b['daysSinceOrder'] ?? 0) : 0) as num;
      return daysB.compareTo(daysA);
    });
    return sorted;
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final cacheManager = context.read<CacheManager>();
      final result = await cacheManager.fetchWithCache<Map<String, dynamic>>(
        apiCall: () async {
          final response = await _apiService.getDashboard();
          final pendingResponse = await _apiService.getPendingOrders();
          final cartResponse = await _apiService.getTodayCart();
          return {
            'dashboard': response.data,
            'pendingOrders': pendingResponse.data,
            'todayCart': cartResponse.data,
          };
        },
        cache: cacheManager.dashboardCache,
      );

      if (!mounted) return;

      final data = result.data;

      // V6: Store previous values for breathing metrics animation
      final oldSales = _dashboardData?['todaySalesVal'] ?? 0;
      final oldStock = _dashboardData?['totalStock'] ?? 0;
      final oldPending = _dashboardData?['pendingQty'] ?? 0;

      setState(() {
        _previousSalesValue = oldSales is num ? oldSales : (num.tryParse('$oldSales') ?? 0);
        _previousStockValue = oldStock is num ? oldStock : (num.tryParse('$oldStock') ?? 0);
        _previousPendingValue = oldPending is num ? oldPending : (num.tryParse('$oldPending') ?? 0);

        _dashboardData = data['dashboard'] is Map ? Map<String, dynamic>.from(data['dashboard']) : null;
        _pendingOrders = data['pendingOrders'] is List ? List.from(data['pendingOrders']) : [];
        _todayCart = data['todayCart'] is List ? List.from(data['todayCart']) : [];
        _lastSyncTime = DateTime.now();
        _isLoading = false;
        _isOffline = result.fromCache;
        _lastSync = DateTime.now();
      });

      // Also save to legacy PersistenceService for backward compatibility
      if (!result.fromCache) {
        await _persistenceService.saveDashboardData(data);
      }

      // V6: Check for revenue milestones and trigger haptic feedback
      _checkRevenueMilestone();

      // Phase 3: Load analytics data in background (non-blocking)
      if (!result.fromCache) {
        _loadAnalyticsData();
      }

    } catch (e) {
      debugPrint('Error loading dashboard: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isOffline = true;
        });
      }
    }
  }
  
  Map<String, dynamic> _getDateStats(DateTime date) {
    final dateStr = '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${(date.year % 100).toString().padLeft(2, '0')}';
    final isoStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    // Count pending orders for this date
    int orderCount = 0;
    for (final o in _pendingOrders) {
      final od = o is Map ? (o['orderDate'] ?? '').toString() : '';
      if (od == dateStr || od == isoStr || od.startsWith(isoStr)) orderCount++;
    }

    // Count packed and revenue for this date
    int packedCount = 0;
    double revenue = 0;
    for (final c in _todayCart) {
      final pd = c is Map ? (c['packedDate'] ?? '').toString() : '';
      if (pd == dateStr || pd == isoStr || pd.startsWith(isoStr)) {
        packedCount++;
        final kgs = (c is Map ? (num.tryParse('${c['kgs']}') ?? 0) : 0).toDouble();
        final price = (c is Map ? (num.tryParse('${c['price']}') ?? 0) : 0).toDouble();
        revenue += kgs * price;
      }
    }

    return {
      'orders': orderCount,
      'packed': packedCount,
      'revenue': revenue > 0 ? '${(revenue / 1000).toStringAsFixed(1)}k' : '0',
    };
  }

  // Phase 3 & 4: Load analytics data
  Future<void> _loadAnalyticsData() async {
    try {
      final forecastResult = await _analyticsService.getStockForecast();
      final insightsResult = await _analyticsService.getProactiveInsights();
      final clientsResult = await _analyticsService.getClientScores();
      final trendsResult = await _analyticsService.getDemandTrends();
      
      if (!mounted) return;
      
      setState(() {
        _stockForecasts = forecastResult.forecasts;
        _insights = insightsResult.insights;
        _clientScores = clientsResult.clients;
        _demandTrends = trendsResult.trends;
      });

      // Cache analytics data
      await _persistenceService.saveAnalyticsData({
        'forecasts': forecastResult.forecasts.map((e) => e.toJson()).toList(),
        'insights': insightsResult.insights.map((e) => e.toJson()).toList(),
        'clients': clientsResult.clients.map((e) => e.toJson()).toList(),
        'trends': trendsResult.trends.map((e) => e.toJson()).toList(),
      });

    } catch (e) {
      debugPrint('Error loading analytics: $e');
    }
  }
  
  // V6: Haptic feedback on revenue milestones
  void _checkRevenueMilestone() {
    final salesVal = _dashboardData?['todaySalesVal'];
    final salesNum = salesVal is num ? salesVal : (num.tryParse('$salesVal') ?? 0);
    final lakhs = (salesNum / 100000).floor();
    
    if (lakhs > _lastMilestoneReached && lakhs > 0) {
      _lastMilestoneReached = lakhs;
      HapticFeedback.heavyImpact();
    }
  }
  
  // V6: Get background gradient based on business state
  List<Color> _getBusinessStateGradient() {
    final pendingQty = _dashboardData?['pendingQty'] ?? 0;
    final packedKgs = _dashboardData?['todayPackedKgs'] ?? 0;
    final totalStock = _dashboardData?['totalStock'] ?? 0;
    
    final pendingNum = pendingQty is num ? pendingQty : (num.tryParse('$pendingQty') ?? 0);
    final packedNum = packedKgs is num ? packedKgs : (num.tryParse('$packedKgs') ?? 0);
    final stockNum = totalStock is num ? totalStock : (num.tryParse('$totalStock') ?? 0);
    
    // Critical: Stock very low
    if (stockNum < 1000) {
      return [const Color(0xFFFEE2E2), const Color(0xFFFECACA), const Color(0xFFFEF2F2)]; // Red tint
    }
    // Warning: Pending > Packed
    if (pendingNum > packedNum && pendingNum > 0) {
      return [const Color(0xFFFEF3C7), const Color(0xFFFDE68A), const Color(0xFFFFFBEB)]; // Amber tint
    }
    // Good: All orders flowing
    if (packedNum > 0 && pendingNum == 0) {
      return [const Color(0xFFD1FAE5), const Color(0xFFA7F3D0), const Color(0xFFECFDF5)]; // Green tint
    }
    // Default: Neutral
    return [const Color(0xFFF1F5F9), const Color(0xFFE2E8F0), const Color(0xFFF8FAFC)];
  }

  // V6: Calculate hours elapsed in business day (8AM - 8PM)
  double _getHoursElapsed() {
    final now = DateTime.now();
    final hour = now.hour;
    if (hour < 8) return 0.5; // Avoid division by zero
    if (hour >= 20) return 12;
    return (hour - 8) + (now.minute / 60);
  }

  // V6: Intent Detection logic
  void _onPendingViewed() {
    setState(() {
      _pendingViewCount++;
    });
    if (_pendingViewCount == 3) {
      HapticFeedback.mediumImpact();
    }
  }

  // V6: Ghost Suggestion Widget - delegated to extracted widget
  Widget _buildGhostSuggestion({required String grade, required String suggestion}) {
    return GestureDetector(
      onTap: _showNetStockDragPopup,
      child: GhostSuggestion(grade: grade, suggestion: suggestion),
    );
  }

  // V6: Intent detection prompt - delegated to extracted widget
  Widget _buildIntentPrompt() {
    return IntentPrompt(onStartNow: _showPendingDragPopup);
  }

  bool _isArcExpanded = false;

  Widget _buildDraggableActionArc() {
    // Position from bottom-right so arc expands upward
    return Positioned(
      right: 20,
      bottom: 100, // Above bottom nav
      child: Draggable(
        feedback: Material(color: Colors.transparent, child: _buildActionArc(isDragging: true)),
        childWhenDragging: const SizedBox.shrink(),
        onDragEnd: (details) {
          setState(() {
            _arcFabPosition = details.offset;
          });
        },
        child: _buildActionArc(),
      ),
    );
  }

  Widget _buildActionArc({bool isDragging = false}) {
    // Column with FAB at bottom, arc items above - mainAxisAlignment.end makes it grow upward
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.center,
      verticalDirection: VerticalDirection.up, // This makes items expand UPWARD
      children: [
        // FAB button - will be at bottom due to verticalDirection.up
        Container(
          margin: EdgeInsets.only(bottom: isDragging ? 0 : 0),
          child: FloatingActionButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              setState(() => _isArcExpanded = !_isArcExpanded);
            },
            backgroundColor: AppTheme.titaniumMid,
            elevation: 6,
            shape: const CircleBorder(),
            child: Container(
              width: 56, height: 56,
              decoration: AppTheme.machinedDecoration,
              child: AnimatedRotation(
                turns: _isArcExpanded ? 0.125 : 0,
                duration: const Duration(milliseconds: 300),
                child: Icon(
                  _isArcExpanded ? Icons.close : Icons.bolt_rounded,
                  color: AppTheme.primary,
                ),
              ),
            ),
          ),
        ),
        // Arc items - will expand ABOVE the FAB due to verticalDirection.up
        if (_isArcExpanded) ...[
          const SizedBox(height: 16),
          AnimatedOpacity(
            opacity: _isArcExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: Builder(
              builder: (ctx) {
                final arcRole = Provider.of<AuthProvider>(ctx, listen: false).role?.toLowerCase() ?? '';
                final arcIsAdmin = arcRole == 'superadmin' || arcRole == 'admin' || arcRole == 'ops';
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildArcItem(Icons.local_shipping_rounded, 'Dispatch', AppTheme.steelBlue, () => _nav('/add_to_cart')),
                    if (arcIsAdmin) ...[
                      const SizedBox(height: 12),
                      _buildArcItem(Icons.bar_chart_rounded, 'Reports', AppTheme.primary, () => _nav('/reports')),
                      const SizedBox(height: 12),
                      _buildArcItem(Icons.account_balance_wallet_rounded, 'Outstanding', const Color(0xFFEF4444), () => _nav('/outstanding')),
                      const SizedBox(height: 12),
                      _buildArcItem(Icons.history_rounded, 'Audit Trail', AppTheme.primary, () => Navigator.pushNamed(context, '/audit_trail')),
                      const SizedBox(height: 12),
                      _buildArcItem(Icons.inventory_2_rounded, 'Stock', AppTheme.primary, _showNetStockDragPopup),
                      const SizedBox(height: 12),
                      _buildArcItem(Icons.add_shopping_cart, 'Order', AppTheme.steelBlue, () => _nav('/new_order')),
                      const SizedBox(height: 12),
                      _buildArcItem(Icons.lightbulb_outline_rounded, 'Insights', const Color(0xFFF59E0B), () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('See insights on dashboard!'), duration: Duration(seconds: 2)),
                        );
                      }),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildArcItem(IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        onTap();
        setState(() => _isArcExpanded = false);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44, height: 44,
            decoration: AppTheme.machinedDecoration,
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.manrope(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: AppTheme.title, // Dark color for visibility
              shadows: [BoxShadow(color: Colors.white.withOpacity(0.8), blurRadius: 2, offset: const Offset(0, 0))],
            ),
          ),
        ],
      ),
    );
  }

  // V6: Breathing Metrics helper widget
  Widget _buildAnimatedCounter({
    required num begin,
    required num end,
    required String Function(double value) formatter,
    required TextStyle style,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: begin.toDouble(), end: end.toDouble()),
      duration: const Duration(seconds: 1),
      curve: Curves.easeOutExpo,
      builder: (_, value, __) => Text(formatter(value), style: style),
    );
  }

  
  // Interaction Handlers
  void _showDailyCartModal() {
    showDialog(
      context: context,
      builder: (context) => _DailyCartDialog(
        todayCart: _todayCart,
        onCancelDispatch: (lot, client) {
          Navigator.pop(context);
          fireAndForget(
            type: 'cancel_dispatch',
            apiCall: () => _apiService.cancelPartialDispatch(lot, client),
            successMessage: 'Dispatch cancelled successfully',
            failureMessage: 'Failed to cancel dispatch',
            onSuccess: () => _loadData(),
          );
        },
      ),
    );
  }

  void _showAvailableStockModal() {
    // Calculate locally like we did for cards
    final netStock = _dashboardData?['netStock'] ?? {};
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    final availableItems = <Map<String, dynamic>>[];
    
    for (var row in rows) {
      if (row is List) {
        if (row.isEmpty) continue;
        for (int i = 1; i < row.length; i++) {
          if (i < headers.length) {
             if (absGrades.contains(headers[i])) {
               final cellValue = row[i];
               final val = cellValue is num 
                   ? cellValue.toDouble() 
                   : (num.tryParse(cellValue?.toString() ?? '0') ?? 0);
               if (val > 0) {
                 availableItems.add({'grade': headers[i], 'value': val});
               }
             }
          }
        }
      } else if (row is Map) {
        final values = row['values'];
        if (values is List) {
          for (int i = 0; i < values.length && i < headers.length; i++) {
            if (absGrades.contains(headers[i])) {
              final cellValue = values[i];
              final val = cellValue is num 
                  ? cellValue.toDouble() 
                  : (num.tryParse(cellValue?.toString() ?? '0') ?? 0);
              if (val > 0) {
                availableItems.add({'grade': headers[i], 'value': val});
              }
            }
          }
        }
      }
    }
    // Aggregate by grade
    final aggregated = <String, double>{};
    for (var item in availableItems) {
      aggregated[item['grade']] = (aggregated[item['grade']] ?? 0) + item['value'];
    }
    
    showDialog(
      context: context,
      builder: (context) => _AvailableStockDialog(stockMap: aggregated),
    );
  }

  void _showPendingOrdersModal() {
    showDialog(
      context: context,
      builder: (context) => _PendingOrdersDialog(pendingOrders: _pendingOrders),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return AppShell(
      title: 'Grand Operations Dashboard',
      subtitle: 'Net stock, orders, sales, allocation & alerts in one scrollable view.',
      disableInternalScrolling: true,
      showAppBar: false,
      showBottomNav: false,
      topActions: [
        _buildTopButton(
          label: 'Dashboard',
          onPressed: () => Navigator.pushReplacementNamed(context, '/admin_dashboard'),
          color: const Color(0xFF5D6E7E),
        ),
        const SizedBox(width: 8),
        _buildTopButton(
          label: '📨 Order Request',
          onPressed: () => _nav('/order_requests'),
          gradient: const LinearGradient(
            colors: [Color(0xFF4A5568), Color(0xFF4A5568)],
          ),
        ),
        const SizedBox(width: 8),
        _buildTopButton(
          label: '⚙️ Recalculate Stocks (Delta)',
          onPressed: () {
            fireAndForget(
              type: 'recalc_stock',
              apiCall: () => _apiService.recalcStock(),
              successMessage: 'Stock recalculated successfully',
              failureMessage: 'Failed to recalculate stock',
              onSuccess: () => _loadData(),
            );
          },
          color: const Color(0xFF10B981),
        ),
        const SizedBox(width: 8),
        _buildTopButton(
          label: '💰 Outstanding',
          onPressed: () => _nav('/outstanding'),
          color: const Color(0xFFEF4444),
        ),
        const SizedBox(width: 8),
        _buildTopButton(
          label: '⚙️ Admin',
          onPressed: () => _nav('/admin'),
          color: const Color(0xFF5D6E7E),
        ),
        const SizedBox(width: 8),
        _buildTopButton(
          label: '🚪 Logout',
          onPressed: () {
            Provider.of<AuthProvider>(context, listen: false).logout();
            Navigator.pushReplacementNamed(context, '/login');
          },
          color: const Color(0xFFEF4444),
        ),
      ],
      content: _isLoading
          ? const DashboardSkeleton()
          : Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB)],
                ),
              ),
              child: Stack(
                fit: StackFit.loose,
                children: [
                  Builder(
                    builder: (context) {
                      final screenWidth = MediaQuery.of(context).size.width;
                      final isMobile = screenWidth < 600;
                      final horizontalPadding = isMobile ? 0.0 : 24.0; // Mobile padding handled inside layouts
                      
                      return Stack(
                        children: [
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 16),
                            child: screenWidth < 900
                              ? _buildMobileLayout()
                              : _buildDesktopLayout(),
                          ),
                          if (_selectedUrgencyIndices.isNotEmpty)
                            _buildDraggableCartButton(),
                          // V11: Floating Bottom Nav
                          if (isMobile) _buildTitaniumNavBar(),
                          if (isMobile) _buildDraggableActionArc(),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
      floatingActionButton: null, // Moved to internal Stack for free dragging
    );
  }

  Widget _buildDraggableCartButton() {
    return Positioned(
      left: _fabPosition.dx,
      top: _fabPosition.dy,
      child: Draggable(
        feedback: _buildCartFab(isDragging: true),
        childWhenDragging: const SizedBox.shrink(),
        onDragEnd: (details) {
          setState(() {
            // Constrain FAB to screen bounds roughly
            double x = details.offset.dx;
            double y = details.offset.dy;
            final size = MediaQuery.of(context).size;
            x = x.clamp(10, size.width - 70);
            y = y.clamp(10, size.height - 150);
            _fabPosition = Offset(x, y);
          });
        },
        child: _buildCartFab(),
      ),
    );
  }

  Widget _buildCartFab({bool isDragging = false}) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _sendSelectedToCart,
        child: Container(
          width: 60, height: 60,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF4A5568)]),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF5D6E7E).withOpacity(0.4),
                blurRadius: isDragging ? 20 : 12,
                offset: const Offset(0, 4),
              ),
            ],
            border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.shopping_cart_checkout_rounded, color: Colors.white, size: 28),
              Positioned(
                right: 12, top: 12,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                  child: Text(
                    '${_selectedUrgencyIndices.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _sendSelectedToCart() {
    HapticFeedback.heavyImpact();

    final selectedItems = _selectedUrgencyIndices.map((idx) {
      return _pendingOrders.where((o) {
        final oIdx = o['index'] is int ? o['index'] : (int.tryParse(o['index']?.toString() ?? '') ?? -1);
        return oIdx == idx;
      }).firstOrNull;
    }).whereType<Map<String, dynamic>>().toList();

    if (selectedItems.isEmpty) return;

    final previousIndices = Set<int>.from(_selectedUrgencyIndices);

    optimistic(
      type: 'add_to_cart',
      applyLocal: () => setState(() => _selectedUrgencyIndices.clear()),
      apiCall: () => _apiService.addToCart(selectedItems),
      rollback: () => setState(() => _selectedUrgencyIndices.addAll(previousIndices)),
      successMessage: '${selectedItems.length} orders sent to daily cart!',
      failureMessage: 'Failed to add orders to cart. Reverted.',
      onSuccess: () => _loadData(),
    );
  }



  // Desktop layout - keeps all sections expanded
  Widget _buildDesktopLayout() {
    final allocatorHint = _dashboardData?['allocatorHint'];
    final hour = DateTime.now().hour;
    final isEveningMode = hour >= 18;
    final stockVal = _dashboardData?['totalStock'] ?? 0;
    final stockNum = stockVal is num ? stockVal : (num.tryParse('$stockVal') ?? 0);

    // Role-based visibility for desktop
    final deskRole = Provider.of<AuthProvider>(context, listen: false).role?.toLowerCase() ?? '';
    final isAdminRole = deskRole == 'superadmin' || deskRole == 'admin' || deskRole == 'ops';

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── TOP PANEL: Hero Metric Cards ──
        _buildHeroGrid(),
        const SizedBox(height: 20),

        // ── AI BRIEFING ── Admin only
        if (isAdminRole) ...[
          const AiBriefingCard(),
          const SizedBox(height: 20),
        ],

        // ── QUICK ACTIONS BAR ──
        if (isAdminRole) ...[
          _buildQuickActionsBar(),
          const SizedBox(height: 24),
        ],

        // ── SALES & ORDERS ──
        _buildSalesSnapshot(),
        const SizedBox(height: 24),

        // ── SIDE-BY-SIDE: Insights + Alerts ── Admin only
        if (isAdminRole) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _buildInsightsSection(),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (allocatorHint != null) ...[
                      _buildDesktopIntelligenceSection(allocatorHint),
                      const SizedBox(height: 20),
                    ],
                    _buildDesktopAlertsSection(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],

        // ── LIVE STOCK INVENTORY ──
        _buildStockSection(),
        const SizedBox(height: 24),

        // ── ALLOCATION ── Admin only
        if (isAdminRole) ...[
          _buildAllocationSection(),
          const SizedBox(height: 24),
        ],

        // ── FORECASTS & TRENDS ── Admin only
        if (isAdminRole && (_stockForecasts.isNotEmpty || _demandTrends.isNotEmpty))
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_stockForecasts.isNotEmpty)
                Expanded(
                  child: StockForecastCard(
                    forecasts: _stockForecasts,
                    onRefresh: _loadAnalyticsData,
                    onTap: () => _nav('/stock_tools'),
                  ),
                ),
              if (_stockForecasts.isNotEmpty && _demandTrends.isNotEmpty)
                const SizedBox(width: 20),
              if (_demandTrends.isNotEmpty)
                Expanded(
                  child: DemandTrendsCard(
                    trends: _demandTrends,
                    onRefresh: _loadAnalyticsData,
                  ),
                ),
            ],
          ),
        if (isAdminRole && (_stockForecasts.isNotEmpty || _demandTrends.isNotEmpty))
          const SizedBox(height: 24),

        // ── ADMIN MAINTENANCE ── Admin only
        if (isAdminRole) ...[
          _buildAdminMaintenanceSection(),
          const SizedBox(height: 24),
        ],

        // ── GHOST SUGGESTION (low stock) ──
        if (stockNum < 2000) ...[
          _buildGhostSuggestion(grade: 'AGEB', suggestion: 'AGEB1'),
          const SizedBox(height: 20),
        ],

        // ── EVENING SUMMARY (after 6 PM) ── Admin only
        if (isAdminRole && isEveningMode) ...[
          _buildDesktopEveningSummary(),
          const SizedBox(height: 24),
        ],

        const SizedBox(height: 60),
      ],
    ),
    );
  }

  // ── Desktop-specific wrapper: Intelligence section ──
  Widget _buildDesktopIntelligenceSection(dynamic hint) {
    final recommendations = <Map<String, dynamic>>[];
    if (hint is Map) {
      if (hint['recommendation'] != null) {
        recommendations.add({'icon': '🎯', 'label': 'RECOMMENDATION', 'text': hint['recommendation'].toString()});
      }
      if (hint['brandVelocity'] != null) {
        recommendations.add({'icon': '🚀', 'label': 'BRAND VELOCITY', 'text': hint['brandVelocity'].toString()});
      }
      if (hint['lotPerformance'] != null) {
        recommendations.add({'icon': '📊', 'label': 'LOT PERFORMANCE', 'text': hint['lotPerformance'].toString()});
      }
    } else if (hint is String) {
      recommendations.add({'icon': '✨', 'label': 'INTELLIGENCE', 'text': hint});
    }
    if (recommendations.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: AppTheme.glassDecoration,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.auto_awesome, size: 18, color: Color(0xFF6366F1)),
            SizedBox(width: 8),
            Text('INTELLIGENCE', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF4A5568), letterSpacing: 0.5)),
          ]),
          const SizedBox(height: 16),
          ...recommendations.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r['icon'] as String, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r['label'] as String, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.8)),
                    const SizedBox(height: 2),
                    Text(r['text'] as String, style: const TextStyle(fontSize: 13, color: Color(0xFF374151), height: 1.4)),
                  ],
                )),
              ],
            ),
          )),
        ],
      ),
    );
  }

  // ── Desktop-specific wrapper: Alerts section ──
  Widget _buildDesktopAlertsSection() {
    final netStock = _dashboardData?['netStock'] ?? {};
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);

    List<Map<String, dynamic>> negativeGrades = [];
    List<Map<String, dynamic>> lowGrades = [];

    for (var row in rows) {
      List<dynamic> values = row is List ? row : (row is Map ? row['values'] ?? [] : []);
      String rowType = row is List ? (values.isNotEmpty ? values[0]?.toString() ?? '' : '') : (row['type']?.toString() ?? '');
      for (int i = 1; i < values.length && i < headers.length; i++) {
        if (absGrades.contains(headers[i])) {
          final val = values[i] is num ? values[i] : (num.tryParse(values[i]?.toString() ?? '0') ?? 0);
          if (val < 0) negativeGrades.add({'grade': headers[i], 'type': rowType, 'value': val});
          else if (val < 50 && val >= 0) lowGrades.add({'grade': headers[i], 'type': rowType, 'value': val});
        }
      }
    }

    final hasIssues = negativeGrades.isNotEmpty || lowGrades.isNotEmpty;
    final accentColor = hasIssues ? Colors.red : const Color(0xFF10B981);

    return Container(
      decoration: AppTheme.glassDecoration,
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(hasIssues ? Icons.warning_amber_rounded : Icons.check_circle_rounded, color: accentColor, size: 20),
          const SizedBox(width: 8),
          Text(hasIssues ? 'STOCK ALERTS' : 'ALL SYSTEMS HEALTHY', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: accentColor, letterSpacing: 0.5)),
        ]),
        const SizedBox(height: 12),
        if (!hasIssues)
          const Text('No stock issues detected.', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)))
        else ...[
          if (negativeGrades.isNotEmpty)
            _buildDesktopAlertRow('Negative Stock', '${negativeGrades.length} grades', Colors.red,
                negativeGrades.take(4).map((e) => '${e['grade']}: ${(e['value'] as num).round()}kg').join(', ')),
          if (lowGrades.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildDesktopAlertRow('Low Stock (<50kg)', '${lowGrades.length} grades', Colors.orange,
                lowGrades.take(4).map((e) => '${e['grade']}: ${(e['value'] as num).round()}kg').join(', ')),
          ],
        ],
      ]),
    );
  }

  Widget _buildDesktopAlertRow(String title, String count, Color color, String details) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Row(children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            const Spacer(),
            Text(count, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
          ]),
          const SizedBox(height: 2),
          Text(details, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        ])),
      ]),
    );
  }

  // ── Desktop-specific: Evening summary ──
  Widget _buildDesktopEveningSummary() {
    return Container(
      decoration: AppTheme.glassDecoration,
      padding: const EdgeInsets.all(20),
      child: Row(children: [
        const Icon(Icons.nightlight_round, size: 20, color: Color(0xFF6366F1)),
        const SizedBox(width: 12),
        const Text('DAILY SUMMARY', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF4A5568), letterSpacing: 0.5)),
        const Spacer(),
        Text('Sales: ₹${(((_dashboardData?['todaySalesVal'] ?? 0) is num ? (_dashboardData?['todaySalesVal'] ?? 0) : (num.tryParse('${_dashboardData?['todaySalesVal']}') ?? 0)) / 100000).toStringAsFixed(2)}L', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
        const SizedBox(width: 24),
        Text('Packed: ${_dashboardData?['todayPackedKgs'] ?? 0} kg', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
        const SizedBox(width: 24),
        Text('Orders: ${_dashboardData?['todayPackedCount'] ?? 0}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
      ]),
    );
  }

  // Mobile layout V5 - "Neumorphic Glass Fusion"
  // Concept: V3 Neumorphic depth + V4 Monolithic flow + Light Glass palette
  // Palette: Frosted white (#F8FAFC), Soft Indigo (#6366F1), Slate (#64748B)
  Widget _buildMobileLayout() {
    final totalSales = _dashboardData?['todaySalesVal'] ?? 0;
    final totalStock = _dashboardData?['totalStock'] ?? 0;
    final pendingQty = _dashboardData?['pendingQty'] ?? 0;
    final packedKgs = _dashboardData?['todayPackedKgs'] ?? 0;
    final packedCount = _dashboardData?['todayPackedCount'] ?? 0;
    final allocatorHint = _dashboardData?['allocatorHint'];

    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good Morning' : (hour < 17 ? 'Good Afternoon' : 'Good Evening');
    final isEveningMode = hour >= 18; // V6: Time-morphing layout

    // V6: Pulse detection
    final stockVal = _dashboardData?['totalStock'] ?? 0;
    final stockNum = stockVal is num ? stockVal : (num.tryParse('$stockVal') ?? 0);

    // Role-based visibility: admin/ops/superadmin see everything, employees see limited
    final role = Provider.of<AuthProvider>(context, listen: false).role?.toLowerCase() ?? '';
    final isAdminRole = role == 'superadmin' || role == 'admin' || role == 'ops';
    final isStockLow = stockNum < 10000; // 20% of 50k target
    
    // Note: Removed Scaffold wrapper to avoid nesting inside AppShell's Scaffold
    // floatingActionButton is now passed to AppShell via the build() method
    // Removed business-state gradient - let AppShell's gradient show through
    return RefreshIndicator(
      onRefresh: () async {
        HapticFeedback.mediumImpact();
        await _loadData();
      },
      color: const Color(0xFF5D6E7E),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            // V11: Top Bar from Ref 1
            _buildFrostedHeader(greeting),
            
            // V11: Titanium Hero Card
            _buildTitaniumHeroCard(greeting, totalStock, pendingQty),
            const SizedBox(height: 16),

            // 📋 User Task Panel - Show for both 'user' and 'admin' roles
            if (['user', 'admin', 'superadmin', 'ops', 'employee'].contains(Provider.of<AuthProvider>(context, listen: false).role?.toLowerCase()))
              _buildUserTaskPanel(),

            // 🧠 AI Brain: Daily Intelligence Briefing - Admin only
            if (isAdminRole) ...[
              const AiBriefingCard(),
              const SizedBox(height: 16),
            ],

            // V11: Precision Tools Header
            _buildSectionHeader('PRECISION TOOLS'),

            // V11: Machined Action Grid - filtered by role
            isAdminRole ? _buildPrecisionTools() : _buildEmployeePrecisionTools(),
            const SizedBox(height: 32),

            // V11: Pending Orders Area
            _buildPendingOrdersUrgencyPanel(),
            const SizedBox(height: 24),

            // V8: Weekly Calendar Strip
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: CalendarStrip(
                selectedDate: _selectedDate,
                onDateSelected: (date) {
                  setState(() => _selectedDate = date);
                },
                accentColor: const Color(0xFF5D6E7E),
                getDateStats: _getDateStats,
              ),
            ),
            const SizedBox(height: 20),

            // Phase 3.1: Stock Depletion Forecast - Admin only
            if (isAdminRole && _stockForecasts.isNotEmpty) ...[
              StockForecastCard(
                forecasts: _stockForecasts,
                onRefresh: _loadAnalyticsData,
                onTap: () => _nav('/stock_tools'),
              ),
              const SizedBox(height: 20),
            ],

            // Phase 3.3: Proactive Insights Carousel - Admin only
            if (isAdminRole && _insights.isNotEmpty) ...[
              InsightsCarousel(
                insights: _insights,
                onInsightAction: (insight) {
                  HapticFeedback.mediumImpact();
                  _showInsightImplementationModal(insight);
                },
              ),
              const SizedBox(height: 20),
            ],

            // V5: Anticipatory Intelligence Card - Admin only
            if (isAdminRole && allocatorHint != null) _buildIntelligenceCard(allocatorHint),
            if (isAdminRole && allocatorHint != null) const SizedBox(height: 20),

            // V5: Swipeable Glass Carousel
            _buildGlassCarousel(packedKgs, packedCount),
            const SizedBox(height: 24),

            // V6: Intent Detection Prompt
            if (_pendingViewCount >= 3) ...[
              _buildIntentPrompt(),
              const SizedBox(height: 20),
            ],

            // V6: Ghost Suggestion (Mock detection for AGEB out of stock)
            if (stockNum < 2000) ...[
              _buildGhostSuggestion(grade: 'AGEB', suggestion: 'AGEB1'),
              const SizedBox(height: 20),
            ],


            // V5: Live Activity Stream (removed — Recent Orders panel)
            // _buildActivityStream(),

            // V8: Stock Distribution Donut Chart
            const SizedBox(height: 20),
            _buildStockDonutSection(),

            // V7: Stock Intelligence Section - Admin only
            if (isAdminRole) ...[
              const SizedBox(height: 24),
              _buildStockIntelligenceSection(),
            ],

            // V7: Alerts & Low Stock Card
            const SizedBox(height: 20),
            _buildAlertsCard(),

            // Phase 3.2: Analytics-powered Client Leaderboard - Admin only
            if (isAdminRole) ...[
              const SizedBox(height: 20),
              if (_clientScores.isNotEmpty)
                ClientLeaderboard(
                  clients: _clientScores,
                  onSeeAll: () => _nav('/view_orders'),
                  onClientTap: (client) {
                    HapticFeedback.lightImpact();
                  },
                )
              else
                _buildClientLeaderboardMini(),
            ],

            // Phase 4.1: Predictive Demand Trends - Admin only
            if (isAdminRole && _demandTrends.isNotEmpty) ...[
              const SizedBox(height: 20),
              DemandTrendsCard(
                trends: _demandTrends,
                onRefresh: _loadAnalyticsData,
              ),
            ],

            // V6: Evening Summary - Admin only
            if (isAdminRole && isEveningMode) ...[
              const SizedBox(height: 24),
              _buildEveningSummaryCard(),
            ],
            
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  // V6: New evening-only summary view
  // V10: Evening Summary Card - Titanium-well style
  Widget _buildEveningSummaryCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        // Titanium-well style
        color: const Color(0xFF9A9A94),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(5, 5)),
          BoxShadow(color: Colors.white.withOpacity(0.2), blurRadius: 5, offset: const Offset(-2, -2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('🌙', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          const Text('DAILY SUMMARY', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
        ]),
        const SizedBox(height: 20),
        _buildEveningRow('Total Sales', '₹${(((_dashboardData?['todaySalesVal'] ?? 0) is num ? (_dashboardData?['todaySalesVal'] ?? 0) : (num.tryParse('${_dashboardData?['todaySalesVal']}') ?? 0)) / 100000).toStringAsFixed(2)}L'),
        _buildEveningRow('Total Packed', '${_dashboardData?['todayPackedKgs'] ?? 0} kg'),
        _buildEveningRow('Orders Fulfilled', '${_dashboardData?['todayPackedCount'] ?? 0}'),
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _showDailyReportPopup,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white.withOpacity(0.1),
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('SHARE REPORT', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
        )),
      ]),
    );
  }

  // Global key for capturing report widget as image
  final GlobalKey _reportKey = GlobalKey();

  void _showDailyReportPopup() {
    HapticFeedback.mediumImpact();
    
    final totalSales = _dashboardData?['todaySalesVal'] ?? 0;
    final totalSalesNum = totalSales is num ? totalSales : (num.tryParse('$totalSales') ?? 0);
    final packedKgs = _dashboardData?['todayPackedKgs'] ?? 0;
    final packedCount = _dashboardData?['todayPackedCount'] ?? 0;
    final pendingQty = _dashboardData?['pendingQty'] ?? 0;
    final totalStock = _dashboardData?['totalStock'] ?? 0;
    final dateStr = DateFormat('dd MMM yyyy').format(DateTime.now());
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF4A5568),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: EdgeInsets.zero,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Capturable report area
            RepaintBoundary(
              key: _reportKey,
              child: Container(
                width: 300,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF5D6E7E), Color(0xFF4A5568)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('📊', style: TextStyle(fontSize: 24)),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('DAILY REPORT', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1)),
                            Text(dateStr, style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7))),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildReportRow('💰 Total Sales', '₹${(totalSalesNum / 100000).toStringAsFixed(2)}L'),
                    _buildReportRow('📦 Packed Today', '$packedKgs kg'),
                    _buildReportRow('✅ Orders Fulfilled', '$packedCount'),
                    _buildReportRow('⏳ Pending Orders', '$pendingQty'),
                    _buildReportRow('📊 Stock Available', '$totalStock kg'),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Text('🏷️', style: TextStyle(fontSize: 16)),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('Emperor Spices', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Share button
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _shareReportAsImage(ctx),
                  icon: const Icon(Icons.share_rounded),
                  label: const Text('SHARE AS IMAGE', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReportRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.8))),
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
        ],
      ),
    );
  }

  Future<void> _shareReportAsImage(BuildContext dialogContext) async {
    try {
      final boundary = _reportKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      if (byteData == null) return;
      
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/daily_report_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      
      Navigator.pop(dialogContext);
      
      await Share.shareXFiles(
        [XFile(file.path)],
        text: '📊 Daily Report - Emperor Spices',
      );
    } catch (e) {
      debugPrint('Error sharing report: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sharing: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildEveningRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.6))),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
      ]),
    );
  }

  // V11: Titanium Hero Card - delegated to extracted widget
  Widget _buildTitaniumHeroCard(String greeting, num totalStock, num pendingQty) {
    return TitaniumHeroCard(
      greeting: greeting,
      totalStock: totalStock,
      pendingQty: pendingQty,
      dashboardData: _dashboardData,
    );
  }

  // V10: Titanium Header Panel - delegated to extracted widget
  Widget _buildFrostedHeader(String greeting) {
    return FrostedHeader(
      userTasks: _userTasks,
      onMarkTasksSeen: _markTasksAsSeen,
      onShowNotifications: _showNotificationsPanel,
    );
  }

  // Glass stat pill - delegated to extracted widget
  Widget _buildGlassStatPill(String value, String label) {
    return GlassStatPill(value: value, label: label);
  }

  Widget _buildTitaniumActionBtn(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 64,
        decoration: AppTheme.machinedDecoration.copyWith(
          borderRadius: BorderRadius.circular(32),
          color: Colors.white.withOpacity(0.7),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppTheme.primary, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.manrope(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: AppTheme.primary,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Sync indicator - delegated to extracted widget
  Widget _buildSyncIndicator() {
    return SyncIndicator(lastSync: _lastSync
    );
  }

  Widget _buildSectionHeader(String title) {
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

  Widget _buildPrecisionTools() {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    bool can(String pageKey) => AccessControlService.canAccess(auth.pageAccess, pageKey, userRole: auth.role);

    final items = <Widget>[
      if (can('offer_price')) _buildPrecisionItem(Icons.local_offer_rounded, 'Offer Price', () => _nav('/offer_price')),
      if (can('new_order')) _buildPrecisionItem(Icons.add_shopping_cart_rounded, 'New Order', () => _nav('/new_order')),
      if (can('view_orders')) _buildPrecisionItem(Icons.list_alt_rounded, 'View Orders', () => _nav('/view_orders')),
      if (can('sales_summary')) _buildPrecisionItem(Icons.bar_chart_rounded, 'Sales Summary', () => _nav('/sales_summary')),
      if (can('grade_allocator')) _buildPrecisionItem(Icons.layers_outlined, 'Allocate', () => _showAllocationPopup()),
      if (can('add_to_cart')) _buildPrecisionItem(Icons.playlist_add_check_rounded, 'Add to Cart', () => _nav('/add_to_cart')),
      if (can('daily_cart')) _buildPrecisionItem(Icons.shopping_cart_outlined, 'Daily Cart', () => _showDailyCartPanel()),
      if (can('stock_tools')) _buildPrecisionItem(Icons.inventory_2_rounded, 'Stock', () => _showNetStockDragPopup()),
      if (can('outstanding')) _buildPrecisionItem(Icons.account_balance_wallet_rounded, 'Outstanding', () => _nav('/outstanding')),
      if (can('sales_summary')) _buildPrecisionItem(Icons.assessment_rounded, 'Reports', () => _nav('/reports')),
      if (can('task_management')) _buildPrecisionItem(Icons.task_alt_rounded, 'Tasks', () => _nav('/task_management')),
      _buildPrecisionItem(Icons.history_rounded, 'Audit Trail', () => Navigator.pushNamed(context, '/audit_trail')),
    ];

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 4,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 0.85,
      children: items,
    );
  }

  // Employee-only precision tools (limited set, filtered by access)
  Widget _buildEmployeePrecisionTools() {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    bool can(String pageKey) => AccessControlService.canAccess(auth.pageAccess, pageKey, userRole: auth.role);

    final items = <Widget>[
      if (can('view_orders')) _buildPrecisionItem(Icons.list_alt_rounded, 'View Orders', () => _nav('/view_orders')),
      if (can('add_to_cart')) _buildPrecisionItem(Icons.playlist_add_check_rounded, 'Add to Cart', () => _nav('/add_to_cart')),
      if (can('daily_cart')) _buildPrecisionItem(Icons.shopping_cart_outlined, 'Daily Cart', () => _showDailyCartPanel()),
      if (can('task_management')) _buildPrecisionItem(Icons.task_alt_rounded, 'My Tasks', () => _nav('/worker_tasks')),
      if (can('attendance')) _buildPrecisionItem(Icons.calendar_month_rounded, 'Attendance', () => _nav('/attendance')),
      if (can('expenses')) _buildPrecisionItem(Icons.receipt_long_rounded, 'Expenses', () => _nav('/expenses')),
      if (can('gate_passes')) _buildPrecisionItem(Icons.badge_rounded, 'Gate Pass', () => _nav('/gate_passes')),
      if (can('dispatch_documents')) _buildPrecisionItem(Icons.description_rounded, 'Dispatch', () => _nav('/dispatch_documents')),
    ];

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 4,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 0.85,
      children: items,
    );
  }

  Widget _buildPrecisionItem(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50, height: 50, // Reduced from 52 to safely clear 75.5px constraints
            decoration: AppTheme.machinedDecoration,
            child: Icon(icon, color: AppTheme.title, size: 20),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              label.toUpperCase(),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.manrope(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: AppTheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Titanium Nav Bar - delegated to extracted widget
  Widget _buildTitaniumNavBar() {
    return const TitaniumNavBar(currentRoute: '/admin_dashboard');
  }

  Widget _buildOfflineIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.5)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 10, color: Colors.white),
          SizedBox(width: 4),
          Text(
            'OFFLINE',
            style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // Header stat - now handled by TitaniumHeroCard internally

  void _showDailyCartPanel() {
    HapticFeedback.mediumImpact();
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5)),
          ],
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: const Color(0xFF5D6E7E), borderRadius: BorderRadius.circular(2)),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: AppTheme.machinedDecoration,
                          child: const Icon(Icons.shopping_cart_rounded, color: Color(0xFF5D6E7E), size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("Today's Cart", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                              Text('${_todayCart.length} items ready for packing', style: const TextStyle(fontSize: 12, color: Color(0xFF5D6E7E))),
                            ],
                          ),
                        ),
                        Container(
                          decoration: AppTheme.machinedDecoration,
                          child: IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded, color: Color(0xFF5D6E7E)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFFE2E8F0)),
                ],
              ),
            ),
            if (_todayCart.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.shopping_cart_outlined, size: 48, color: Colors.grey[300]),
                      const SizedBox(height: 12),
                      Text('No items in cart yet', style: TextStyle(color: Colors.grey[500], fontSize: 14)),
                      const SizedBox(height: 8),
                      Text('Select orders from urgency panel to add', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = _todayCart[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8, offset: const Offset(0, 2))],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(
                                color: const Color(0xFF5D6E7E).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Center(child: Text('${index + 1}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E)))),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item['client']?.toString() ?? 'Unknown', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF4A5568))),
                                  Text('${item['grade']} • ${item['kgs']} kg', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                                ],
                              ),
                            ),
                            Text(item['lot']?.toString() ?? '', style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                          ],
                        ),
                      );
                    },
                    childCount: _todayCart.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // V5: Neumorphic Revenue Monolith (unified glass depth)
  // V9: Pending Orders Urgency Panel - Matte Titanium Style
  Widget _buildPendingOrdersUrgencyPanel() {
    final pendingOrdersRaw = _pendingOrders;

    // Transform into local representation
    final List<Map<String, dynamic>> pendingOrders = (pendingOrdersRaw is List ? pendingOrdersRaw : <dynamic>[]).map((o) {
      final days = o is Map ? (o['daysSinceOrder'] ?? 0) : 0;
      return {
        ...(o is Map<String, dynamic> ? o : <String, dynamic>{}),
        'urgency': days >= 3 ? 'red' : (days >= 2 ? 'yellow' : 'green'),
        'daysSinceOrder': days,
      };
    }).toList()
      ..sort((a, b) => (b['daysSinceOrder'] as num).compareTo(a['daysSinceOrder'] as num));

    // Header Row
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                'PENDING ORDERS',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF131416),
                  letterSpacing: 1.5,
                ),
              ),
              GestureDetector(
                onTap: () => _showFullUrgencyList(pendingOrders),
                child: const Text(
                  'VIEW ALL',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF5D6E7E),
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // List of items (Matte Glass)
          ...pendingOrders.take(3).map((order) => _buildUrgencyOrderRow(order)),
        ],
      ),
    );
  }

  void _showSubOrderDetailPopup(Map<String, dynamic> order) {
    HapticFeedback.mediumImpact();
    final color = order['urgency'] == 'red' ? const Color(0xFFEF4444) : 
                order['urgency'] == 'yellow' ? const Color(0xFFF59E0B) : const Color(0xFF10B981);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF4A5568),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.description_rounded, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            const Text('Order Details', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailField('Client', order['client']?.toString() ?? 'Unknown'),
            _buildDetailField('Grade', order['grade']?.toString() ?? 'Unknown'),
            _buildDetailField('Weight', '${order['kgs']} kg'),
            _buildDetailField('Lot', order['lot']?.toString() ?? 'N/A'),
            _buildDetailField('Brand', order['brand']?.toString() ?? 'Standard'),
            _buildDetailField('Date', order['orderDate']?.toString() ?? 'N/A'),
            if (order['notes']?.toString().isNotEmpty ?? false)
              _buildDetailField('Notes', order['notes'].toString()),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 60, child: Text('$label:', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12))),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  Widget _buildUrgencyBadge(int count, Color color) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text('$count', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _buildUrgencyOrderRow(Map<String, dynamic> order) {
    final String urgency = order['urgency'] ?? 'green';
    final int days = order['daysSinceOrder'] ?? 0;
    final String client = order['client']?.toString() ?? 'Unknown';
    final String lot = order['lot']?.toString() ?? 'N/A';
    
    return GestureDetector(
      onTap: () => _showSubOrderDetailPopup(order),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Icon(Icons.inventory_2_outlined, color: AppTheme.primary, size: 20),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '#ORD-$lot',
                        style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.title),
                      ),
                      Text(
                        '$client • $days days ago',
                        style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      urgency == 'red' ? 'Overdue' : '${days}m ago',
                      style: GoogleFonts.manrope(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: urgency == 'red' ? AppTheme.danger : AppTheme.title,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: (urgency == 'red' ? AppTheme.danger : AppTheme.primary).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        urgency == 'red' ? 'URGENT' : 'ACTIVE',
                        style: GoogleFonts.manrope(
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          color: urgency == 'red' ? AppTheme.danger : AppTheme.primary,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showFullUrgencyList(List<Map<String, dynamic>> orders) {
    final redOrders = orders.where((o) => o['urgency'] == 'red').toList()
      ..sort((a, b) => (b['daysSinceOrder'] as num).compareTo(a['daysSinceOrder'] as num));
    final yellowOrders = orders.where((o) => o['urgency'] == 'yellow').toList()
      ..sort((a, b) => (b['daysSinceOrder'] as num).compareTo(a['daysSinceOrder'] as num));
    final greenOrders = orders.where((o) => o['urgency'] == 'green').toList()
      ..sort((a, b) => (b['daysSinceOrder'] as num).compareTo(a['daysSinceOrder'] as num));
    
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB)],
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: CustomScrollView(
                  controller: scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          Container(
                            margin: const EdgeInsets.only(top: 12),
                            width: 40, height: 4,
                            decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEF4444).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(Icons.priority_high_rounded, color: Color(0xFFEF4444), size: 22),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('Pending Orders by Urgency', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                                      Text('${orders.length} total • ${_selectedUrgencyIndices.length} selected', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => Navigator.pop(context),
                                  icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFFE2E8F0)),
                        ],
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          if (redOrders.isNotEmpty) ...[
                            _buildUrgencySectionStateful('🔴 Critical (>10 days)', redOrders, const Color(0xFFEF4444), setSheetState),
                            const SizedBox(height: 16),
                          ],
                          if (yellowOrders.isNotEmpty) ...[
                            _buildUrgencySectionStateful('🟡 Warning (5-10 days)', yellowOrders, const Color(0xFFF59E0B), setSheetState),
                            const SizedBox(height: 16),
                          ],
                          if (greenOrders.isNotEmpty) ...[
                            _buildUrgencySectionStateful('🟢 Normal (<5 days)', greenOrders, const Color(0xFF10B981), setSheetState),
                          ],
                          const SizedBox(height: 80), // Space for FAB
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
              // Floating cart button INSIDE modal
              if (_selectedUrgencyIndices.isNotEmpty)
                Positioned(
                  bottom: 20,
                  right: 20,
                  child: _buildModalCartFab(sheetContext, setSheetState),
                ),
            ],
          ),
      ),
    );
  }

  Widget _buildModalCartFab(BuildContext sheetContext, StateSetter setSheetState) {
    return GestureDetector(
      onTap: () => _sendSelectedToCartFromModal(sheetContext, setSheetState),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF4A5568)]),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(color: const Color(0xFF5D6E7E).withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shopping_cart_checkout_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Text('Add ${_selectedUrgencyIndices.length} to Cart', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  void _sendSelectedToCartFromModal(BuildContext sheetContext, StateSetter setSheetState) {
    HapticFeedback.heavyImpact();

    final selectedItems = _selectedUrgencyIndices.map((idx) {
      return _pendingOrders.where((o) {
        final oIdx = o['index'] is int ? o['index'] : (int.tryParse(o['index']?.toString() ?? '') ?? -1);
        return oIdx == idx;
      }).firstOrNull;
    }).whereType<Map<String, dynamic>>().toList();

    if (selectedItems.isEmpty) return;

    final previousIndices = Set<int>.from(_selectedUrgencyIndices);

    optimistic(
      type: 'add_to_cart',
      applyLocal: () {
        setState(() => _selectedUrgencyIndices.clear());
        setSheetState(() {});
        Navigator.pop(sheetContext); // Close modal immediately
      },
      apiCall: () => _apiService.addToCart(selectedItems),
      rollback: () => setState(() => _selectedUrgencyIndices.addAll(previousIndices)),
      successMessage: '${selectedItems.length} orders sent to daily cart!',
      failureMessage: 'Failed to add orders to cart. Reverted.',
      onSuccess: () => _loadData(),
    );
  }

  Widget _buildUrgencySectionStateful(String title, List<Map<String, dynamic>> orders, Color color, StateSetter setSheetState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 8),
        ...orders.map((order) {
          final int orderIndex = order['index'] is int ? order['index'] : (int.tryParse(order['index']?.toString() ?? '') ?? -1);
          final bool isSelected = _selectedUrgencyIndices.contains(orderIndex);

          return GestureDetector(
            onTap: () => _showSubOrderDetailPopup(order),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isSelected ? color.withOpacity(0.15) : color.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isSelected ? color : color.withOpacity(0.25), width: isSelected ? 2 : 1),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
                    child: Center(child: Text('${order['daysSinceOrder']}d', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(order['client']?.toString() ?? 'Unknown', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF4A5568))),
                        Text('${order['grade']} • ${order['kgs']} kg • ${order['orderDate']}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                      ],
                    ),
                  ),
                  Checkbox(
                    value: isSelected,
                    activeColor: color,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    onChanged: (val) {
                      setSheetState(() {
                        if (val == true) {
                          _selectedUrgencyIndices.add(orderIndex);
                          HapticFeedback.lightImpact();
                        } else {
                          _selectedUrgencyIndices.remove(orderIndex);
                        }
                      });
                      setState(() {}); // Also update main dashboard for the floating button
                    },
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ],
    );
  }


  Widget _buildUrgencySection(String title, List<Map<String, dynamic>> orders, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 8),
        ...orders.map((order) {
          final int orderIndex = order['index'] is int ? order['index'] : (int.tryParse(order['index']?.toString() ?? '') ?? -1);
          final bool isSelected = _selectedUrgencyIndices.contains(orderIndex);

          return GestureDetector(
            onTap: () => _showSubOrderDetailPopup(order), // Open details on tap
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isSelected ? color.withOpacity(0.15) : color.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isSelected ? color : color.withOpacity(0.25), width: isSelected ? 2 : 1),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Text('${order['daysSinceOrder']}d', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(order['client']?.toString() ?? 'Unknown', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF4A5568))),
                        Text('${order['grade']} • ${order['kgs']} kg • ${order['orderDate']}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                      ],
                    ),
                  ),
                  // Checkbox for selection
                  Checkbox(
                    value: isSelected,
                    activeColor: color,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _selectedUrgencyIndices.add(orderIndex);
                          HapticFeedback.lightImpact();
                        } else {
                          _selectedUrgencyIndices.remove(orderIndex);
                        }
                      });
                    },
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ],
    );
  }

  void _scheduleCriticalOrdersNotification(int redCount, int yellowCount) {
    // This will trigger a local notification for critical orders
    // Integration with notification service
    if (_notificationScheduled) return;
    _notificationScheduled = true;
    
    debugPrint('🔔 Scheduling notification: $redCount critical, $yellowCount warning orders');
    // NotificationService would be called here to schedule daily reminder
  }
  
  bool _notificationScheduled = false;


  // V5: Neumorphic Stat Duo
  Widget _buildStatDuo(dynamic stock, dynamic pending) {
    final stockNum = stock is num ? stock : (num.tryParse('$stock') ?? 0);
    final pendingNum = pending is num ? pending : (num.tryParse('$pending') ?? 0);
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Expanded(child: _buildNeumorphicStat(
          'Net Stock', 
          _previousStockValue, 
          stockNum, 
          (val) => '${(val / 1000).toStringAsFixed(1)}K', 
          Icons.inventory_2_rounded, 
          const Color(0xFF10B981), 
          _showNetStockDragPopup
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildNeumorphicStat(
          'Pending', 
          _previousPendingValue, 
          pendingNum, 
          (val) => '${(val / 1000).toStringAsFixed(1)}K', 
          Icons.pending_actions_rounded, 
          const Color(0xFFF59E0B), 
          _showPendingDragPopup
        )),
      ]),
    );
  }

  // V10: Titanium Block Stat Card
  Widget _buildNeumorphicStat(String label, num beginValue, num endValue, String Function(double) formatter, IconData icon, Color accent, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            // Bevel shadow
            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
            const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
          ],
          border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Icon container with inner shadow
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(1, 1)),
              ],
            ),
            child: Icon(icon, color: accent, size: 18),
          ),
          const SizedBox(height: 12),
          // Value with titanium text
          _buildAnimatedCounter(
            begin: beginValue,
            end: endValue,
            formatter: formatter,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF131416)),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: accent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(label.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF5D6E7E), letterSpacing: 0.8)),
          ]),
        ]),
      ),
    );
  }


  // V5: Anticipatory Intelligence Card (glass border)
  // V10: Deep Insights - Titanium-well recessed style
  Widget _buildIntelligenceCard(dynamic hint) {
    final grade = hint['grade']?.toString() ?? '';
    final qty = hint['qty']?.toString() ?? '';
    const steelBlue = Color(0xFF5D6E7E);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        // Recessed container style
        color: const Color(0xFFD1D1CB),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          // Inset shadows for recessed look
          BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(4, 4)),
          BoxShadow(color: Colors.white.withOpacity(0.4), blurRadius: 8, offset: const Offset(-4, -4)),
        ],
        border: Border.all(color: const Color(0xFFA8A8A1)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFE3E3DE),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(1, 1)),
              ],
            ),
            child: const Icon(Icons.auto_awesome, color: steelBlue, size: 18),
          ),
          const SizedBox(width: 12),
          const Text('INTELLIGENCE', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF131416))),
        ]),
        const SizedBox(height: 20),
        _buildTitaniumInsightRow('🎯', 'RECOMMENDATION', 'Pack $qty kg of $grade for best fulfillment.', const Color(0xFFEF4444)),
        const SizedBox(height: 16),
        Container(height: 1, color: const Color(0xFFA8A8A1).withOpacity(0.5)),
        const SizedBox(height: 16),
        _buildTitaniumInsightRow('🚀', 'BRAND VELOCITY', 'Emperor is selling 1.5x faster than Royal today.', const Color(0xFF5D6E7E)),
        const SizedBox(height: 16),
        Container(height: 1, color: const Color(0xFFA8A8A1).withOpacity(0.5)),
        const SizedBox(height: 16),
        _buildTitaniumInsightRow('📊', 'LOT PERFORMANCE', 'Lot 123 has 98% quality consistency score.', const Color(0xFF10B981)),
      ]),
    );
  }

  Widget _buildTitaniumInsightRow(String emoji, String title, String desc, Color iconColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFFE3E3DE),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(1, 1)),
            ],
          ),
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 16))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: const Color(0xFF5D6E7E).withOpacity(0.7), letterSpacing: 0.5)),
            const SizedBox(height: 2),
            Text(desc, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF131416))),
          ]),
        ),
      ],
    );
  }

  Widget _buildInsightRow(String title, String desc) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E))),
      const SizedBox(height: 4),
      Text(desc, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
    ]);
  }


  // V5: Swipeable Glass Carousel
  // V10: Intelligence Carousel - Machined Titanium Style
  Widget _buildGlassCarousel(dynamic packedKgs, dynamic packedCount) {
    final kgs = packedKgs is num ? packedKgs : (num.tryParse('$packedKgs') ?? 0);
    final count = packedCount is num ? packedCount : (num.tryParse('$packedCount') ?? 0);
    
    // V6: Logic for Smart Reorder
    final pendingQty = _dashboardData?['pendingQty'] ?? 0;
    final totalStock = _dashboardData?['totalStock'] ?? 0;
    final pendingNum = pendingQty is num ? pendingQty : (num.tryParse('$pendingQty') ?? 0);
    final stockNum = totalStock is num ? totalStock : (num.tryParse('$totalStock') ?? 0);
    final needsReorder = pendingNum > (stockNum * 0.8) && pendingNum > 0;
    
    // V6: Logic for Demand Forecast
    final hours = _getHoursElapsed();
    final ordersPerHour = count / hours;
    final forecastedOrders = (ordersPerHour * 2).ceil();
    
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Icon(Icons.lightbulb_outline, size: 16, color: Colors.amber[600]),
          const SizedBox(width: 6),
          const Text('INSIGHTS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF5D6E7E), letterSpacing: 2)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFD1D1CB),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('0${needsReorder ? 4 : 3}', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF5D6E7E))),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 140,
        child: PageView(
          controller: PageController(viewportFraction: 0.72, initialPage: 0),
          padEnds: false, // Aligns first card to left edge
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _buildMachinedCard('Packed Today', '${kgs.toStringAsFixed(0)} kg', 'Across $count orders', Icons.inventory_2, true, _showPackedDragPopup),
            ),
            if (needsReorder)
              _buildMachinedCard('Smart Reorder', 'Alert', 'Pending > 80% of Stock', Icons.warning_amber_rounded, false, _showNetStockDragPopup),
            _buildMachinedCard('Next 2 Hours', '~$forecastedOrders Orders', 'Predicted demand', Icons.schedule, true, _showPendingDragPopup),
            _buildMachinedCard('Flow Rate', '${(kgs / hours).toStringAsFixed(1)} kg/hr', 'Current throughput', Icons.speed, true, _showNetStockDragPopup),
          ],
        ),
      ),
    ]);
  }


  // V10: Machined Card - Industrial Metal Style
  Widget _buildMachinedCard(String title, String value, String subtitle, IconData icon, bool isBlue, VoidCallback onTap) {
    // Machined blue or machined copper from reference
    final gradientColors = isBlue 
        ? [const Color(0xFF4A5568), const Color(0xFF2D3748)]
        : [const Color(0xFFCD7F32), const Color(0xFF8B4513)];
    
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradientColors,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.white.withOpacity(0.1), blurRadius: 0, offset: const Offset(1, 1)),
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 15, offset: const Offset(0, 10)),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, mainAxisSize: MainAxisSize.max, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Icon(icon, color: Colors.white.withOpacity(0.8), size: 24),
            Container(width: 24, height: 3, decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(2))),
          ]),
          const Spacer(),
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.6))),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Text(value, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.3)),
          ),
        ]),
      ),
    );
  }
  
  // Keep old method for compatibility
  Widget _buildGlassCard(String title, String value, String subtitle, Color accent, VoidCallback onTap) {
    return _buildMachinedCard(title, value, subtitle, Icons.auto_awesome, true, onTap);
  }

  // V5: Unified Action Panel (Neumorphic buttons)
  // V10: Unified Actions - Titanium-block style
  Widget _buildUnifiedActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: _buildTitaniumActionButton('New Order', Icons.add_rounded, () => _nav('/new_order'))),
          const SizedBox(width: 12),
          Expanded(child: _buildTitaniumActionButton('All Orders', Icons.list_alt_rounded, () => _nav('/view_orders'))),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _buildTitaniumMiniAction('📦', 'Stock', _showStockPopup)),
          const SizedBox(width: 10),
          Expanded(child: _buildTitaniumMiniAction('💰', 'Sales', _showSalesPopup)),
          const SizedBox(width: 10),
          Expanded(child: _buildTitaniumMiniAction('🎯', 'Allocate', _showAllocationPopup)),
          const SizedBox(width: 10),
          Expanded(child: _buildTitaniumMiniAction('📊', 'Insights', _showInsightsPopup)),
        ]),
      ]),
    );
  }

  // V10: Titanium Action Button
  Widget _buildTitaniumActionButton(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          // Titanium-block gradient
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
            const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
          ],
          border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: const Color(0xFF5D6E7E), size: 22),
          const SizedBox(width: 10),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: Color(0xFF131416),
              letterSpacing: 1.2,
            ),
          ),
        ]),
      ),
    );
  }

  // V10: Titanium Mini Action (circular)
  Widget _buildTitaniumMiniAction(String emoji, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // Titanium-block gradient
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
              ),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
                const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
              ],
            ),
            child: Text(emoji, style: const TextStyle(fontSize: 20)),
          ),
          const SizedBox(height: 8),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: Color(0xFF5D6E7E),
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
  
  // Keep old methods for compatibility
  Widget _buildActionButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return _buildTitaniumActionButton(label, icon, onTap);
  }

  Widget _buildMiniAction(String emoji, String label, VoidCallback onTap) {
    return _buildTitaniumMiniAction(emoji, label, onTap);
  }

  // V8: Stock Distribution Donut Chart Section
  Widget _buildStockDonutSection() {
    final netStock = _dashboardData?['netStock'] ?? {};
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    
    // Debug logging
    debugPrint('📊 Stock Donut - netStock keys: ${netStock.keys.toList()}');
    debugPrint('📊 Stock Donut - rows count: ${rows.length}');
    
    // Calculate totals per type
    double colourTotal = 0;
    double fruitTotal = 0;
    double rejectionTotal = 0;
    
    for (var row in rows) {
      List<dynamic> values = row is List ? row : (row is Map ? row['values'] ?? [] : []);
      String rowType = row is List ? (values.isNotEmpty ? values[0]?.toString() ?? '' : '') : (row['type']?.toString() ?? '');
      
      debugPrint('📊 Row type: $rowType, values length: ${values.length}');
      
      double sum = 0;
      for (int i = 1; i < values.length; i++) {
        final val = values[i] is num ? values[i].toDouble() : (double.tryParse(values[i]?.toString() ?? '0') ?? 0);
        if (val > 0) sum += val;
      }
      
      if (rowType.toLowerCase().contains('colour')) colourTotal = sum;
      else if (rowType.toLowerCase().contains('fruit')) fruitTotal = sum;
      else if (rowType.toLowerCase().contains('rejection')) rejectionTotal = sum;
    }
    
    final total = colourTotal + fruitTotal + rejectionTotal;
    debugPrint('📊 Stock totals - Colour: $colourTotal, Fruit: $fruitTotal, Rejection: $rejectionTotal, Total: $total');
    
    // Show placeholder if no data instead of hiding
    if (total <= 0) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          // Titanium-well style
          color: const Color(0xFF9A9A94),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(5, 5)),
            BoxShadow(color: Colors.white.withOpacity(0.2), blurRadius: 5, offset: const Offset(-2, -2)),
          ],
        ),
        child: Column(
          children: [
            const Text(
              'STOCK DISTRIBUTION',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white70, letterSpacing: 2),
            ),
            const SizedBox(height: 16),
            Icon(Icons.inventory_2_outlined, size: 40, color: Colors.white.withOpacity(0.3)),
            const SizedBox(height: 8),
            Text('No stock data available', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5))),
            const SizedBox(height: 4),
            Text('Pull to refresh', style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.3))),
          ],
        ),
      );
    }
    
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        _showFullStockBreakdown();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          // Titanium-well style
          color: const Color(0xFF9A9A94),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(5, 5)),
            BoxShadow(color: Colors.white.withOpacity(0.2), blurRadius: 5, offset: const Offset(-2, -2)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'STOCK DISTRIBUTION',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF4A5568), letterSpacing: 1.5),
                ),
                Row(
                  children: [
                    Icon(Icons.touch_app_rounded, size: 12, color: AppTheme.title.withOpacity(0.6)),
                    const SizedBox(width: 4),
                    Text('Tap for details', style: TextStyle(fontSize: 9, color: AppTheme.title.withOpacity(0.6))),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Flexible(
                  child: DonutChart(
                    progress: (colourTotal / total).clamp(0.0, 1.0),
                    centerText: '${(colourTotal / 1000).toStringAsFixed(0)}K',
                    subtitle: 'Colour',
                    size: 70,
                    strokeWidth: 7,
                    primaryColor: const Color(0xFF10B981),
                    secondaryColor: const Color(0xFF34D399),
                  ),
                ),
                Flexible(
                  child: DonutChart(
                    progress: (fruitTotal / total).clamp(0.0, 1.0),
                    centerText: '${(fruitTotal / 1000).toStringAsFixed(0)}K',
                    subtitle: 'Fruit',
                    size: 70,
                    strokeWidth: 7,
                    primaryColor: const Color(0xFFF59E0B),
                    secondaryColor: const Color(0xFFFBBF24),
                  ),
                ),
                Flexible(
                  child: DonutChart(
                    progress: (rejectionTotal / total).clamp(0.0, 1.0),
                    centerText: '${(rejectionTotal / 1000).toStringAsFixed(0)}K',
                    subtitle: 'Reject',
                    size: 70,
                    strokeWidth: 7,
                    primaryColor: const Color(0xFFEF4444),
                    secondaryColor: const Color(0xFFF87171),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildDonutLegend('Colour Bold', const Color(0xFF10B981), colourTotal),
                _buildDonutLegend('Fruit Bold', const Color(0xFFF59E0B), fruitTotal),
                _buildDonutLegend('Rejection', const Color(0xFFEF4444), rejectionTotal),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showFullStockBreakdown() {
    final netStock = _dashboardData?['netStock'] ?? {};
    final virtualGrades = ['8.5 mm', '7.8 bold', '7 to 8 mm', '6.5 to 8 mm', '6.5 to 7.5 mm', '6 to 7 mm', 'Mini Bold', 'Pan'];
    
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF5D6E7E).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.inventory_2_rounded, color: Color(0xFF5D6E7E), size: 22),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Stock Breakdown', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                              Text('Absolute grade stock by type', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFFE2E8F0)),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: StockAccordion(
                  netStock: netStock,
                  virtualGrades: virtualGrades,
                  stockTypes: const ['Colour Bold', 'Fruit Bold', 'Rejection'],
                  initiallyExpanded: true,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }
  
  Widget _buildDonutLegend(String label, Color color, double value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 9, color: AppTheme.title)),
            Text('${(value / 1000).toStringAsFixed(1)}K', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
          ],
        ),
      ],
    );
  }

  // ====================== V7: MISSING FEATURES ======================

  // V7: Stock Intelligence Section - Swipeable cards for stock data
  Widget _buildStockIntelligenceSection() {
    final netStock = _dashboardData?['netStock'] ?? {};
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    
    // Calculate low and high stock items
    final lowItems = <Map<String, dynamic>>[];
    final highItems = <Map<String, dynamic>>[];
    
    for (var row in rows) {
      List<dynamic> values = [];
      String rowType = '';
      if (row is List) {
        values = row;
        rowType = values.isNotEmpty ? values[0]?.toString() ?? '' : '';
      } else if (row is Map && row['values'] is List) {
        values = (row['values'] as List<dynamic>?) ?? [];
        rowType = row['type']?.toString() ?? '';
      }
      
      for (int i = 1; i < values.length && i < headers.length; i++) {
        if (absGrades.contains(headers[i])) {
          final val = values[i] is num ? values[i].toDouble() : (num.tryParse(values[i]?.toString() ?? '0') ?? 0).toDouble();
          if (val < 0) {
            lowItems.add({'type': rowType, 'grade': headers[i], 'value': val});
          } else if (val > 500) {
            highItems.add({'type': rowType, 'grade': headers[i], 'value': val});
          }
        }
      }
    }
    
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          const Text('STOCK INTELLIGENCE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF4A5568), letterSpacing: 1.5)),
          const SizedBox(width: 8),
          Icon(Icons.insights_rounded, size: 14, color: Colors.green[400]),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 130,
        child: PageView(
          controller: PageController(viewportFraction: 0.88),
          children: [
            _buildNeumorphicStockCard('⚠️ Low Stock', '${lowItems.length} items', 'Grades below threshold', Colors.red, lowItems.isEmpty ? '💪 All healthy!' : lowItems.take(3).map((e) => '${e['grade']}: ${(e['value'] as num).round()}kg').join('\n')),
            _buildNeumorphicStockCard('🔥 High Stock', '${highItems.length} items', 'Push for sales!', Colors.green, highItems.isEmpty ? '📦 Balanced stock' : highItems.take(3).map((e) => '${e['grade']}: ${(e['value'] as num).round()}kg').join('\n')),
            _buildNeumorphicStockCard('📊 Stock Table', 'Full View', 'Tap to expand', const Color(0xFF5D6E7E), 'View complete stock by type & grade', onTap: _showNetStockDragPopup),
          ],
        ),
      ),
    ]);
  }

  Widget _buildNeumorphicStockCard(String title, String value, String subtitle, Color color, String content, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB)],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
            const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color))),
            Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
          ]),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
          const SizedBox(height: 8),
          Text(content, style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)), maxLines: 3, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }

  // V7: Alerts Card with Low/Negative Stock Warnings
  // V10: Alerts Card - iOS Glassmorphic
  // V10: Alerts Card - Titanium-block style
  Widget _buildAlertsCard() {
    final netStock = _dashboardData?['netStock'] ?? {};
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    
    List<Map<String, dynamic>> negativeGrades = [];
    List<Map<String, dynamic>> lowGrades = [];
    
    for (var row in rows) {
      List<dynamic> values = row is List ? row : (row is Map ? row['values'] ?? [] : []);
      String rowType = row is List ? (values.isNotEmpty ? values[0]?.toString() ?? '' : '') : (row['type']?.toString() ?? '');
      
      for (int i = 1; i < values.length && i < headers.length; i++) {
        if (absGrades.contains(headers[i])) {
          final val = values[i] is num ? values[i] : (num.tryParse(values[i]?.toString() ?? '0') ?? 0);
          if (val < 0) {
            negativeGrades.add({'grade': headers[i], 'type': rowType, 'value': val});
          } else if (val < 50 && val >= 0) {
            lowGrades.add({'grade': headers[i], 'type': rowType, 'value': val});
          }
        }
      }
    }
    
    final hasIssues = negativeGrades.isNotEmpty || lowGrades.isNotEmpty;
    final accentColor = hasIssues ? Colors.red : const Color(0xFF10B981);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        // Titanium-block gradient
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
          const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(hasIssues ? Icons.warning_amber_rounded : Icons.check_circle_rounded, color: accentColor, size: 20),
          const SizedBox(width: 10),
          Text(hasIssues ? 'STOCK ALERTS' : 'ALL SYSTEMS GO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: accentColor, letterSpacing: 1)),
        ]),
        const SizedBox(height: 12),
        if (!hasIssues)
          const Text('No stock issues. Keep crushing it! 💪', style: TextStyle(fontSize: 12, color: Color(0xFF5D6E7E)))
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (negativeGrades.isNotEmpty) 
              _buildInteractiveAlertChip('🔴 ${negativeGrades.length} Negative', Colors.red, negativeGrades, 'Negative Stock'),
            if (lowGrades.isNotEmpty) 
              _buildInteractiveAlertChip('⚠️ ${lowGrades.length} Low (<50kg)', Colors.orange, lowGrades, 'Low Stock'),
          ]),
      ]),
    );
  }

  Widget _buildInteractiveAlertChip(String label, Color color, List<Map<String, dynamic>> grades, String title) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        _showStockAlertDetails(title, color, grades);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1), 
          borderRadius: BorderRadius.circular(10), 
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(width: 6),
            Icon(Icons.arrow_forward_ios_rounded, size: 10, color: color),
          ],
        ),
      ),
    );
  }

  void _showStockAlertDetails(String title, Color color, List<Map<String, dynamic>> grades) {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5)),
          ],
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  // Handle
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: const Color(0xFF5D6E7E), borderRadius: BorderRadius.circular(2)),
                  ),
                  // Header
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
                          child: Icon(title.contains('Negative') ? Icons.trending_down_rounded : Icons.warning_amber_rounded, color: color, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
                              Text('${grades.length} grade(s) affected', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = grades[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: color.withOpacity(0.15)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(item['grade'], style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item['type'] ?? 'Unknown', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF334155))),
                                Text('Current: ${item['value']} kg', style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  childCount: grades.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.3))),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
    );
  }

  // V7: Client Leaderboard Mini
  // V10: Client Leaderboard Mini - iOS Glassmorphic
  // V10: Client Leaderboard Mini - Titanium-block style
  Widget _buildClientLeaderboardMini() {
    final leaderboard = List<dynamic>.from(_dashboardData?['clientLeaderboard'] ?? []);
    final top5 = leaderboard.take(5).toList();
    const steelBlue = Color(0xFF5D6E7E);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        // Dark gradient matching Packed Today cards
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4A5568), Color(0xFF2D3748)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
          const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('🏅', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          const Text('TOP CLIENTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
          const Spacer(),
          GestureDetector(
            onTap: _showInsightsPopup,
            child: Text('VIEW ALL', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: Colors.white.withOpacity(0.7))),
          ),
        ]),
        const SizedBox(height: 14),
        if (top5.isEmpty)
          const Text('No client data yet. Time for coffee? ☕', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)))
        else
          ...top5.asMap().entries.map((entry) {
            final i = entry.key;
            final c = entry.value;
            final medal = i == 0 ? '🥇' : (i == 1 ? '🥈' : (i == 2 ? '🥉' : ''));
            return Padding(
              padding: EdgeInsets.only(bottom: i < top5.length - 1 ? 8 : 0),
              child: Row(children: [
                Text(medal.isEmpty ? '${i + 1}.' : medal, style: const TextStyle(fontSize: 14, color: Colors.white)),
                const SizedBox(width: 8),
                Expanded(child: Text(c['client']?.toString() ?? '?', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white), overflow: TextOverflow.ellipsis)),
                Text('₹${c['pendingValue'] ?? 0}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white.withOpacity(0.8))),
              ]),
            );
          }),
      ]),
    );
  }

  // V7: Quick Admin Actions Panel - iOS Glassmorphic Style
  Widget _buildQuickAdminActions() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildQuickActionChip('Daily Cart', Icons.shopping_cart_outlined, () => _nav('/daily_cart')),
          _buildQuickActionChip('Allocator', Icons.dashboard_outlined, () => _nav('/grade_allocator')),
          _buildQuickActionChip('Inbound', Icons.inventory_2_outlined, () => Navigator.pushNamed(context, '/scan_stock')),
          _buildQuickActionChip('Reports', Icons.bar_chart_outlined, () => _nav('/sales_summary')),
        ],
      ),
    );
  }

  Widget _buildQuickActionChip(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Frosted glass circular button
          ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.6),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(icon, color: const Color(0xFF475569), size: 24),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Label
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: Color(0xFF64748B),
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  // V7: Sales Intensity Heat Map Strip
  Widget _buildSalesIntensityStrip() {
    final hoursElapsed = _getHoursElapsed().floor();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: const Color(0xFFCBD5E1), blurRadius: 6, offset: const Offset(2, 2)),
          const BoxShadow(color: Colors.white, blurRadius: 6, offset: Offset(-2, -2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('DAILY INTENSITY', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8), letterSpacing: 1.2)),
        const SizedBox(height: 10),
        Row(children: List.generate(12, (i) {
          final isActive = i < hoursElapsed;
          final intensity = isActive ? (i / 12) : 0.0;
          return Expanded(
            child: Container(
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: isActive ? Color.lerp(const Color(0xFF10B981), const Color(0xFFEF4444), intensity) : const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        })),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: const [
          Text('8 AM', style: TextStyle(fontSize: 8, color: Color(0xFF94A3B8))),
          Text('8 PM', style: TextStyle(fontSize: 8, color: Color(0xFF94A3B8))),
        ]),
      ]),
    );
  }

  // V6: Get empty state message based on time of day
  Widget _buildContextualEmptyState() {
    final hour = DateTime.now().hour;
    String emoji = '😴';
    String title = "It's quiet here...";
    String subtitle = "Time for coffee? ☕";

    if (hour < 12) {
      emoji = '🌅';
      title = "Fresh start!";
      subtitle = "First order coming soon...";
    } else if (hour < 17) {
      emoji = '☕';
      title = "Quiet afternoon";
      subtitle = "Maybe review some analytics?";
    } else {
      emoji = '🌙';
      title = "Day's wrapping up";
      subtitle = "Great work today! 🎉";
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E8F0).withOpacity(0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(children: [
        Text(emoji, style: const TextStyle(fontSize: 32)),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF475569))),
        Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
      ]),
    );
  }

  // V10: Live Activity Stream - iOS Glassmorphic
  // V10: Recent Orders - Titanium-block style
  Widget _buildActivityStream() {
    final pending = _sortByUrgency(_pendingOrders);
    final recent = pending.isNotEmpty ? pending.take(3).toList() : [];
    const steelBlue = Color(0xFF5D6E7E);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        // Dark gradient matching Packed Today cards
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4A5568), Color(0xFF2D3748)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
          const BoxShadow(color: Colors.white70, blurRadius: 4, offset: Offset(-2, -2)),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF22C55E), shape: BoxShape.circle)),
          const SizedBox(width: 10),
          const Text('RECENT ORDERS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
          const Spacer(),
          GestureDetector(
            onTap: () => _showPendingDragPopup(),
            child: Text('VIEW ALL', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: Colors.white.withOpacity(0.7))),
          ),
        ]),
        const SizedBox(height: 16),
        if (recent.isEmpty)
          _buildContextualEmptyState()
        else
                ...recent.asMap().entries.map((entry) {
                  final i = entry.key;
                  final order = entry.value;
                  final client = order['client']?.toString() ?? 'Client';
                  final grade = order['grade']?.toString() ?? 'Grade';
                  
                  return GestureDetector(
                    onTap: () => _showPendingDragPopup(),
                    child: Container(
                      margin: EdgeInsets.only(bottom: i < recent.length - 1 ? 12 : 0),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        // Titanium sub-card
                        color: const Color(0xFFD1D1CB),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(1, 1)),
                        ],
                      ),
                      child: Row(children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFE3E3DE), Color(0xFFA8A8A1)],
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.view_in_ar_rounded, color: Color(0xFF5D6E7E), size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('#ORD-${order['lot'] ?? i}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF131416))),
                          Text(client.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF5D6E7E), letterSpacing: 0.3)),
                        ])),
                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text(i == 0 ? 'Processing' : 'In Transit', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: i == 0 ? const Color(0xFF5D6E7E) : const Color(0xFF9A9A94))),
                          Text('${order['kgs'] ?? 0}kg', style: const TextStyle(fontSize: 10, color: Color(0xFF9A9A94))),
                        ]),
                      ]),
                    ),
                  );
                }),
      ]),
    );
  }




  // Glassmorphic Header with blur effect
  Widget _buildGlassHeader(String greeting) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Colors.white.withOpacity(0.8), Colors.white.withOpacity(0.4)],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.5)),
        boxShadow: [BoxShadow(color: const Color(0xFF5D6E7E).withOpacity(0.1), blurRadius: 30, offset: const Offset(0, 12))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Row(children: [
            // Avatar with gradient ring
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFFEC4899), Color(0xFFF59E0B)]),
              ),
              child: Container(
                width: 50, height: 50,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]),
                child: const Center(child: Text('👤', style: TextStyle(fontSize: 24))),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(greeting, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
              const SizedBox(height: 2),
              Text(DateFormat('EEEE, d MMM yyyy').format(DateTime.now()), style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280), fontWeight: FontWeight.w500)),
            ])),
            // Notification bell
            GestureDetector(
              onTap: () {
                HapticFeedback.mediumImpact();
                _showNotificationsPanel();
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.notifications_outlined, color: Color(0xFF6B7280), size: 22),
                  ),
                  Consumer<NotificationService>(
                    builder: (context, notificationService, _) {
                      final taskCount = _userTasks.where((t) => t.status == TaskStatus.ongoing || t.status == TaskStatus.pending).length;
                      final approvalCount = notificationService.pendingApprovalCount;
                      final totalCount = taskCount + approvalCount;
                      
                      if (totalCount == 0) return const SizedBox.shrink();
                      
                      return Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: Text(
                            '$totalCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // Hero Stats with animated progress rings
  Widget _buildHeroStatsRow(dynamic totalSales, dynamic totalStock, dynamic pendingQty) {
    final sales = totalSales is num ? totalSales : (num.tryParse('$totalSales') ?? 0);
    final stock = totalStock is num ? totalStock : (num.tryParse('$totalStock') ?? 0);
    final pending = pendingQty is num ? pendingQty : (num.tryParse('$pendingQty') ?? 0);
    
    return SizedBox(
      height: 180,
      child: Row(children: [
        // Main Sales Card - Larger
        Expanded(flex: 3, child: _buildMainSalesCard(sales)),
        const SizedBox(width: 12),
        // Stock & Pending Pills
        Expanded(flex: 2, child: Column(children: [
          Expanded(child: _buildMiniStatPill('📦', stock, 'Stock', const Color(0xFF10B981), _showNetStockDragPopup)),
          const SizedBox(height: 8),
          Expanded(child: _buildMiniStatPill('⏳', pending, 'Pending', const Color(0xFFF59E0B), _showPendingDragPopup)),
        ])),
      ]),
    );
  }

  Widget _buildMainSalesCard(num sales) {
    final formatted = sales >= 100000 ? '₹${(sales / 100000).toStringAsFixed(1)}L' : '₹${sales.toStringAsFixed(0)}';
    return GestureDetector(
      onTap: _showSalesPopup,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF4A5568), Color(0xFF4A5568), Color(0xFF334155)],
          ),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [BoxShadow(color: const Color(0xFF4A5568).withOpacity(0.4), blurRadius: 25, offset: const Offset(0, 12))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: const Color(0xFF22C55E), borderRadius: BorderRadius.circular(20)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.trending_up, size: 12, color: Colors.white), SizedBox(width: 4), Text('+12%', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))])),
            const Spacer(),
            const Icon(Icons.auto_graph_rounded, color: Colors.white24, size: 28),
          ]),
          const Spacer(),
          Text(formatted, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -1)),
          const SizedBox(height: 4),
          Row(children: [
            Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF22C55E), shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text("Today's Revenue", style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7))),
          ]),
        ]),
      ),
    );
  }

  Widget _buildMiniStatPill(String emoji, num value, String label, Color color, VoidCallback onTap) {
    final formatted = value >= 1000 ? '${(value / 1000).toStringAsFixed(1)}K' : value.toStringAsFixed(0);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.2)),
          boxShadow: [BoxShadow(color: color.withOpacity(0.15), blurRadius: 15, offset: const Offset(0, 5))],
        ),
        child: Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(formatted, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
            Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
          ]),
          const Spacer(),
          Icon(Icons.chevron_right_rounded, color: color.withOpacity(0.5), size: 20),
        ]),
      ),
    );
  }

  // Bento Grid with mixed sizes
  Widget _buildBentoGrid(dynamic packedKgs, dynamic packedCount, dynamic pendingValue, dynamic netStock) {
    return Column(children: [
      // First row: Wide analytics + Square packed
      Row(children: [
        Expanded(flex: 3, child: _buildAnalyticsCard()),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: _buildPackedRingCard(packedKgs, packedCount)),
      ]),
      const SizedBox(height: 12),
      // Second row: Stock distribution + Add Order
      Row(children: [
        Expanded(child: _buildStockDistributionCard(netStock)),
        const SizedBox(width: 12),
        Expanded(child: _buildAddOrderCardV2()),
      ]),
    ]);
  }

  Widget _buildAnalyticsCard() {
    return GestureDetector(
      onTap: _showInsightsPopup,
      child: Container(
        height: 150,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.white, Colors.white.withOpacity(0.9)]),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.insights_rounded, color: Color(0xFF5D6E7E), size: 20),
            const SizedBox(width: 8),
            const Text('Weekly', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1F2937))),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(10)),
              child: const Text('+8.5%', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF16A34A)))),
          ]),
          const SizedBox(height: 12),
          Expanded(child: _buildMiniBarChartV2()),
        ]),
      ),
    );
  }

  Widget _buildMiniBarChartV2() {
    final List<double> data = [0.4, 0.6, 0.5, 0.8, 0.7, 0.9, 0.5];
    final List<Color> colors = [const Color(0xFF5D6E7E), const Color(0xFF10B981), const Color(0xFF4A5568)];
    return Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: data.asMap().entries.map((e) {
      final color = colors[e.key % colors.length];
      return Container(
        width: 12, height: 60 * e.value,
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color, color.withOpacity(0.5)]),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }).toList());
  }

  Widget _buildPackedRingCard(dynamic packedKgs, dynamic packedCount) {
    final kgs = packedKgs is num ? packedKgs : (num.tryParse('$packedKgs') ?? 0);
    final count = packedCount is num ? packedCount : (num.tryParse('$packedCount') ?? 0);
    return GestureDetector(
      onTap: _showPackedDragPopup,
      child: Container(
        height: 150,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFDF2F8), Color(0xFFFCE7F3)]),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFF9A8D4).withOpacity(0.3)),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Stack(alignment: Alignment.center, children: [
            SizedBox(width: 60, height: 60, child: CircularProgressIndicator(value: 0.7, strokeWidth: 6, backgroundColor: const Color(0xFFFBCFE8), valueColor: const AlwaysStoppedAnimation(Color(0xFFEC4899)))),
            Text('$count', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFBE185D))),
          ]),
          const SizedBox(height: 8),
          Text('${kgs.toStringAsFixed(0)} kg', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF9D174D))),
          const Text('Packed', style: TextStyle(fontSize: 10, color: Color(0xFFBE185D))),
        ]),
      ),
    );
  }

  Widget _buildStockDistributionCard(dynamic netStock) {
    return GestureDetector(
      onTap: _showStockPopup,
      child: Container(
        height: 120,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFECFDF5), Color(0xFFD1FAE5)]),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF6EE7B7).withOpacity(0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.donut_large_rounded, color: Color(0xFF059669), size: 18),
            const SizedBox(width: 8),
            const Text('Stock Mix', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF047857))),
          ]),
          const Spacer(),
          Row(children: [
            _buildMiniDonut(0.6, const Color(0xFF5D6E7E)),
            const SizedBox(width: 6),
            _buildMiniDonut(0.25, const Color(0xFF10B981)),
            const SizedBox(width: 6),
            _buildMiniDonut(0.15, const Color(0xFFEF4444)),
            const Spacer(),
            const Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('View All', style: TextStyle(fontSize: 10, color: Color(0xFF059669))),
              Icon(Icons.arrow_forward, size: 14, color: Color(0xFF059669)),
            ]),
          ]),
        ]),
      ),
    );
  }

  Widget _buildMiniDonut(double value, Color color) {
    return SizedBox(width: 28, height: 28, child: Stack(alignment: Alignment.center, children: [
      CircularProgressIndicator(value: value, strokeWidth: 4, backgroundColor: color.withOpacity(0.2), valueColor: AlwaysStoppedAnimation(color)),
      Text('${(value * 100).toInt()}', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: color)),
    ]));
  }

  Widget _buildAddOrderCardV2() {
    return GestureDetector(
      onTap: () => _nav('/new_order'),
      child: Container(
        height: 120,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF4A5568), Color(0xFF4A5568)]),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: const Color(0xFF4A5568).withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.add_rounded, color: Colors.white, size: 20)),
            const Spacer(),
            const Icon(Icons.arrow_outward_rounded, color: Colors.white54, size: 18),
          ]),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('New Order', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
            Text('Quick create', style: TextStyle(fontSize: 10, color: Colors.white70)),
          ]),
        ]),
      ),
    );
  }

  // Live Activity Card
  Widget _buildLiveActivityCard() {
    final pending = _pendingOrders;
    final recent = pending.isNotEmpty ? pending.take(2).toList() : [];
    
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF22C55E), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          const Text('Live Activity', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1F2937))),
          const Spacer(),
          GestureDetector(onTap: () => _nav('/view_orders'), child: const Text('See all', style: TextStyle(fontSize: 12, color: Color(0xFF5D6E7E), fontWeight: FontWeight.w500))),
        ]),
        const SizedBox(height: 16),
        if (recent.isEmpty)
          const Center(child: Text('No recent activity', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13)))
        else
          ...recent.map((order) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              Container(width: 40, height: 40, decoration: BoxDecoration(gradient: LinearGradient(colors: [const Color(0xFF5D6E7E).withOpacity(0.1), const Color(0xFF4A5568).withOpacity(0.1)]), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.receipt_long_outlined, color: Color(0xFF5D6E7E), size: 18)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(order['client']?.toString() ?? 'Unknown', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)), overflow: TextOverflow.ellipsis),
                Text('${order['grade']} • ${order['kgs']} kg', style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
              ])),
              Text('₹${order['price']}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
            ]),
          )),
      ]),
    );
  }

  // Quick Actions Bar
  Widget _buildQuickActionsBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF4A5568), Color(0xFF4A5568)]),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        _buildQuickActionItem(Icons.inventory_2_outlined, 'Stock', _showStockPopup),
        _buildQuickActionItem(Icons.receipt_long_outlined, 'Orders', () => _nav('/view_orders')),
        _buildQuickActionItem(Icons.monetization_on_outlined, 'Sales', _showSalesPopup),
        _buildQuickActionItem(Icons.track_changes_rounded, 'Allocator', _showAllocationPopup),
        _buildQuickActionItem(Icons.insights_rounded, 'Insights', _showInsightsPopup),
      ]),
    );
  }

  Widget _buildQuickActionItem(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: Colors.white, size: 22)),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _buildCategoryCard(String emoji, String title, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color.withOpacity(0.15), color.withOpacity(0.05)]),
          border: Border.all(color: color.withOpacity(0.3), width: 1),
          boxShadow: [BoxShadow(color: color.withOpacity(0.2), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 28)),
                  const SizedBox(height: 8),
                  Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color.withOpacity(0.9))),
                  const SizedBox(height: 4),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('View', style: TextStyle(fontSize: 11, color: color.withOpacity(0.7))),
                    const SizedBox(width: 2),
                    Icon(Icons.arrow_forward_ios, size: 10, color: color.withOpacity(0.7)),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showStockPopup() {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)]),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5))],
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF5D6E7E), borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                  const Text('📦', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
                  const Expanded(child: Text('Stock Intelligence', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ])),
                const Divider(height: 1),
              ]),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(child: _buildStockSection()),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  void _showSalesPopup() {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)]), borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5))]),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                  const Text('💰', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
                  const Expanded(child: Text('Sales Snapshot', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ])),
                const Divider(height: 1),
              ]),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(child: _buildSalesSnapshot()),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  void _showAllocationPopup() {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)]), borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5))]),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                  const Text('🎯', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
                  const Expanded(child: Text('Allocation', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ])),
                const Divider(height: 1),
              ]),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(child: _buildAllocationSection()),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  void _showActionsPopup() {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)]), borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5))]),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                  const Text('⚡', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
                  const Expanded(child: Text('Quick Actions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ])),
                const Divider(height: 1),
              ]),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Wrap(spacing: 12, runSpacing: 12, children: [
                  _buildActionTile('➕ New Order', () { Navigator.pop(context); _nav('/new_order'); }),
                  _buildActionTile('📋 View Orders', () { Navigator.pop(context); _nav('/view_orders'); }),
                  _buildActionTile('📈 Sales Summary', () { Navigator.pop(context); _nav('/sales_summary'); }),
                  _buildActionTile('🧺 Add To Cart', () { Navigator.pop(context); _nav('/add_to_cart'); }),
                  _buildActionTile('📅 Daily Cart', () { Navigator.pop(context); _nav('/daily_cart'); }),
                  _buildActionTile('🎯 Grade Allocator', () { Navigator.pop(context); _nav('/grade_allocator'); }),
                  _buildActionTile('📨 Order Requests', () { Navigator.pop(context); _nav('/order_requests'); }),
                  _buildActionTile('✅ Pending Approvals', () { Navigator.pop(context); _nav('/pending_approvals'); }),
                  _buildActionTile('⚙️ Admin Panel', () { Navigator.pop(context); _nav('/admin'); }),
                  _buildActionTile('🔄 Refresh', () { Navigator.pop(context); _loadData(); }),
                ]),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  Widget _buildActionTile(String label, VoidCallback onTap) {
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))]),
      child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
    ));
  }

  void _showInsightImplementationModal(Insight insight) {
    final Color accentColor = insight.priority == 'critical' 
        ? const Color(0xFFEF4444) 
        : insight.priority == 'high' 
            ? const Color(0xFF5D6E7E)
            : const Color(0xFF5D6E7E); // All priorities use steel blue
    
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB)], // Titanium light gradient
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  // Handle
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Header
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: accentColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(insight.icon, style: const TextStyle(fontSize: 24)),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(insight.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: accentColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                insight.priority.toUpperCase(),
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: accentColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Description
                  Text(
                    insight.description,
                    style: const TextStyle(fontSize: 14, color: Color(0xFF475569), height: 1.5),
                  ),
                  // Substitutions
                  if (insight.substitutions != null && insight.substitutions!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text('Recommended Alternatives:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: insight.substitutions!.map((sub) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                        ),
                        child: Text(sub, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
                      )).toList(),
                    ),
                  ],
                  const SizedBox(height: 32),
                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Center(
                              child: Text('Dismiss', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: GestureDetector(
                          onTap: () {
                            Navigator.pop(context);
                            HapticFeedback.heavyImpact();
                            // Execute the action based on insight type
                            if (insight.action == 'add_to_cart' || insight.type == 'dispatch_opportunity') {
                              // INTELLIGENT DISPATCH: Open allocator with prefilled data
                              Navigator.pushNamed(
                                context, 
                                '/grade_allocator',
                                arguments: {
                                  'prefillGrade': insight.grade,
                                  'prefillQty': insight.value,
                                  'insightTitle': insight.title,
                                },
                              );
                            } else if (insight.action == 'stock_calculator') {
                              _nav('/stock_tools');
                            } else if (insight.action == 'view_orders') {
                              // For Priority Client - open client ledger directly
                              Navigator.pop(context); // close the insight modal
                              if (insight.client != null && insight.client!.isNotEmpty) {
                                Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => ClientLedgerDetailScreen(clientName: insight.client!),
                                ));
                              } else {
                                _nav('/ledger');
                              }
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('✅ Implementing: ${insight.title}'),
                                  backgroundColor: const Color(0xFF10B981),
                                ),
                              );
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [accentColor, accentColor.withOpacity(0.8)]),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [BoxShadow(color: accentColor.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))],
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.bolt_rounded, color: Colors.white, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  insight.action == 'add_to_cart' ? 'Dispatch Now' 
                                      : insight.action == 'stock_calculator' ? 'Check Stock'
                                      : insight.action == 'view_orders' ? 'View Ledger'
                                      : 'Implement Now',
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showNotificationsPanel() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Notifications',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return Align(
          alignment: Alignment.topCenter,
          child: Material(
            color: Colors.transparent,
            child: Container(
              margin: EdgeInsets.only(
                top: MediaQuery.of(dialogContext).padding.top + 10,
                left: 12,
                right: 12,
              ),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(dialogContext).size.height * 0.7,
              ),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB)],
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.notifications_active_rounded, color: Color(0xFFEF4444), size: 20),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text('Notifications', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            Navigator.pushNamed(context, '/notifications');
                          },
                          child: const Text('View All', style: TextStyle(fontSize: 12, color: Color(0xFF10B981), fontWeight: FontWeight.w600)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Mark all as read', style: TextStyle(fontSize: 12, color: Color(0xFF5D6E7E))),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B), size: 20),
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                  // Task and Notification list
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // User Tasks Section (non-dismissible)
                          if (_userTasks.where((t) => t.status == TaskStatus.ongoing || t.status == TaskStatus.pending).isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                              child: Text(
                                'MY TASKS',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.grey[600],
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            ..._userTasks
                                .where((t) => t.status == TaskStatus.ongoing || t.status == TaskStatus.pending)
                                .map((task) {
                              final isOngoing = task.status == TaskStatus.ongoing;
                              final priorityColor = task.priority == 'high'
                                  ? Colors.red
                                  : task.priority == 'medium'
                                      ? Colors.orange
                                      : Colors.blue;
                              return Container(
                                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isOngoing ? const Color(0xFFFFF7ED) : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isOngoing ? Colors.orange.shade200 : const Color(0xFFE2E8F0),
                                  ),
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  leading: Container(
                                    width: 8,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: priorityColor,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  title: Text(
                                    task.title,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF4A5568),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isOngoing ? Colors.orange : Colors.blue,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          isOngoing ? 'ONGOING' : 'PENDING',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: priorityColor.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          task.priority.toUpperCase(),
                                          style: TextStyle(
                                            color: priorityColor,
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  trailing: isOngoing
                                      ? IconButton(
                                          icon: const Icon(Icons.check_circle, color: Colors.green, size: 28),
                                          onPressed: () {
                                            _markTaskComplete(task);
                                            Navigator.pop(dialogContext);
                                          },
                                        )
                                      : const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
                                  onTap: () {
                                    Navigator.pop(dialogContext);
                                    Navigator.pushNamed(context, '/worker_tasks');
                                  },
                                ),
                              );
                            }).toList(),
                            const SizedBox(height: 8),
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 20),
                              height: 1,
                              color: const Color(0xFFE2E8F0),
                            ),
                          ],
                          // Approval Requests Section (for admin only) with approve/reject icons
                          Consumer<NotificationService>(
                            builder: (ctx, notifService, _) {
                              final role = Provider.of<AuthProvider>(ctx, listen: false).role?.toLowerCase() ?? '';
                              final isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
                              final pendingApprovals = notifService.pendingApprovals;

                              if (!isAdmin || pendingApprovals.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                                    child: Row(
                                      children: [
                                        Text(
                                          'APPROVAL REQUESTS',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.grey[600],
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEF4444),
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            '${pendingApprovals.length}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ...pendingApprovals.map((request) {
                                    final isDelete = request.actionType == 'delete';
                                    final actionColor = isDelete ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
                                    final actionIcon = isDelete ? Icons.delete_rounded : Icons.edit_rounded;
                                    final actionLabel = isDelete ? 'Delete' : 'Edit';
                                    
                                    // Build resource description
                                    String resourceDesc = '${request.resourceType} #${request.resourceId}';
                                    final data = request.resourceData;
                                    if (data != null) {
                                      final client = data['client'] ?? '';
                                      final lot = data['lot'] ?? '';
                                      final grade = data['grade'] ?? '';
                                      if (client.toString().isNotEmpty && lot.toString().isNotEmpty) {
                                        resourceDesc = '$client - $lot${grade.toString().isNotEmpty ? ' ($grade)' : ''}';
                                      }
                                    }
                                    
                                    // Format time ago
                                    final diff = DateTime.now().difference(request.createdAt);
                                    String timeAgo;
                                    if (diff.inMinutes < 60) {
                                      timeAgo = '${diff.inMinutes}m ago';
                                    } else if (diff.inHours < 24) {
                                      timeAgo = '${diff.inHours}h ago';
                                    } else {
                                      timeAgo = '${diff.inDays}d ago';
                                    }
                                    
                                    return GestureDetector(
                                      onTap: () {
                                        // Show full request details popup
                                        _showRequestDetailsPopup(context, request, isAdmin: true, notifService: notifService, dialogContext: dialogContext);
                                      },
                                      child: Container(
                                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: actionColor.withOpacity(0.2)),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.04),
                                            blurRadius: 8,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          // Action type icon
                                          Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: actionColor.withOpacity(0.1),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(actionIcon, color: actionColor, size: 16),
                                          ),
                                          const SizedBox(width: 10),
                                          // Request info
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: actionColor.withOpacity(0.1),
                                                        borderRadius: BorderRadius.circular(4),
                                                      ),
                                                      child: Text(
                                                        actionLabel,
                                                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: actionColor),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      child: Text(
                                                        request.requesterName,
                                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  resourceDesc,
                                                  style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                Text(
                                                  timeAgo,
                                                  style: const TextStyle(fontSize: 9, color: Color(0xFF94A3B8)),
                                                ),
                                              ],
                                            ),
                                          ),
                                          // Approve/Reject buttons on right side
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              // Approve (tick) button
                                              GestureDetector(
                                                onTap: () async {
                                                  final prefs = await SharedPreferences.getInstance();
                                                  final adminId = prefs.getString('userId') ?? '';
                                                  final adminName = prefs.getString('username') ?? 'Admin';

                                                  fireAndForget(
                                                    type: 'approve_request',
                                                    apiCall: () async {
                                                      final success = await notifService.approveRequest(request.id, adminId, adminName);
                                                      if (!success) throw Exception('Approval failed');
                                                      notifService.removeApprovalRequest(request.id);
                                                    },
                                                    successMessage: 'Request approved',
                                                    failureMessage: 'Failed to approve request',
                                                  );
                                                },
                                                child: Container(
                                                  width: 32,
                                                  height: 32,
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF10B981).withOpacity(0.1),
                                                    borderRadius: BorderRadius.circular(8),
                                                    border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                                                  ),
                                                  child: const Icon(Icons.check_rounded, color: Color(0xFF10B981), size: 18),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              // Reject (X) button
                                              GestureDetector(
                                                onTap: () async {
                                                  final reasonController = TextEditingController();
                                                  
                                                  final confirmed = await showDialog<bool>(
                                                    context: dialogContext,
                                                    builder: (ctx) => AlertDialog(
                                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                                      title: const Text('Reject Request'),
                                                      content: Column(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          Text(
                                                            'Reject ${request.actionType} request from ${request.requesterName}?',
                                                            style: const TextStyle(color: Color(0xFF64748B)),
                                                          ),
                                                          const SizedBox(height: 16),
                                                          TextField(
                                                            controller: reasonController,
                                                            decoration: InputDecoration(
                                                              labelText: 'Reason (optional)',
                                                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                                            ),
                                                            maxLines: 2,
                                                          ),
                                                        ],
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () => Navigator.pop(ctx, false),
                                                          child: const Text('Cancel'),
                                                        ),
                                                        ElevatedButton(
                                                          onPressed: () => Navigator.pop(ctx, true),
                                                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                                                          child: const Text('Reject'),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                  
                                                  if (confirmed != true) return;

                                                  final prefs = await SharedPreferences.getInstance();
                                                  final adminId = prefs.getString('userId') ?? '';
                                                  final adminName = prefs.getString('username') ?? 'Admin';
                                                  final reason = reasonController.text.isNotEmpty ? reasonController.text : 'No reason provided';

                                                  fireAndForget(
                                                    type: 'reject_request',
                                                    apiCall: () async {
                                                      final success = await notifService.rejectRequest(request.id, adminId, adminName, reason);
                                                      if (!success) throw Exception('Rejection failed');
                                                      notifService.removeApprovalRequest(request.id);
                                                    },
                                                    successMessage: 'Request rejected',
                                                    failureMessage: 'Failed to reject request',
                                                  );
                                                },
                                                child: Container(
                                                  width: 32,
                                                  height: 32,
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFEF4444).withOpacity(0.1),
                                                    borderRadius: BorderRadius.circular(8),
                                                    border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
                                                  ),
                                                  child: const Icon(Icons.close_rounded, color: Color(0xFFEF4444), size: 18),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ));  // Close GestureDetector
                                  }).toList(),
                                  const SizedBox(height: 8),
                                  Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 20),
                                    height: 1,
                                    color: const Color(0xFFE2E8F0),
                                  ),
                                ],
                              );
                            },
                          ),
                          // MY REQUESTS Section (for all users to see their own requests)
                          Consumer<NotificationService>(
                            builder: (ctx, notifService, _) {
                              final myRequests = notifService.myRequestsUnread;
                              final role = Provider.of<AuthProvider>(ctx, listen: false).role?.toLowerCase() ?? '';
                              final isAdminRole = role == 'superadmin' || role == 'admin' || role == 'ops';

                              if (myRequests.isEmpty) {
                                return const SizedBox.shrink();
                              }

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                                    child: Row(
                                      children: [
                                        Text(
                                          'MY REQUESTS',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.grey[600],
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Icon(Icons.send, size: 14, color: Color(0xFF3B82F6)),
                                      ],
                                    ),
                                  ),
                                  ...myRequests.map((request) {
                                    final isPending = request.status == 'pending';
                                    final isApproved = request.status == 'approved';
                                    final canDismiss = !isPending;

                                    Color statusColor;
                                    IconData statusIcon;
                                    String statusText;
                                    Color bgColor;

                                    if (isPending) {
                                      statusColor = const Color(0xFFF59E0B);
                                      statusIcon = Icons.hourglass_top;
                                      statusText = 'Pending';
                                      bgColor = const Color(0xFFFEFCE8);
                                    } else if (isApproved) {
                                      statusColor = const Color(0xFF10B981);
                                      statusIcon = Icons.check_circle;
                                      statusText = 'Approved';
                                      bgColor = const Color(0xFFECFDF5);
                                    } else {
                                      statusColor = const Color(0xFFEF4444);
                                      statusIcon = Icons.cancel;
                                      statusText = 'Rejected';
                                      bgColor = const Color(0xFFFEF2F2);
                                    }

                                    // Format time ago
                                    final diff = DateTime.now().difference(request.createdAt);
                                    String timeAgo;
                                    if (diff.inMinutes < 1) {
                                      timeAgo = 'Just now';
                                    } else if (diff.inMinutes < 60) {
                                      timeAgo = '${diff.inMinutes}m ago';
                                    } else if (diff.inHours < 24) {
                                      timeAgo = '${diff.inHours}h ago';
                                    } else {
                                      timeAgo = '${diff.inDays}d ago';
                                    }

                                    final cardWidget = GestureDetector(
                                      onTap: () {
                                        _showRequestDetailsPopup(context, request, isAdmin: false, notifService: notifService, dialogContext: dialogContext);
                                      },
                                      child: Container(
                                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: bgColor,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: statusColor.withOpacity(0.3)),
                                      ),
                                      child: Row(
                                        children: [
                                          // Status icon
                                          Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: statusColor.withOpacity(0.1),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(statusIcon, color: statusColor, size: 16),
                                          ),
                                          const SizedBox(width: 10),
                                          // Request info
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '${request.actionType.substring(0, 1).toUpperCase()}${request.actionType.substring(1)} ${request.resourceType}',
                                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                                                ),
                                                if (request.requesterName.isNotEmpty)
                                                  Text(
                                                    'From: ${request.requesterName}',
                                                    style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                                                  ),
                                                Text(
                                                  timeAgo,
                                                  style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                                                ),
                                              ],
                                            ),
                                          ),
                                          // Show tick/x action buttons for admin on pending cards
                                          if (isAdminRole && isPending) ...[
                                            GestureDetector(
                                              onTap: () async {
                                                final prefs = await SharedPreferences.getInstance();
                                                final adminId = prefs.getString('userId') ?? '';
                                                final adminName = prefs.getString('username') ?? 'Admin';
                                                if (adminId.isEmpty) {
                                                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User ID not found. Please log in again.'), backgroundColor: Color(0xFFEF4444)));
                                                  return;
                                                }
                                                // Show loading
                                                showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
                                                try {
                                                  final success = await notifService.approveRequest(request.id, adminId, adminName);
                                                  if (success) {
                                                    notifService.removeApprovalRequest(request.id);
                                                    notifService.fetchMyRequests();
                                                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request approved'), backgroundColor: Color(0xFF10B981)));
                                                  } else if (context.mounted) {
                                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to approve request'), backgroundColor: Color(0xFFEF4444)));
                                                  }
                                                } catch (e) {
                                                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFEF4444)));
                                                } finally {
                                                  if (context.mounted) Navigator.pop(context);
                                                }
                                              },
                                              child: Container(
                                                width: 32,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF10B981).withOpacity(0.1),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                                                ),
                                                child: const Icon(Icons.check_rounded, color: Color(0xFF10B981), size: 18),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            GestureDetector(
                                              onTap: () async {
                                                final reasonController = TextEditingController();
                                                final confirmed = await showDialog<bool>(
                                                  context: context,
                                                  builder: (rctx) => AlertDialog(
                                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                                    title: const Text('Reject Request'),
                                                    content: TextField(controller: reasonController, decoration: InputDecoration(labelText: 'Reason (optional)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))), maxLines: 2),
                                                    actions: [
                                                      TextButton(onPressed: () => Navigator.pop(rctx, false), child: const Text('Cancel')),
                                                      ElevatedButton(onPressed: () => Navigator.pop(rctx, true), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)), child: const Text('Reject')),
                                                    ],
                                                  ),
                                                );
                                                if (confirmed != true) {
                                                  reasonController.dispose();
                                                  return;
                                                }
                                                final prefs = await SharedPreferences.getInstance();
                                                final adminId = prefs.getString('userId') ?? '';
                                                final adminName = prefs.getString('username') ?? 'Admin';
                                                final reason = reasonController.text.isNotEmpty ? reasonController.text : 'No reason provided';
                                                reasonController.dispose();
                                                if (adminId.isEmpty) {
                                                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User ID not found. Please log in again.'), backgroundColor: Color(0xFFEF4444)));
                                                  return;
                                                }
                                                showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
                                                try {
                                                  final success = await notifService.rejectRequest(request.id, adminId, adminName, reason);
                                                  if (success) {
                                                    notifService.removeApprovalRequest(request.id);
                                                    notifService.fetchMyRequests();
                                                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request rejected'), backgroundColor: Color(0xFFEF4444)));
                                                  } else if (context.mounted) {
                                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to reject request'), backgroundColor: Color(0xFFEF4444)));
                                                  }
                                                } catch (e) {
                                                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFEF4444)));
                                                } finally {
                                                  if (context.mounted) Navigator.pop(context);
                                                }
                                              },
                                              child: Container(
                                                width: 32,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFEF4444).withOpacity(0.1),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
                                                ),
                                                child: const Icon(Icons.close_rounded, color: Color(0xFFEF4444), size: 18),
                                              ),
                                            ),
                                          ] else
                                            // Status badge for non-admin or non-pending
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: statusColor.withOpacity(0.1),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: statusColor.withOpacity(0.3)),
                                              ),
                                              child: Text(
                                                statusText,
                                                style: TextStyle(
                                                  color: statusColor,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ));

                                    if (canDismiss) {
                                      return Dismissible(
                                        key: Key(request.id),
                                        direction: DismissDirection.endToStart,
                                        confirmDismiss: (direction) async {
                                          return await notifService.dismissRequest(request.id);
                                        },
                                        background: Container(
                                          alignment: Alignment.centerRight,
                                          padding: const EdgeInsets.only(right: 16),
                                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF94A3B8),
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: const Icon(Icons.check, color: Colors.white, size: 18),
                                        ),
                                        child: cardWidget,
                                      );
                                    }
                                    return cardWidget;
                                  }).toList(),
                                  const SizedBox(height: 8),
                                  Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 20),
                                    height: 1,
                                    color: const Color(0xFFE2E8F0),
                                  ),
                                ],
                              );
                            },
                          ),
                          // System Notifications Section (dismissible)
                          Consumer<NotificationService>(
                            builder: (ctx, service, _) {
                              final notifications = service.notifications;
                              final myRequests = service.myRequests;
                              final hasTasks = _userTasks.where((t) => t.status == TaskStatus.ongoing || t.status == TaskStatus.pending).isNotEmpty;
                              final role = Provider.of<AuthProvider>(ctx, listen: false).role?.toLowerCase() ?? '';
                              final isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
                              final hasAdminApprovals = isAdmin && service.pendingApprovals.isNotEmpty;

                              // Show "No notifications" only if nothing to show
                              if (notifications.isEmpty && myRequests.isEmpty && !hasTasks && !hasAdminApprovals) {
                                return Padding(
                                  padding: const EdgeInsets.all(40),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.notifications_off_outlined, size: 48, color: Colors.grey[300]),
                                      const SizedBox(height: 12),
                                      Text('No notifications', style: TextStyle(color: Colors.grey[500], fontSize: 14)),
                                    ],
                                  ),
                                );
                              }
                              if (notifications.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                                    child: Text(
                                      'ALERTS',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.grey[600],
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                  ),
                                  ...notifications.map((notification) {
                                    IconData icon;
                                    Color iconColor;
                                    Color bgColor;

                                    switch (notification.type) {
                                      case 'stock':
                                        icon = Icons.inventory_2_rounded;
                                        iconColor = const Color(0xFFEF4444);
                                        bgColor = const Color(0xFFFEE2E2);
                                        break;
                                      case 'orders':
                                        icon = Icons.shopping_cart_rounded;
                                        iconColor = const Color(0xFF5D6E7E);
                                        bgColor = const Color(0xFFE0E7FF);
                                        break;
                                      case 'sync':
                                        icon = Icons.sync_rounded;
                                        iconColor = const Color(0xFF10B981);
                                        bgColor = const Color(0xFFD1FAE5);
                                        break;
                                      case 'alert':
                                        icon = Icons.warning_amber_rounded;
                                        iconColor = const Color(0xFFF59E0B);
                                        bgColor = const Color(0xFFFEF3C7);
                                        break;
                                      default:
                                        icon = Icons.info_outline_rounded;
                                        iconColor = const Color(0xFF64748B);
                                        bgColor = const Color(0xFFF1F5F9);
                                    }

                                    final diff = DateTime.now().difference(notification.timestamp);
                                    String timeAgo;
                                    if (diff.inMinutes < 1) {
                                      timeAgo = 'Just now';
                                    } else if (diff.inMinutes < 60) {
                                      timeAgo = '${diff.inMinutes}m ago';
                                    } else if (diff.inHours < 24) {
                                      timeAgo = '${diff.inHours}h ago';
                                    } else {
                                      timeAgo = '${diff.inDays}d ago';
                                    }

                                    return Dismissible(
                                      key: Key(notification.id),
                                      direction: DismissDirection.endToStart,
                                      background: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.red[400],
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        alignment: Alignment.centerRight,
                                        padding: const EdgeInsets.only(right: 20),
                                        child: const Icon(Icons.delete_rounded, color: Colors.white),
                                      ),
                                      onDismissed: (_) {
                                        service.removeNotification(notification.id);
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: notification.isRead ? Colors.white : const Color(0xFFF8FAFC),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: const Color(0xFFE2E8F0)),
                                        ),
                                        child: ListTile(
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                          leading: Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(10)),
                                            child: Icon(icon, color: iconColor, size: 20),
                                          ),
                                          title: Text(
                                            notification.title,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: notification.isRead ? FontWeight.w500 : FontWeight.bold,
                                              color: const Color(0xFF4A5568),
                                            ),
                                          ),
                                          subtitle: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(notification.body, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                                              const SizedBox(height: 4),
                                              Text(timeAgo, style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                                            ],
                                          ),
                                          onTap: () {
                                            service.markAsRead(notification.id);
                                            Navigator.pop(dialogContext);
                                          },
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -1),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          )),
          child: child,
        );
      },
    );
  }

  void _showInsightsPopup() {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5)),
          ],
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF5D6E7E), borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                  const Text('📊', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
                  const Expanded(child: Text('Insights', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ])),
                const Divider(height: 1),
              ]),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(child: _buildInsightsSection()),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  // Draggable popups for hero cards (matching category card style)
  void _showNetStockDragPopup() {
    // Get full stock data with type (Colour, Fruit, Rejection)
    final netStock = _dashboardData?['netStock'] ?? {};
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    
    // Build structured stock data: { type: { grade: value } }
    final stockByType = <String, Map<String, double>>{};
    for (var row in rows) {
      if (row is List && row.isNotEmpty) {
        final type = row[0]?.toString() ?? 'Unknown';
        stockByType[type] = {};
        for (int i = 1; i < row.length && i < headers.length; i++) {
          final grade = headers[i];
          final val = row[i] is num ? row[i].toDouble() : (num.tryParse('${row[i]}') ?? 0);
          stockByType[type]![grade] = val;
        }
      }
    }
    
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5)),
          ],
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF5D6E7E), borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                  const Text('📦', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
                  const Expanded(child: Text('Net Stock Balance', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ])),
                const Divider(height: 1),
              ]),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: StockAccordion(
                  netStock: netStock,
                  virtualGrades: virtualGrades,
                  stockTypes: const ['Colour Bold', 'Fruit Bold', 'Rejection'],
                  initiallyExpanded: true,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  void _showPendingDragPopup() {
    _onPendingViewed(); // V6: Track intent
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)]), borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5))]),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                  const Text('🧾', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
                  const Expanded(child: Text('Pending Orders', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ])),
                const Divider(height: 1),
              ]),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: _PendingOrdersDragContent(pendingOrders: _sortByUrgency(_pendingOrders), scrollController: ScrollController(), onRefresh: _loadData),
            ),
          ],
        ),
      ),
    );
  }

  void _showPackedDragPopup() {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB), Color(0xFFA8A8A1)]), borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, -5))]),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                  const Text('🚚', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
                  const Expanded(child: Text("Today's Packed", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ])),
                const Divider(height: 1),
              ]),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: _DailyCartDragContent(todayCart: _todayCart, scrollController: ScrollController(), onCancelDispatch: (lot, client) async {
                Navigator.pop(context);
                fireAndForget(
                  type: 'cancel_dispatch',
                  apiCall: () => _apiService.cancelPartialDispatch(lot, client),
                  successMessage: 'Dispatch cancelled successfully',
                  failureMessage: 'Failed to cancel dispatch',
                  onSuccess: () => _loadData(),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  // Content builders for hero card popups
  Widget _buildAvailableStockContent() {
    final netStock = _dashboardData?['netStock'] ?? {};
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    final availableItems = <Map<String, dynamic>>[];
    for (var row in rows) {
      if (row is List && row.isNotEmpty) {
        for (int i = 1; i < row.length && i < headers.length; i++) {
          if (absGrades.contains(headers[i])) {
            final val = row[i] is num ? row[i].toDouble() : (num.tryParse('${row[i]}') ?? 0);
            if (val > 0) availableItems.add({'grade': headers[i], 'type': row[0], 'value': val});
          }
        }
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Available Stock (Absolute Grades)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[800])),
      const SizedBox(height: 12),
      ...availableItems.map((item) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0))),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('${item['type']} - ${item['grade']}', style: const TextStyle(fontSize: 14)),
          Text('${(item['value'] as num).round()} kg', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
        ]),
      )),
      if (availableItems.isEmpty) const Text('No available stock items.', style: TextStyle(color: Colors.grey)),
    ]);
  }

  Widget _buildPendingOrdersContent() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Pending Orders - ${_pendingOrders.length} items', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[800])),
      const SizedBox(height: 12),
      ..._pendingOrders.take(20).map((order) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${order['client']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('${order['grade']} - ${order['kgs']} kg @ ₹${order['price']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      )),
      if (_pendingOrders.isEmpty) const Text('No pending orders.', style: TextStyle(color: Colors.grey)),
    ]);
  }

  Widget _buildTodayCartContent() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text("Today's Packed - ${_todayCart.length} items", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[800])),
      const SizedBox(height: 12),
      ..._todayCart.take(20).map((order) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${order['client']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('${order['grade']} - ${order['kgs']} kg @ ₹${order['price']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      )),
      if (_todayCart.isEmpty) const Text('No packed items today.', style: TextStyle(color: Colors.grey)),
    ]);
  }

  Widget _buildBackgroundBlobs() {
    return AnimatedBuilder(
      animation: _bgAnimationController,
      builder: (context, child) {
        final val = _bgAnimationController.value;
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Vibrant Indigo Blob - Top Right (moves more dramatically)
              Positioned(
                top: -80 + (val * 200),
                right: -100 + (val * 150),
                child: _buildBlob(650, const Color(0xFF5D6E7E).withOpacity(0.15)),
              ),
              // Rose/Pink Blob - Bottom Left (moves more dramatically)
              Positioned(
                bottom: 50 + (val * 250),
                left: -150 + (val * 200),
                child: _buildBlob(750, const Color(0xFFEC4899).withOpacity(0.12)),
              ),
              // Azure/Blue Blob - Center Right (moves more dramatically)
              Positioned(
                top: 100 + (val * 180),
                right: -200 + (val * 250),
                child: _buildBlob(600, const Color(0xFF5D6E7E).withOpacity(0.14)),
              ),
              // Emerald/Cyan Blob - Bottom Right (moves more dramatically)
              Positioned(
                bottom: -100 + (val * 200),
                right: -80 + (val * 150),
                child: _buildBlob(550, const Color(0xFF10B981).withOpacity(0.10)),
              ),
            ],
          ),
        );
      },
    );
  }
  Widget _buildShimmerOverlay() {
    return AnimatedBuilder(
      animation: _shimmerAnimationController,
      builder: (context, child) {
        final val = _shimmerAnimationController.value;
        return IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: [
                  (val - 0.3).clamp(0.0, 1.0),
                  val.clamp(0.0, 1.0),
                  (val + 0.3).clamp(0.0, 1.0),
                ],
                colors: [
                  Colors.white.withOpacity(0),
                  Colors.white.withOpacity(0.06),
                  Colors.white.withOpacity(0),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBlob(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color,
            color.withOpacity(0),
          ],
        ),
      ),
    );
  }


  Widget _buildHeroGrid() {
    final stockHealth = _dashboardData?['stockHealth'] ?? {};
    final totalStock = _dashboardData?['totalStock'] ?? 0;
    final isHealthy = (stockHealth['criticalCount'] ?? 0) == 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isMobile = screenWidth < 600;
        
        // Mobile: 2-column grid matching category cards
        if (isMobile) {
          return GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.4,
            children: [
              _buildMiniHeroCard('📦', 'Net Stock', '$totalStock', isHealthy ? const Color(0xFF10B981) : const Color(0xFFEF4444), _showNetStockDragPopup),
              _buildMiniHeroCard('🧾', 'Pending', '${_dashboardData?['pendingQty'] ?? '—'}', const Color(0xFF5D6E7E), _showPendingDragPopup),
              _buildMiniHeroCard('🚚', 'Packed', '${_dashboardData?['todayPackedKgs'] ?? '—'}', const Color(0xFFEC4899), _showPackedDragPopup),
              _buildMiniHeroCard('➕', 'Add Order', '', const Color(0xFF22C55E), () => _nav('/new_order')),
            ],
          );
        }
        
        // Desktop: full width cards
        final cardWidth = constraints.maxWidth > 900 ? (constraints.maxWidth - 36) / 3 : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            InkWell(
              onTap: _showAvailableStockModal,
              borderRadius: BorderRadius.circular(28),
              child: HeroCard(
                title: '📦 Net Stock (Absolute)',
                value: '$totalStock',
                subtitle: 'Absolute grades only',
                color: isHealthy ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                width: cardWidth,
                statusBadge: isHealthy ? 'Healthy' : 'Attention',
              ),
            ),
            InkWell(
              onTap: _showPendingOrdersModal,
              borderRadius: BorderRadius.circular(28),
              child: HeroCard(
                title: '🧾 Pending Quantity',
                value: '${_dashboardData?['pendingQty'] ?? '—'}',
                subtitle: 'Awaiting dispatch (kg)',
                color: const Color(0xFF5D6E7E),
                width: cardWidth,
              ),
            ),
            InkWell(
              onTap: _showDailyCartModal,
              borderRadius: BorderRadius.circular(28),
              child: HeroCard(
                title: '🚚 Today\'s Packed',
                value: '${_dashboardData?['todayPackedKgs'] ?? '—'}',
                subtitle: 'Lots: ${_dashboardData?['todayPackedCount'] ?? '—'} • ₹ ${_dashboardData?['todaySalesVal'] ?? '—'}',
                color: const Color(0xFFEC4899),
                width: cardWidth,
              ),
            ),
          ],
        );
      },
    );
  }

  // Compact hero card for mobile view
  Widget _buildMiniHeroCard(String emoji, String title, String value, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color.withOpacity(0.15), color.withOpacity(0.05)]),
          border: Border.all(color: color.withOpacity(0.3), width: 1),
          boxShadow: [BoxShadow(color: color.withOpacity(0.2), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 6),
                      Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color.withOpacity(0.8))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }


  static const List<String> absGrades = [
    '8 mm', '7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below'
  ];

  // Virtual grades (sales grades - "illusion" derived from absolute grades)
  static const List<String> virtualGrades = [
    '8.5 mm', '7.8 bold', '7 to 8 mm', '6.5 to 8 mm', '6.5 to 7.5 mm', '6 to 7 mm', 'Mini Bold', 'Pan'
  ];

  // Liquid Glass section wrapper for consistent styling
  Widget _buildGlassSection({
    required String title,
    required Widget child,
    IconData? icon,
    Color? accentColor,
  }) {
    final color = accentColor ?? const Color(0xFF5D6E7E);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4A5568).withOpacity(0.12), // Enhanced depth
            blurRadius: 44,
            offset: const Offset(0, 16), // Deeper offset for corners
            spreadRadius: -4,
          ),
          BoxShadow(
            color: Colors.white.withOpacity(0.15),
            blurRadius: 0,
            offset: const Offset(0, -1),
            spreadRadius: 0,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
            borderRadius: BorderRadius.circular(32),
          ),
          child: LiquidGlass.withOwnLayer(
            settings: const LiquidGlassSettings(
              blur: 30,
              glassColor: Colors.white10,
              thickness: 10,
            ),
            shape: LiquidRoundedSuperellipse(borderRadius: 32),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Glass Pill Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: color.withOpacity(0.2), width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 16, color: color),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: color,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStockSection() {
    final netStock = _dashboardData?['netStock'] ?? {};
    if (netStock.isEmpty) return const Center(child: Text('No stock data available.'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // V7: Stock Intelligence Label
        const Row(
          children: [
            Icon(Icons.auto_graph_rounded, color: Color(0xFF5D6E7E), size: 16),
            SizedBox(width: 8),
            Text('LIVE INVENTORY', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF5D6E7E), letterSpacing: 1.2)),
          ],
        ),
        const SizedBox(height: 16),
        
        // Stock display - using reusable StockAccordion
        StockAccordion(
          netStock: netStock,
          virtualGrades: virtualGrades,
          stockTypes: const ['Colour Bold', 'Fruit Bold', 'Rejection'],
          initiallyExpanded: true,
        ),
        const SizedBox(height: 24),
        
        // Add a Footer hint
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline_rounded, color: Color(0xFF64748B), size: 18),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Negative values indicate stock that has been sold but not yet shipped or allocated.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Stock grid display (replacement for deleted StockAccordion)
  Widget _buildStockGridDisplay(Map<dynamic, dynamic> netStock) {
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    
    if (headers.isEmpty || rows.isEmpty) {
      return const Center(child: Text('No stock data available.'));
    }
    
    // Get grades (headers minus the first "Type" column)
    final grades = headers.sublist(1);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows.map<Widget>((row) {
        if (row is! List || row.isEmpty) return const SizedBox();
        final type = row[0]?.toString() ?? 'Unknown';
        final values = row.sublist(1);
        
        final typeColor = type.toLowerCase().contains('colour') 
            ? const Color(0xFF5D6E7E)
            : type.toLowerCase().contains('fruit')
                ? const Color(0xFF10B981)
                : const Color(0xFFF59E0B);
        
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: typeColor.withOpacity(0.2)),
            boxShadow: [
              BoxShadow(
                color: typeColor.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Type header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: typeColor.withOpacity(0.08),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: typeColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      type,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: typeColor,
                      ),
                    ),
                  ],
                ),
              ),
              // Grade values
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(grades.length, (i) {
                    final grade = grades[i];
                    final val = i < values.length 
                        ? (values[i] is num ? values[i].toDouble() : (num.tryParse('${values[i]}')?.toDouble() ?? 0))
                        : 0.0;
                    
                    final isPositive = val > 0;
                    final isNegative = val < 0;
                    
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: isNegative 
                            ? const Color(0xFFFEE2E2)
                            : isPositive 
                                ? const Color(0xFFDCFCE7)
                                : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isNegative 
                              ? const Color(0xFFFCA5A5)
                              : isPositive 
                                  ? const Color(0xFF86EFAC)
                                  : const Color(0xFFE2E8F0),
                          width: 0.5,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            grade,
                            style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${val.round()} kg',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isNegative 
                                  ? const Color(0xFFDC2626)
                                  : isPositive 
                                      ? const Color(0xFF16A34A)
                                      : const Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildListCard(String title, String subtitle, Color color, double width, List<Widget> children) {
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A5568).withOpacity(0.12),
              blurRadius: 40,
              offset: const Offset(0, 12),
              spreadRadius: -4,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: LiquidGlass.withOwnLayer(
              settings: const LiquidGlassSettings(
                blur: 30,
                glassColor: Colors.white10,
                thickness: 10,
              ),
              shape: LiquidRoundedSuperellipse(borderRadius: 24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF4A5568)), overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.warning_amber_rounded, size: 16, color: color),
                    ],
                  ),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                  const SizedBox(height: 16),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

  Widget _buildAllocationSection() {
    final hint = _dashboardData?['allocatorHint'] ?? {};
    final hintGrade = hint['grade'] ?? '—';
    final hintQty = hint['qty'] ?? '—';
    
    final netStock = _dashboardData?['netStock'] ?? {};
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    
    // Find absolute grades with positive stock (including type)
    List<String> availableGrades = [];
    for (var row in rows) {
      List<dynamic> values = [];
      String rowType = '';
      if (row is List) {
        values = row;
        rowType = values.isNotEmpty ? values[0]?.toString() ?? '' : '';
      } else if (row is Map && row['values'] is List) {
        values = (row['values'] as List<dynamic>?) ?? [];
        rowType = row['type']?.toString() ?? (values.isNotEmpty ? values[0]?.toString() ?? '' : '');
      } else {
        continue;
      }
      
      if (values.isEmpty || rowType.isEmpty) continue;
      
      for (int i = 1; i < values.length && i < headers.length; i++) {
        if (absGrades.contains(headers[i])) {
          final cellValue = values[i];
          final val = cellValue is num 
              ? cellValue.toDouble() 
              : (num.tryParse(cellValue?.toString() ?? '0') ?? 0);
          if (val > 0) {
            availableGrades.add('$rowType - ${headers[i]}: ${val.toStringAsFixed(0)}kg');
          }
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('GRADE ALLOCATION & PLANNING', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF6B7280), letterSpacing: 0.16)),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 900;
            final cardWidth = isWide ? (constraints.maxWidth - 32) / 3 : constraints.maxWidth;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _buildActionCard(
                  '🎯 Allocation / Status', 
                  'Based on today\'s packed lots.', 
                  Icons.track_changes, 
                  cardWidth, 
                  'Best Grade to Pack: $hintGrade\nTotal Pending: $hintQty kg',
                  onPressed: () => _nav('/grade_allocator'),
                  buttonLabel: '🧮 Open Grade Allocator'
                ),
                _buildActionCard(
                  '📦 Available for Allocation', 
                  'Absolute grades with positive stock.', 
                  Icons.inventory_2, 
                  cardWidth, 
                  availableGrades.isEmpty ? 'None' : availableGrades.take(4).join('\n')
                ),
                _buildActionCard(
                  '📋 Pending Orders by Grade', 
                  'Total kgs per grade across all clients.', 
                  Icons.assignment, 
                  cardWidth, 
                  _pendingOrders.isEmpty 
                    ? 'No orders' 
                    : () {
                        final map = <String, double>{};
                        for (var o in _pendingOrders) {
                          final g = o['grade']?.toString() ?? 'Unknown';
                          final k = (num.tryParse(o['kgs'].toString()) ?? 0).toDouble();
                          map[g] = (map[g] ?? 0) + k;
                        }
                        return map.entries.map((e) => '${e.key}: ${e.value.toStringAsFixed(0)}kg').join('\n');
                      }()
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildActionCard(String title, String subtitle, IconData icon, double width, String content, {VoidCallback? onPressed, String? buttonLabel}) {
    final bool isMobile = width < 400;
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A5568).withOpacity(0.12),
              blurRadius: 40,
              offset: const Offset(0, 12),
              spreadRadius: -4,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: LiquidGlass.withOwnLayer(
              settings: const LiquidGlassSettings(
                blur: 30,
                glassColor: Colors.white10,
                thickness: 10,
              ),
              shape: LiquidRoundedSuperellipse(borderRadius: 24),
              child: Padding(
                padding: EdgeInsets.all(isMobile ? 16 : 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 18, color: const Color(0xFF5D6E7E)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                  const SizedBox(height: 12),
                  Text(content, style: const TextStyle(fontSize: 13, color: Color(0xFF4A5568))),
                  if (onPressed != null && buttonLabel != null) ...[
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: onPressed,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 36),
                        backgroundColor: Colors.white.withOpacity(0.12),
                        foregroundColor: const Color(0xFF4A5568),
                        elevation: 0,
                        side: BorderSide(color: Colors.white.withOpacity(0.2)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(buttonLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

  Widget _buildAdminMaintenanceSection() {
    // Recalculate logic for alerts (reused from stock section)
    final netStock = _dashboardData?['netStock'] ?? {};
    final headers = List<String>.from(netStock['headers'] ?? []);
    final rows = List<dynamic>.from(netStock['rows'] ?? []);
    final shortages = <Map<String, dynamic>>[];
    final lowStock = <Map<String, dynamic>>[];

    for (var row in rows) {
      if (row is List) {
        if (row.isEmpty) continue;
        final rowType = row[0]?.toString() ?? '';
        for (int i = 1; i < row.length; i++) {
          if (i < headers.length) {
            final header = headers[i];
            if (absGrades.contains(header)) {
              final cellValue = row[i];
              final val = cellValue is num 
                  ? cellValue.toDouble() 
                  : (num.tryParse(cellValue?.toString() ?? '0') ?? 0);
              if (val < 0) {
                shortages.add({'type': rowType, 'grade': header, 'value': val});
              }
              if (val < 50) {
                lowStock.add({'type': rowType, 'grade': header, 'value': val});
              }
            }
          }
        }
      } else if (row is Map) {
        // Handle Map structure
        final rowType = row['type']?.toString() ?? '';
        final values = row['values'];
        if (values is List) {
          for (int i = 0; i < values.length && i < headers.length; i++) {
            final header = headers[i];
            if (absGrades.contains(header)) {
              final cellValue = values[i];
              final val = cellValue is num 
                  ? cellValue.toDouble() 
                  : (num.tryParse(cellValue?.toString() ?? '0') ?? 0);
              if (val < 0) {
                shortages.add({'type': rowType, 'grade': header, 'value': val});
              }
              if (val < 50) {
                lowStock.add({'type': rowType, 'grade': header, 'value': val});
              }
            }
          }
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ALERTS, HEALTH & ADMIN', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF6B7280))),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
             final isWide = constraints.maxWidth > 900;
             final col1Width = isWide ? (constraints.maxWidth - 32) * 0.4 : constraints.maxWidth;
             final col2Width = isWide ? (constraints.maxWidth - 32) * 0.35 : constraints.maxWidth;
             final col3Width = isWide ? (constraints.maxWidth - 32) * 0.25 : constraints.maxWidth;

             return Wrap(
               spacing: 16,
               runSpacing: 16,
               children: [
                 // Alerts Card
                 Container(
                   width: col1Width,
                   decoration: AppTheme.glassDecoration,
                   padding: const EdgeInsets.all(24),
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                       const Row(
                         children: [
                           Text('🔔 Alerts & Notifications', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                         ],
                       ),
                       const Text('Key issues derived from low / negative stock.', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                       const SizedBox(height: 16),
                       if (shortages.isEmpty && lowStock.isEmpty)
                         const Text('No active alerts. System healthy.', style: TextStyle(fontSize: 12, color: Colors.green))
                       else ...[
                         if (shortages.isNotEmpty)
                           Padding(
                             padding: const EdgeInsets.only(bottom: 8.0),
                             child: Text('🔴 Critical: ${shortages.length} negative stock items.', style: const TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.bold)),
                           ),
                         if (lowStock.isNotEmpty)
                            Text('⚠️ Warning: ${lowStock.length} items below safety threshold (50kg).', style: TextStyle(fontSize: 12, color: Colors.orange[800])),
                       ]
                     ],
                   ),
                 ),
                 
                 // Critical Shortages Strip
                 Container(
                   width: col2Width,
                   decoration: AppTheme.glassDecoration,
                   padding: const EdgeInsets.all(24),
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                       const Text('⚠️ Critical Shortages', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                       const Text('Most negative or near-zero grades.', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                       const SizedBox(height: 16),
                       if (shortages.isEmpty)
                         const Text('No critical shortages.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)))
                       else
                         _buildScrollableRow(
                           shortages.map((s) => Container(
                               margin: const EdgeInsets.only(right: 12),
                               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                               decoration: BoxDecoration(
                                 color: Colors.red.withOpacity(0.1),
                                 border: Border.all(color: Colors.red.withOpacity(0.3)),
                                 borderRadius: BorderRadius.circular(8),
                               ),
                               child: Column(
                                 crossAxisAlignment: CrossAxisAlignment.start,
                                 children: [
                                   Text('${s['type']} ${s['grade']}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red)),
                                   Text('${(s['value'] as num).round()} kg', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.red)),
                                 ],
                               ),
                             )).toList(),
                         ),
                     ],
                   ),
                 ),

                 // Admin Actions (Full Width)
                 Container(
                    width: col3Width,
                    decoration: AppTheme.glassDecoration,
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('⚙️ Delta Mode & Maintenance', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                         const SizedBox(height: 8),
                        Text('Delta Status: ${_dashboardData?['deltaStatus'] ?? 'Loading...'}', style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                        const Divider(height: 24),
                        const Text('🧹 Admin Actions', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _buildAdminButton('⚙️ Recalculate (Delta)', () => _apiService.recalcStock()),
                            _buildAdminButton('🧼 Rebuild All', () => _apiService.rebuildAdmin()),
                            _buildAdminButton('🔁 Reset Pointer', () => _apiService.resetPointerAdmin()),
                          ],
                        ),
                      ],
                    ),
                 ),
               ],
             );
          },
        ),
      ],
    );
  }

  Widget _buildStockTableOrButton(List<String> headers, List<dynamic> rows) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        
        if (isMobile) {
          // Mobile: Show a tappable card that opens a popup
          return InkWell(
            onTap: () => _showStockTablePopup(headers, rows),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              decoration: AppTheme.glassDecoration,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5D6E7E).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.table_chart_outlined, color: Color(0xFF5D6E7E), size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('📊 Stock by Type & Grade', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                        Text('Tap to view stock table', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
                ],
              ),
            ),
          );
        } else {
          // Desktop: Show full table inline
          return Container(
            decoration: AppTheme.glassDecoration,
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('📊 Stock by Type & Grade', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                    Text('Values in kgs from net_stock sheet.', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                  ],
                ),
                const SizedBox(height: 8),
                if (rows.isEmpty)
                  const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('Loading stock table...', style: TextStyle(color: Color(0xFF6B7280)))))
                else
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.02),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: headers.where((h) => !virtualGrades.contains(h)).map((h) => Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                              child: Text(
                                h,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF4A5568)),
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )).toList(),
                        ),
                      ),
                      const SizedBox(height: 2),
                      ...rows.where((row) {
                        if (row is List && row.isNotEmpty) {
                          return (row[0]?.toString() ?? '').trim().isNotEmpty;
                        }
                        if (row is Map) {
                          final values = row['values'];
                          if (values is List && values.isNotEmpty) {
                            return (values[0]?.toString() ?? '').trim().isNotEmpty;
                          }
                        }
                        return false;
                      }).map((row) {
                        List<dynamic> values = [];
                        if (row is List) {
                          values = row;
                        } else if (row is Map && row['values'] is List) {
                          values = (row['values'] as List<dynamic>?) ?? [];
                        }
                        while (values.length < headers.length) {
                          values.add('');
                        }
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.1))),
                          ),
                          child: Row(
                            children: values.take(headers.length).toList().asMap().entries.where((entry) {
                              // Skip virtual grade columns entirely
                              final idx = entry.key;
                              if (idx == 0) return true; // Keep type label
                              final header = idx < headers.length ? headers[idx] : '';
                              return !virtualGrades.contains(header);
                            }).map((entry) {
                              final idx = entry.key;
                              final v = entry.value;
                              final numVal = num.tryParse(v.toString());
                              final isFirstCol = idx == 0;

                              // First column is the type label
                              if (isFirstCol) {
                                return Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                                    child: Text(
                                      v.toString(),
                                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                );
                              }

                              final displayVal = numVal;
                              
                              // Value cells with badge style (matching Stock Calculator)
                              if (displayVal == null || displayVal == 0) {
                                return const Expanded(child: SizedBox.shrink());
                              }
                              
                              // Color scheme: red < 0, orange 0-50, green > 50
                              Color bgColor;
                              Color borderColor;
                              Color textColor;
                              if (displayVal < 0) {
                                bgColor = Colors.red.withOpacity(0.04);
                                borderColor = Colors.red.withOpacity(0.08);
                                textColor = Colors.red;
                              } else if (displayVal < 50) {
                                bgColor = Colors.orange.withOpacity(0.1);
                                borderColor = Colors.orange.withOpacity(0.3);
                                textColor = Colors.orange[800]!;
                              } else {
                                bgColor = Colors.green.withOpacity(0.04);
                                borderColor = Colors.green.withOpacity(0.08);
                                textColor = Colors.green[700]!;
                              }
                              
                              return Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: bgColor,
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(color: borderColor),
                                    ),
                                    child: Text(
                                      '${displayVal > 0 ? "+" : ""}${displayVal.round()}',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: textColor,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        );
                      }).toList(),
                    ],
                  ),
              ],
            ),
          );
        }
      },
    );
  }

  void _showStockTablePopup(List<String> headers, List<dynamic> rows) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 600, maxWidth: 450),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('📊 Net Stock Status', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                  IconButton(
                    icon: const Icon(Icons.close, size: 22, color: Color(0xFF64748B)),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 12),
              Expanded(
                  child: StockAccordion(
                    netStock: {
                      'headers': headers,
                      'rows': rows,
                    },
                    virtualGrades: virtualGrades,
                    stockTypes: const ['Colour Bold', 'Fruit Bold', 'Rejection'],
                    initiallyExpanded: true,
                  ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdminButton(String label, Future Function() action) {
    return ElevatedButton(
      onPressed: () {
        fireAndForget(
          type: 'admin_action',
          apiCall: action,
          successMessage: 'Success: $label',
          failureMessage: 'Failed: $label',
        );
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF4A5568),
        side: BorderSide(color: const Color(0xFFCBD5E1).withOpacity(0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildInsightsSection() {
    final leaderboard = List<dynamic>.from(_dashboardData?['clientLeaderboard'] ?? []);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('INSIGHTS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF6B7280))),
        const SizedBox(height: 16),
        Container(
          decoration: AppTheme.glassDecoration,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('🏅 Client Leaderboard', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              if (leaderboard.isEmpty)
                const Text('No data loaded.')
              else
                Table(
                  columnWidths: const {
                    0: FlexColumnWidth(3),
                    1: FlexColumnWidth(2),
                    2: FlexColumnWidth(2),
                  },
                  children: [
                    const TableRow(
                      children: [
                        Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Client', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                        Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Pending', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                        Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Dispatched', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                      ],
                    ),
                    ...leaderboard.take(5).map((c) => TableRow(
                      children: [
                        Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(c['client'] ?? '?', style: const TextStyle(fontSize: 12))),
                        Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('₹${c['pendingValue'] ?? 0}', style: const TextStyle(fontSize: 12))),
                        Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('₹${c['dispatchedValue'] ?? 0}', style: const TextStyle(fontSize: 12))),
                      ],
                    )),
                  ],
                ),
              const SizedBox(height: 24),
              const Text('📈 Daily Dispatch Trend (30 Days)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _buildTrendChart(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTrendChart() {
    final trendList = List<dynamic>.from(_dashboardData?['dispatchHistory'] ?? []);
    if (trendList.isEmpty) return const Text('No trend data.');

    final maxKg = trendList.fold<double>(1.0, (max, item) {
      final kg = (num.tryParse(item['kg'].toString()) ?? 0).toDouble();
      return kg > max ? kg : max;
    });

    return SizedBox(
      height: 120,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: trendList.take(30).map((item) {
          final kg = (num.tryParse(item['kg'].toString()) ?? 0).toDouble();
          final heightFactor = kg / maxKg;
          final date = item['date'] ?? '??';
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Tooltip(
                message: '$date: $kg kg',
                child: Container(
                  height: 120 * heightFactor + 2, // ensure at least a sliver shows
                  decoration: BoxDecoration(
                    color: const Color(0xFF5D6E7E).withOpacity(0.7),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSmallStockCard(String title, String subtitle, Color color, double width) {
    return Container(
      width: width,
      decoration: AppTheme.glassDecoration,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF4A5568))),
              const Icon(Icons.info_outline, size: 16, color: Color(0xFF6B7280)),
            ],
          ),
          Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
          const SizedBox(height: 16),
          const Text('No data found.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ],
      ),
    );
  }

  Widget _buildSalesSnapshot() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SALES & ORDERS SNAPSHOT',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF6B7280), letterSpacing: 0.16),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = constraints.maxWidth > 800 ? (constraints.maxWidth - 16) / 2 : constraints.maxWidth;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _buildSalesCard('📅 Today’s Sales', 'Dispatch overview', [
                  _buildInfoRow('Total kgs dispatched', '${_dashboardData?['todaySalesKgs'] ?? '—'}'),
                  _buildInfoRow('Today Packed Count', '${_dashboardData?['todayPackedCount'] ?? '—'}'),
                  _buildInfoRow('Total Net Stock', '${_dashboardData?['totalStock'] ?? '—'} kg'),
                ], cardWidth),
                _buildSalesCard('🧾 Sales Summary', 'Pending vs dispatched', [
                  _buildInfoRow('Pending Dispatch Qty', '${_dashboardData?['pendingQty'] ?? '—'} kg'),
                  _buildInfoRow('Dispatched Today', '${_dashboardData?['summaryDispatchedToday'] ?? '—'} kg'),
                  _buildInfoRow('Pending Order Value', '₹ ${_dashboardData?['pendingValue'] ?? '—'}'),
                ], cardWidth),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth > 900;
            return Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: wide ? 8 : 1,
                      child: _buildActiveOrdersCard(),
                    ),
                    if (wide) const SizedBox(width: 16),
                    if (wide)
                      Expanded(
                        flex: 4,
                        child: _buildPackingSelectionCard(),
                      ),
                  ],
                ),
                if (!wide) ...[
                  const SizedBox(height: 16),
                  _buildPackingSelectionCard(),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        _buildTodayPackedCard(),
      ],
    );
  }

  Widget _buildActiveOrdersCard() {
    final filteredOrders = _pendingOrders.where((o) {
      if (_billingFilter == 'all') return true;
      final billingFrom = (o['billingFrom'] ?? '').toString().toLowerCase();
      return billingFrom == _billingFilter;
    }).toList();

    // Metrics calculation
    int count = 0;
    double totalKg = 0;
    double sygtKg = 0;
    double esplKg = 0;

    for (var o in filteredOrders) {
      final kgs = (num.tryParse(o['kgs'].toString()) ?? 0).toDouble();
      final billingFrom = (o['billingFrom'] ?? '').toString().toUpperCase();
      
      count++;
      totalKg += kgs;
      if (billingFrom == 'SYGT') sygtKg += kgs;
      if (billingFrom == 'ESPL') esplKg += kgs;
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4A5568).withOpacity(0.12),
            blurRadius: 40,
            offset: const Offset(0, 12),
            spreadRadius: -4,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
            borderRadius: BorderRadius.circular(24),
          ),
          child: LiquidGlass.withOwnLayer(
            settings: const LiquidGlassSettings(
              blur: 30,
              glassColor: Colors.white10,
              thickness: 10,
            ),
            shape: LiquidRoundedSuperellipse(borderRadius: 24),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text('📌 Active Pending Orders', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                            Text('Pulled live from order book.', style: TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      ...['all', 'sygt', 'espl'].map((f) => GestureDetector(
                        onTap: () => setState(() => _billingFilter = f),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          margin: const EdgeInsets.only(left: 4),
                          decoration: BoxDecoration(
                            color: _billingFilter == f ? const Color(0xFF5D6E7E) : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: _billingFilter == f ? const Color(0xFF5D6E7E) : const Color(0xFFE2E8F0)),
                          ),
                          child: Text(
                            f.toUpperCase(), 
                            style: TextStyle(
                              fontSize: 9, 
                              fontWeight: FontWeight.w600, 
                              color: _billingFilter == f ? Colors.white : const Color(0xFF64748B),
                            ),
                          ),
                        ),
                      )),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Metrics Row
                   Row(
                    children: [
                      Expanded(child: _buildMiniMetric('Pending orders', '$count')),
                      const SizedBox(width: 8),
                      Expanded(child: _buildMiniMetric('Pending kgs', '${totalKg.round()}')),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('SYGT vs ESPL', style: TextStyle(fontSize: 9, color: Color(0xFF6B7280))),
                            Text('SYGT: ${sygtKg.round()}', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blue)),
                            Text('ESPL: ${esplKg.round()}', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.purple)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (filteredOrders.isEmpty)
                    const Text('No pending orders.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)))
                  else
                    SizedBox(
                      height: 220,
                      child: ListView.builder(
                        itemCount: filteredOrders.length,
                        itemBuilder: (context, index) {
                          final o = filteredOrders[index];
                          return Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(o['client'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                    Text('${o['grade']} • ${o['billingFrom']}', style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
                                  ],
                                ),
                                Text('${o['kgs']} kg', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E))),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniMetric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
      ],
    );
  }

  Widget _buildTodayPackedCard() {
    double totalKg = 0;
    double totalVal = 0;
    for (var o in _todayCart) {
      final kgs = (num.tryParse(o['kgs'].toString()) ?? 0).toDouble();
      final price = (num.tryParse(o['price'].toString()) ?? 0).toDouble();
      totalKg += kgs;
      totalVal += (kgs * price);
    }
    
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4A5568).withOpacity(0.12),
            blurRadius: 40,
            offset: const Offset(0, 12),
            spreadRadius: -4,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
            borderRadius: BorderRadius.circular(24),
          ),
          child: LiquidGlass.withOwnLayer(
            settings: const LiquidGlassSettings(
              blur: 30,
              glassColor: Colors.white10,
              thickness: 10,
            ),
            shape: LiquidRoundedSuperellipse(borderRadius: 24),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('🚚 Today\'s Packed Orders', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                          Text('From cart_orders ("Packed Date" = today).', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      _buildMiniMetric('Lots packed', '${_todayCart.length}'),
                      const SizedBox(width: 24),
                      _buildMiniMetric('Total kgs', '${totalKg.round()}'),
                      const SizedBox(width: 24),
                      _buildMiniMetric('Approx value', '₹ ${totalVal.toStringAsFixed(0)}'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_todayCart.isEmpty)
                    const Text('No packed orders today.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)))
                  else
                    SizedBox(
                      height: 200,
                      child: ListView.builder(
                        itemCount: _todayCart.length,
                        itemBuilder: (context, index) {
                          final o = _todayCart[index];
                          return Container(
                            padding: const EdgeInsets.all(8),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('${o['client']} • ${o['packedDate'] ?? 'Today'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                      Text('Lot ${o['lot']} • ${o['grade']} • ₹${o['price']} • ${o['brand']}', style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
                                    ],
                                  ),
                                ),
                                Text('${o['kgs']} kg', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ],
                            ),
                          );
                        },
                      ),
                    )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPackingSelectionCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4A5568).withOpacity(0.12),
            blurRadius: 40,
            offset: const Offset(0, 12),
            spreadRadius: -4,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
            borderRadius: BorderRadius.circular(24),
          ),
          child: LiquidGlass.withOwnLayer(
            settings: const LiquidGlassSettings(
              blur: 30,
              glassColor: Colors.white10,
              thickness: 10,
            ),
            shape: LiquidRoundedSuperellipse(borderRadius: 24),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('🧺 Select Orders for Packing', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                  const Text('High-priority (oldest first).', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 230,
                    child: _isLoading && _pendingOrders.isEmpty
                        ? const Center(child: CircularProgressIndicator())
                        : _pendingOrders.isEmpty
                            ? const Text('No orders to pack.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)))
                            : ListView.builder(
                                itemCount: _pendingOrders.length,
                            itemBuilder: (context, index) {
                              final o = _pendingOrders[index];
                              final isSelected = _selectedPackingIndices.contains(index);
                              return CheckboxListTile(
                                value: isSelected,
                                onChanged: (val) {
                                  setState(() {
                                    if (val == true) _selectedPackingIndices.add(index);
                                    else _selectedPackingIndices.remove(index);
                                  });
                                },
                                title: Text(o['client']?.toString() ?? '?', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                subtitle: Text('${o['grade']} • ${o['kgs']}kg', style: const TextStyle(fontSize: 10)),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _selectedPackingIndices.isEmpty ? null : () {
                      final selectedOrders = _selectedPackingIndices.map((idx) => _pendingOrders[idx]).toList();
                      final previousOrders = List<dynamic>.from(_pendingOrders);
                      final previousIndices = Set<int>.from(_selectedPackingIndices);

                      optimistic(
                        type: 'add_to_cart',
                        applyLocal: () => setState(() {
                          final selectedIds = selectedOrders.map((e) => e['index'] ?? e['id']).toSet();
                          _pendingOrders.removeWhere((o) => selectedIds.contains(o['index'] ?? o['id']));
                          _selectedPackingIndices.clear();
                        }),
                        apiCall: () => _apiService.addToCart(selectedOrders),
                        rollback: () => setState(() {
                          _pendingOrders
                            ..clear()
                            ..addAll(previousOrders);
                          _selectedPackingIndices.addAll(previousIndices);
                        }),
                        successMessage: 'Orders successfully added to cart!',
                        failureMessage: 'Failed to add orders to cart. Reverted.',
                        onSuccess: () => _loadData(),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 36),
                      backgroundColor: const Color(0xFF5D6E7E),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Add Selected to Cart', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSalesCard(String title, String subtitle, List<Widget> children, double width) {
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A5568).withOpacity(0.12),
              blurRadius: 40,
              offset: const Offset(0, 12),
              spreadRadius: -4,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: LiquidGlass.withOwnLayer(
              settings: const LiquidGlassSettings(
                blur: 30,
                glassColor: Colors.white10,
                thickness: 10,
              ),
              shape: LiquidRoundedSuperellipse(borderRadius: 24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF4A5568))),
                    Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                    const SizedBox(height: 16),
                    ...children,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF4A5568))),
        ],
      ),
    );
  }

  Widget _buildSmallActionButton(String label, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white.withOpacity(0.12),
        foregroundColor: const Color(0xFF4A5568),
        elevation: 0,
        side: BorderSide(color: const Color(0xFFCBD5E1).withOpacity(0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildScrollableRow(List<Widget> children) {
    final ScrollController controller = ScrollController();
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left, color: Color(0xFF6B7280)),
          onPressed: () {
            controller.animateTo(
              (controller.offset - 200).clamp(0, controller.position.maxScrollExtent),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: controller,
            child: Row(
              children: children,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right, color: Color(0xFF6B7280)),
          onPressed: () {
            controller.animateTo(
              (controller.offset + 200).clamp(0, controller.position.maxScrollExtent),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
        ),
      ],
    );
  }

  Widget _buildTopButton({required String label, required VoidCallback onPressed, LinearGradient? gradient, Color? color}) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: color,
        gradient: gradient,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: (color ?? (gradient?.colors.last ?? Colors.blue)).withOpacity(0.5),
            offset: const Offset(0, 4),
            blurRadius: 12,
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

// _HeroCard class moved to admin_dashboard/widgets/titanium_hero_card.dart as HeroCard

class _DailyCartDialog extends StatelessWidget {
  final List<dynamic> todayCart;
  final Function(String, String) onCancelDispatch;

  const _DailyCartDialog({required this.todayCart, required this.onCancelDispatch});

  @override
  Widget build(BuildContext context) {
    // Group by Client
    final grouped = <String, List<dynamic>>{};
    for (var order in todayCart) {
      final client = order['client'] ?? 'Unknown';
      if (!grouped.containsKey(client)) grouped[client] = [];
      grouped[client]!.add(order);
    }
    final sortedClients = grouped.keys.toList()..sort();

    final bool isMobile = MediaQuery.of(context).size.width < 800;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: isMobile ? MediaQuery.of(context).size.width * 0.95 : 800,
        height: isMobile ? MediaQuery.of(context).size.height * 0.85 : 600,
        padding: EdgeInsets.all(isMobile ? 12 : 24),
        child: Column(
          children: [
             Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 Expanded(child: Text('📅 Today\'s Packed Orders', style: TextStyle(fontSize: isMobile ? 16 : 20, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                 const CloseButton(),
               ],
             ),
             const Divider(),
             Expanded(
               child: todayCart.isEmpty 
                 ? const Center(child: Text('No packed orders today.', style: TextStyle(color: Colors.grey)))
                 : ListView.builder(
                   itemCount: sortedClients.length,
                   itemBuilder: (context, index) {
                     final client = sortedClients[index];
                     final orders = grouped[client]!;
                     return Container(
                       margin: const EdgeInsets.only(bottom: 16),
                       decoration: BoxDecoration(
                         borderRadius: BorderRadius.circular(12),
                         border: Border.all(color: Colors.grey.withOpacity(0.2)),
                       ),
                       child: Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           Container(
                             width: double.infinity,
                             padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                             decoration: BoxDecoration(
                               color: Colors.blue.withOpacity(0.05),
                               borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                               border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.2))),
                             ),
                             child: Text('👤 $client', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                           ),
                           ...orders.map((o) => Padding(
                             padding: const EdgeInsets.all(12),
                             child: Row(
                               crossAxisAlignment: CrossAxisAlignment.start,
                               children: [
                                 Expanded(
                                   child: Column(
                                     crossAxisAlignment: CrossAxisAlignment.start,
                                     children: [
                                       Text(
                                         'Lot ${o['lot']}: ${o['grade']} • ${o['kgs']} kg • ₹${o['price']}', 
                                         style: const TextStyle(fontWeight: FontWeight.w500)
                                       ),
                                       if (o['notes'] != null && o['notes'].toString().isNotEmpty)
                                          Text('📝 ${o['notes']}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                     ],
                                   ),
                                 ),
                                 IconButton(
                                   icon: const Icon(Icons.close, color: Colors.red, size: 20),
                                   onPressed: () => onCancelDispatch(o['lot'].toString(), client),
                                   tooltip: 'Cancel Dispatch',
                                 ),
                               ],
                             ),
                           )),
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
}

class _AvailableStockDialog extends StatelessWidget {
  final Map<String, double> stockMap;

  const _AvailableStockDialog({required this.stockMap});

  @override
  Widget build(BuildContext context) {
    final sortedGrades = stockMap.keys.toList()
      ..sort((a, b) => stockMap[b]!.compareTo(stockMap[a]!));

    return Dialog(
       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
       child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          padding: const EdgeInsets.all(16),
         child: Column(
           mainAxisSize: MainAxisSize.min,
           children: [
             const Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 Text('📦 Available for Allocation', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                 CloseButton(),
               ],
             ),
             const SizedBox(height: 8),
             const Text(
               'Absolute grades with positive stock, aggregated across buckets.',
               style: TextStyle(fontSize: 12, color: Colors.grey),
               textAlign: TextAlign.left,
             ),
             const SizedBox(height: 16),
             stockMap.isEmpty
               ? const Padding(padding: EdgeInsets.all(20), child: Text('No positive absolute grades available.', style: TextStyle(color: Colors.grey)))
               : Flexible(
                   child: SingleChildScrollView(
                     child: Table(
                       columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1)},
                       border: TableBorder(horizontalInside: BorderSide(color: Colors.grey.withOpacity(0.2))),
                       children: [
                         const TableRow(
                           decoration: BoxDecoration(color: Color(0xFFF1F5F9)),
                           children: [
                             Padding(padding: EdgeInsets.all(8.0), child: Text('Grade', style: TextStyle(fontWeight: FontWeight.bold))),
                             Padding(padding: EdgeInsets.all(8.0), child: Text('Available (kg)', style: TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
                           ],
                         ),
                         ...sortedGrades.map((grade) => TableRow(
                           children: [
                             Padding(padding: const EdgeInsets.all(12.0), child: Text(grade)),
                             Padding(padding: const EdgeInsets.all(12.0), child: Text('${stockMap[grade]?.round()}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                           ],
                         )),
                       ],
                     ),
                   ),
                 ),
           ],
         ),
       ),
    );
  }
}

class _PendingOrdersDialog extends StatefulWidget {
  final List<dynamic> pendingOrders;
  final VoidCallback? onRefresh;

  const _PendingOrdersDialog({required this.pendingOrders, this.onRefresh});

  @override
  State<_PendingOrdersDialog> createState() => _PendingOrdersDialogState();
}

class _PendingOrdersDialogState extends State<_PendingOrdersDialog> {
  final ApiService _apiService = ApiService();
  
  // Filter state variables
  String _billingFilter = '';
  String _gradeFilter = '';
  String _searchQuery = '';

  // Get unique billing options from orders
  List<String> get _billingOptions {
    final billings = widget.pendingOrders
        .map((o) => o['billing']?.toString() ?? '')
        .where((b) => b.isNotEmpty)
        .toSet()
        .toList();
    billings.sort();
    return billings;
  }

  // Get unique grade options from orders (sorted by GradeHelper)
  List<String> get _gradeOptions {
    final grades = widget.pendingOrders
        .map((o) => o['grade']?.toString() ?? '')
        .where((g) => g.isNotEmpty)
        .toSet()
        .toList();
    return GradeHelper.sorted(grades);
  }

  // Apply filters to orders
  List<dynamic> get _filteredOrders {
    return widget.pendingOrders.where((o) {
      final billing = o['billing']?.toString().toLowerCase() ?? '';
      final grade = o['grade']?.toString().toLowerCase() ?? '';
      final client = o['client']?.toString().toLowerCase() ?? '';
      final brand = o['brand']?.toString().toLowerCase() ?? '';

      final matchesBilling = _billingFilter.isEmpty || billing == _billingFilter.toLowerCase();
      final matchesGrade = _gradeFilter.isEmpty || grade == _gradeFilter.toLowerCase();
      final matchesSearch = _searchQuery.isEmpty || 
          client.contains(_searchQuery.toLowerCase()) ||
          grade.contains(_searchQuery.toLowerCase()) ||
          brand.contains(_searchQuery.toLowerCase());

      return matchesBilling && matchesGrade && matchesSearch;
    }).toList();
  }

  // Group orders by date, then by client
  Map<String, Map<String, List<dynamic>>> _groupOrders(List<dynamic> orders) {
    final grouped = <String, Map<String, List<dynamic>>>{};
    
    for (final o in orders) {
      final date = o['orderDate']?.toString() ?? 'Unknown';
      final client = o['client']?.toString() ?? 'Unknown';
      
      if (!grouped.containsKey(date)) {
        grouped[date] = {};
      }
      if (!grouped[date]!.containsKey(client)) {
        grouped[date]![client] = [];
      }
      grouped[date]![client]!.add(o);
    }
    
    return grouped;
  }

  Future<void> _deleteOrder(dynamic order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete Order?'),
        content: const Text('Are you sure? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final rowIndex = order['index'];
        if (rowIndex != null) {
          await _apiService.deleteOrder(rowIndex);
          if (widget.onRefresh != null) {
            widget.onRefresh!();
          }
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Order deleted successfully'), backgroundColor: Colors.green),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _editOrder(dynamic order) async {
    // Navigate to view_orders screen for editing
    Navigator.pop(context);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    AccessControlService.navigateWithAccessCheck(context, '/view_orders', auth.pageAccess, userRole: auth.role);
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = MediaQuery.of(context).size.width < 600;
    final filteredOrders = _filteredOrders;
    final grouped = _groupOrders(filteredOrders);
    // Sort dates oldest first
    final sortedDates = grouped.keys.toList()..sort((a, b) => a.compareTo(b));

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.95,
        height: MediaQuery.of(context).size.height * 0.85,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text('🧾 Pending Orders', style: TextStyle(fontSize: isMobile ? 16 : 18, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                const CloseButton(),
              ],
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Billing filter
                  SizedBox(
                    width: isMobile ? 130 : 130,
                    child: DropdownButtonFormField<String>(
                      value: _billingFilter.isEmpty ? null : _billingFilter,
                      isExpanded: true,
                      decoration: InputDecoration(
                        hintText: 'Billing',
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
                      ),
                      borderRadius: BorderRadius.circular(20),
                      items: _billingOptions.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 12)))).toList(),
                      onChanged: (val) => setState(() => _billingFilter = val ?? ''),
                    ),
                  ),
                  // Grades filter
                  SizedBox(
                    width: isMobile ? 180 : 170,
                    child: GradeGroupedDropdown(
                      value: _gradeFilter.isEmpty ? null : _gradeFilter,
                      grades: _gradeOptions,
                      decoration: InputDecoration(
                        hintText: 'All Grades',
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
                      ),
                      menuMaxHeight: 350,
                      itemStyle: const TextStyle(fontSize: 12),
                      onChanged: (val) => setState(() => _gradeFilter = val ?? ''),
                    ),
                  ),
                  // Search field
                  SizedBox(
                    width: isMobile ? double.infinity : 250,
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'Search Client/Grade...',
                        filled: true,
                        fillColor: Colors.white,
                        prefixIcon: const Icon(Icons.search, color: Color(0xFF666666), size: 18),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFCCCCCC))),
                      ),
                      onChanged: (val) => setState(() => _searchQuery = val),
                    ),
                  ),
                ],
              ),
            ),
            if (_billingFilter.isNotEmpty || _gradeFilter.isNotEmpty || _searchQuery.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    _billingFilter = '';
                    _gradeFilter = '';
                    _searchQuery = '';
                  }),
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text('Clear'),
                ),
              ),
            // Results count
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(
                    '${filteredOrders.length} orders',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                  ),
                  if (filteredOrders.length != widget.pendingOrders.length)
                    Text(
                      ' (filtered from ${widget.pendingOrders.length})',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                    ),
                ],
              ),
            ),
            Expanded(
              child: filteredOrders.isEmpty
                ? const Center(child: Text('No orders match the filters.', style: TextStyle(color: Colors.grey)))
                : ListView(
                    children: [
                      for (final date in sortedDates) ...[
                        // Date header
                        Padding(
                          padding: const EdgeInsets.only(top: 16, bottom: 8),
                          child: Text('📅 $date', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                        // Clients under this date (sorted alphabetically)
                        for (final client in (grouped[date]!.keys.toList()..sort())) ...[
                          // Client header
                          Padding(
                            padding: const EdgeInsets.only(left: 16, top: 12, bottom: 8),
                            child: Text('👤 $client', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                          // Orders for this client
                          for (final o in grouped[date]![client]!)
                            _buildOrderLine(o),
                        ],
                      ],
                    ],
                  ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: () {
                  final auth = Provider.of<AuthProvider>(context, listen: false);
                  AccessControlService.navigateWithAccessCheck(context, '/view_orders', auth.pageAccess, userRole: auth.role);
                },
                child: const Text('Open Grouped Orders (Pending)'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderLine(dynamic o) {
    final lot = o['lot'] ?? '';
    final grade = o['grade'] ?? '';
    final no = o['no'] ?? '';
    final bagBox = o['bagbox'] ?? '';
    final kgs = o['kgs'] ?? '';
    final price = o['price'] ?? '';
    final brand = o['brand'] ?? '';
    final notes = o['notes']?.toString() ?? '';

    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 18, vertical: isMobile ? 8 : 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(isMobile ? 12 : 20),
        border: Border.all(color: const Color(0xFFDDDDDD)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            offset: const Offset(0, 4),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RichText(
                      text: TextSpan(
                        style: TextStyle(fontSize: isMobile ? 13 : 15, color: const Color(0xFF4A5568), fontWeight: FontWeight.w500),
                        children: [
                          TextSpan(text: '$lot: $grade - $no $bagBox - $kgs kgs x ₹$price - $brand'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusBadge(status: 'PENDING'),
            ],
          ),
          if (notes.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const Icon(Icons.notes, size: 12, color: Color(0xFF64748B)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      notes,
                      style: TextStyle(fontSize: isMobile ? 11 : 13, color: const Color(0xFF64748B), fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _buildRowButton(isMobile ? '✏️' : '✏️ Edit', const Color(0xFF5D6E7E), () => _editOrder(o), isMobile: isMobile),
              const SizedBox(width: 8),
              _buildRowButton(isMobile ? '❌' : '❌ Delete', const Color(0xFFEF4444), () => _deleteOrder(o), isMobile: isMobile),
            ],
          ),
        ],
      ),
    );
  }

  Widget _StatusBadge({required String status}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.3)),
      ),
      child: Text(
        status,
        style: const TextStyle(
          color: Color(0xFFD97706),
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildRowButton(String label, Color color, VoidCallback onPressed, {bool isMobile = false}) {
    return SizedBox(
      height: isMobile ? 30 : 36,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withOpacity(0.1),
          foregroundColor: color,
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(isMobile ? 12 : 20), side: BorderSide(color: color.withOpacity(0.2))),
          elevation: 0,
        ),
        child: Text(label, style: TextStyle(fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

// Content widget for Available Stock drag popup
class _AvailableStockDialogContent extends StatelessWidget {
  final Map<String, double> stockMap;
  final ScrollController scrollController;
  const _AvailableStockDialogContent({required this.stockMap, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final sortedEntries = stockMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: sortedEntries.length,
      itemBuilder: (context, index) {
        final entry = sortedEntries[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(entry.key, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: const Color(0xFF10B981).withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                child: Text('${entry.value.round()} kg', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
              ),
            ],
          ),
        );
      },
    );
  }
}

// Content widget for Pending Orders drag popup (matches original _PendingOrdersDialog styling exactly)
class _PendingOrdersDragContent extends StatefulWidget {
  final List<dynamic> pendingOrders;
  final ScrollController scrollController;
  final VoidCallback? onRefresh;
  const _PendingOrdersDragContent({required this.pendingOrders, required this.scrollController, this.onRefresh});

  @override
  State<_PendingOrdersDragContent> createState() => _PendingOrdersDragContentState();
}

class _PendingOrdersDragContentState extends State<_PendingOrdersDragContent> {
  final ApiService _apiService = ApiService();
  String _searchQuery = '';
  String _billingFilter = '';
  String _gradeFilter = '';

  List<String> get _billingOptions {
    final billings = widget.pendingOrders.map((o) => o['billingFrom']?.toString() ?? '').where((b) => b.isNotEmpty).toSet().toList();
    billings.sort();
    return billings;
  }

  List<String> get _gradeOptions {
    final grades = widget.pendingOrders.map((o) => o['grade']?.toString() ?? '').where((g) => g.isNotEmpty).toSet().toList();
    return GradeHelper.sorted(grades);
  }

  List<dynamic> get _filteredOrders {
    return widget.pendingOrders.where((o) {
      final client = o['client']?.toString().toLowerCase() ?? '';
      final grade = o['grade']?.toString().toLowerCase() ?? '';
      final billing = o['billingFrom']?.toString().toLowerCase() ?? '';
      final matchesSearch = _searchQuery.isEmpty || client.contains(_searchQuery.toLowerCase()) || grade.contains(_searchQuery.toLowerCase());
      final matchesBilling = _billingFilter.isEmpty || billing == _billingFilter.toLowerCase();
      final matchesGrade = _gradeFilter.isEmpty || grade == _gradeFilter.toLowerCase();
      return matchesSearch && matchesBilling && matchesGrade;
    }).toList();
  }

  Map<String, Map<String, List<dynamic>>> _groupOrders(List<dynamic> orders) {
    final grouped = <String, Map<String, List<dynamic>>>{};
    for (final o in orders) {
      final date = o['orderDate']?.toString() ?? 'Unknown';
      final client = o['client']?.toString() ?? 'Unknown';
      if (!grouped.containsKey(date)) grouped[date] = {};
      if (!grouped[date]!.containsKey(client)) grouped[date]![client] = [];
      grouped[date]![client]!.add(o);
    }
    return grouped;
  }

  Future<void> _deleteOrder(dynamic order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete Order?'),
        content: const Text('Are you sure? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        final rowIndex = order['index'];
        if (rowIndex != null) {
          await _apiService.deleteOrder(rowIndex);
          if (widget.onRefresh != null) widget.onRefresh!();
          if (mounted) {
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Order deleted'), backgroundColor: Color(0xFF22C55E)));
          }
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _editOrder(dynamic order) {
    Navigator.pop(context);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    AccessControlService.navigateWithAccessCheck(context, '/view_orders', auth.pageAccess, userRole: auth.role);
  }

  @override
  Widget build(BuildContext context) {
    final orders = _filteredOrders;
    final grouped = _groupOrders(orders);
    final sortedDates = grouped.keys.toList()..sort((a, b) {
      // Parse dd/MM/yy chronologically (oldest first)
      try {
        final pA = a.split('/'), pB = b.split('/');
        final dA = DateTime(2000 + int.parse(pA[2]), int.parse(pA[1]), int.parse(pA[0]));
        final dB = DateTime(2000 + int.parse(pB[2]), int.parse(pB[1]), int.parse(pB[0]));
        return dA.compareTo(dB);
      } catch (_) { return a.compareTo(b); }
    });

    return Column(children: [
      // Filters row
      Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, runSpacing: 8, children: [
        SizedBox(width: 120, child: DropdownButtonFormField<String>(
          value: _billingFilter.isEmpty ? null : _billingFilter,
          isExpanded: true,
          decoration: InputDecoration(hintText: 'Billing', isDense: true, filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), border: OutlineInputBorder(borderRadius: BorderRadius.circular(20))),
          items: _billingOptions.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 12)))).toList(),
          onChanged: (val) => setState(() => _billingFilter = val ?? ''),
        )),
        SizedBox(width: 160, child: GradeGroupedDropdown(
          value: _gradeFilter.isEmpty ? null : _gradeFilter,
          grades: _gradeOptions,
          decoration: InputDecoration(hintText: 'All Grades', isDense: true, filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), border: OutlineInputBorder(borderRadius: BorderRadius.circular(20))),
          menuMaxHeight: 350,
          itemStyle: const TextStyle(fontSize: 12),
          onChanged: (val) => setState(() => _gradeFilter = val ?? ''),
        )),
        Expanded(child: TextField(
          decoration: InputDecoration(hintText: 'Search...', filled: true, fillColor: Colors.white, prefixIcon: const Icon(Icons.search, size: 18), isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), border: OutlineInputBorder(borderRadius: BorderRadius.circular(20))),
          onChanged: (v) => setState(() => _searchQuery = v),
        )),
      ])),
      if (_billingFilter.isNotEmpty || _gradeFilter.isNotEmpty || _searchQuery.isNotEmpty)
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: () => setState(() { _billingFilter = ''; _gradeFilter = ''; _searchQuery = ''; }),
          icon: const Icon(Icons.clear, size: 16), label: const Text('Clear'),
        )),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Text('${orders.length} orders', style: const TextStyle(fontSize: 12, color: Colors.grey))),
      
      // Grouped orders list
      Expanded(child: ListView.builder(
        controller: widget.scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: sortedDates.length,
        itemBuilder: (context, dateIndex) {
          final date = sortedDates[dateIndex];
          final clients = grouped[date]!;
          final sortedClients = clients.keys.toList()..sort();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('📅 $date', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF6B7280)))),
            ...sortedClients.map((client) {
              final clientOrders = clients[client]!;
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.withOpacity(0.2))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: Colors.blue.withOpacity(0.05), borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
                    child: Text('👤 $client', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                  ...clientOrders.map((o) => Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: const Color(0xFF5D6E7E).withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text('${o['billingFrom']}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E)))),
                        const SizedBox(width: 8),
                        Expanded(child: Text('${o['lot']}: ${o['grade']} - ${o['no']} ${o['bagbox']} - ${o['kgs']} kg x ₹${o['price']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
                      ]),
                      const SizedBox(height: 4),
                      Text('${o['brand']}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                      if (o['notes'] != null && o['notes'].toString().isNotEmpty)
                        Padding(padding: const EdgeInsets.only(top: 4), child: Row(children: [
                          const Icon(Icons.notes, size: 12, color: Color(0xFF64748B)),
                          const SizedBox(width: 4),
                          Expanded(child: Text('${o['notes']}', style: const TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic))),
                        ])),
                      const SizedBox(height: 8),
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        SizedBox(height: 28, child: ElevatedButton(onPressed: () => _editOrder(o), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))), child: const Text('✏️ Edit', style: TextStyle(fontSize: 11)))),
                        const SizedBox(width: 8),
                        SizedBox(height: 28, child: ElevatedButton(onPressed: () => _deleteOrder(o), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))), child: const Text('❌ Delete', style: TextStyle(fontSize: 11)))),
                      ]),
                    ]),
                  )),
                ]),
              );
            }),
          ]);
        },
      )),
    ]);
  }
}

// Content widget for Daily Cart (Today's Packed) drag popup - matches original _DailyCartDialog styling
class _DailyCartDragContent extends StatelessWidget {
  final List<dynamic> todayCart;
  final ScrollController scrollController;
  final Future<void> Function(String lot, String client) onCancelDispatch;
  const _DailyCartDragContent({required this.todayCart, required this.scrollController, required this.onCancelDispatch});

  @override
  Widget build(BuildContext context) {
    // Group by Client (matching original)
    final grouped = <String, List<dynamic>>{};
    for (var order in todayCart) {
      final client = order['client'] ?? 'Unknown';
      if (!grouped.containsKey(client)) grouped[client] = [];
      grouped[client]!.add(order);
    }
    final sortedClients = grouped.keys.toList()..sort();

    return todayCart.isEmpty 
      ? const Center(child: Text('No packed orders today.', style: TextStyle(color: Colors.grey)))
      : ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.all(12),
          itemCount: sortedClients.length,
          itemBuilder: (context, index) {
            final client = sortedClients[index];
            final orders = grouped[client]!;
            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.withOpacity(0.2))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: Colors.blue.withOpacity(0.05), borderRadius: const BorderRadius.vertical(top: Radius.circular(12)), border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.2)))),
                  child: Text('👤 $client', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                ),
                ...orders.map((o) => Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Lot ${o['lot']}: ${o['grade']} • ${o['kgs']} kg • ₹${o['price']}', style: const TextStyle(fontWeight: FontWeight.w500)),
                      if (o['notes'] != null && o['notes'].toString().isNotEmpty)
                        Text('📝 ${o['notes']}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ])),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.red, size: 20),
                      onPressed: () => onCancelDispatch(o['lot']?.toString() ?? '', client),
                      tooltip: 'Cancel Dispatch',
                    ),
                  ]),
                )),
              ]),
            );
          },
        );
  }
}

// Custom painters moved to admin_dashboard/widgets/mini_charts.dart
// Exported as MiniLineChartPainter, SoftTrendPainter, HeaderProgressPainter
