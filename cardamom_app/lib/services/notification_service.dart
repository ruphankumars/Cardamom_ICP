import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';

/// Model for approval requests (edit/delete suborders)
class ApprovalRequest {
  final String id;
  final String requesterId;
  final String requesterName;
  final String actionType; // 'edit' or 'delete'
  final String resourceType; // 'order', 'suborder'
  final int resourceId;
  final Map<String, dynamic>? resourceData;
  final Map<String, dynamic>? proposedChanges;
  final String? reason;
  final DateTime createdAt;
  String status; // 'pending', 'approved', 'rejected'
  String? adminId;
  String? adminName;
  String? rejectReason;
  DateTime? resolvedAt;
  final bool dismissed;

  ApprovalRequest({
    required this.id,
    required this.requesterId,
    required this.requesterName,
    required this.actionType,
    required this.resourceType,
    required this.resourceId,
    this.resourceData,
    this.proposedChanges,
    this.reason,
    required this.createdAt,
    this.status = 'pending',
    this.adminId,
    this.adminName,
    this.rejectReason,
    this.resolvedAt,
    this.dismissed = false,
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    return ApprovalRequest(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      requesterId: (json['requesterId'] ?? '').toString(),
      requesterName: (json['requesterName'] ?? 'Unknown').toString(),
      actionType: (json['actionType'] ?? 'edit').toString(),
      resourceType: (json['resourceType'] ?? 'order').toString(),
      resourceId: json['resourceId'] is int ? json['resourceId'] : int.tryParse(json['resourceId']?.toString() ?? '0') ?? 0,
      resourceData: json['resourceData'],
      proposedChanges: json['proposedChanges'],
      reason: json['reason']?.toString(),
      createdAt: json['createdAt'] != null
          ? (DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now())
          : DateTime.now(),
      status: (json['status'] ?? 'pending').toString(),
      adminId: json['adminId']?.toString(),
      adminName: json['adminName']?.toString(),
      rejectReason: json['rejectReason']?.toString(),
      resolvedAt: json['resolvedAt'] != null
          ? DateTime.tryParse(json['resolvedAt'].toString())
          : null,
      dismissed: json['dismissed'] == true || json['dismissed'] == 'true',
    );
  }
}

class AppNotification {
  final String id;
  final String title;
  final String body;
  final DateTime timestamp;
  final String type; // orders, stock, alert, sync, approval_result
  bool isRead;
  final String? relatedRequestId; // For approval result notifications

  AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.timestamp,
    required this.type,
    this.isRead = false,
    this.relatedRequestId,
  });
}

class NotificationService extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  final SocketService _socketService = SocketService();
  
  // Start with empty list - notifications come from real events
  final List<AppNotification> _notifications = [];

  // Approval requests (fetched from API)
  List<ApprovalRequest> _approvalRequests = [];
  List<ApprovalRequest> _myRequests = []; // User's own requests with status (all, including dismissed)
  List<ApprovalRequest> _myRequestsUnread = []; // Only non-dismissed (for badge/popup)
  final LinkedHashSet<String> _locallyDismissedIds = LinkedHashSet<String>(); // Track locally dismissed items to prevent reappearing during polling
  bool _isLoadingApprovals = false;
  bool _isFetchingMyRequests = false; // Guard against concurrent fetchMyRequests calls
  Timer? _pollingTimer;
  bool _useWebSocket = false; // ICP: always use HTTP polling (no WebSockets)
  String? _userId;
  String? _userRole;
  bool _isInitialized = false; // Guard: prevent multiple initializeRealtime() calls

  NotificationService() {
    // Clear any stale callbacks on the singleton before adding new ones
    _socketService.clearCallbacks();
    // Set up socket event handlers
    _socketService.onApprovalCreated(_handleApprovalCreated);
    _socketService.onApprovalResolved(_handleApprovalResolved);
    _socketService.onApprovalUpdated(_handleApprovalUpdated);
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    // Don't disconnect the singleton SocketService here — it would break
    // other consumers. Just clear our callbacks so they don't fire on a
    // disposed NotificationService.
    _socketService.clearCallbacks();
    super.dispose();
  }

  bool get isWebSocketConnected => _socketService.isConnected;

  /// Initialize real-time notifications (WebSocket primary, polling always as backup)
  /// Safe to call multiple times — only initializes once per userId.
  void initializeRealtime({required String userId, required String role}) {
    // Guard: skip if already initialized for this user
    if (_isInitialized && _userId == userId && _userRole == role) {
      debugPrint('[NotificationService] Already initialized for $userId ($role), skipping');
      return;
    }
    
    // If switching users, clean up old state
    if (_isInitialized && _userId != userId) {
      debugPrint('[NotificationService] User changed from $_userId to $userId, reinitializing');
      stopPolling();
      _socketService.disconnect();
      _locallyDismissedIds.clear(); // #77: Clear stale dismissed IDs on user switch
    }
    
    _userId = userId;
    _userRole = role;
    _isInitialized = true;
    
    // Fetch once on init (startPolling handles the timer, but does NOT duplicate the initial fetch)
    fetchApprovalRequests();
    fetchMyRequests();
    // Superadmin: also fetch persisted doc notifications from SQLite
    if (role == 'superadmin') fetchPersistedNotifications();
    
    // Start polling as a reliable backup
    startPolling();
    
    if (_useWebSocket) {
      // Also try WebSocket for faster updates
      _socketService.connect(userId: userId, role: role);
      debugPrint('[NotificationService] WebSocket + Polling active for $userId ($role)');
    }
  }

  void _handleApprovalCreated(Map<String, dynamic> data) {
    debugPrint('[NotificationService] New approval request received');
    // Refresh the approval requests list (superadmin only — guarded inside fetchApprovalRequests)
    fetchApprovalRequests();
  }

  void _handleApprovalResolved(Map<String, dynamic> data) {
    final status = data['status'] ?? 'unknown';
    final approved = status == 'approved';
    debugPrint('📬 [NotificationService] Approval resolved: $status');
    
    addApprovalResultNotification(
      requestId: data['requestId'] ?? '',
      actionType: data['actionType'] ?? 'action',
      approved: approved,
      adminName: data['adminName'],
      rejectReason: data['reason'],
    );
  }

  void _handleApprovalUpdated(Map<String, dynamic> data) {
    debugPrint('📬 [NotificationService] Approval list updated');
    // Refresh the list (superadmin only — guarded inside fetchApprovalRequests)
    fetchApprovalRequests();
  }

  /// Start periodic polling for approval requests (fallback or primary)
  /// NOTE: Does NOT do an initial fetch — caller (initializeRealtime) handles that.
  void startPolling() {
    if (_pollingTimer != null) return; // Already running
    
    // Set up timer only — initial fetch is done by initializeRealtime()
    final interval = _useWebSocket ? const Duration(seconds: 60) : const Duration(seconds: 15);
    _pollingTimer = Timer.periodic(interval, (timer) {
      fetchApprovalRequests();
      fetchMyRequests();
      if (_userRole == 'superadmin') fetchPersistedNotifications();
    });
    debugPrint('[NotificationService] Polling started (interval: ${interval.inSeconds}s)');
  }

  /// Stop polling
  void stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    debugPrint('🔕 [NotificationService] Polling stopped');
  }

  /// Disconnect all real-time connections
  void disconnectRealtime() {
    _socketService.disconnect();
    _socketService.clearCallbacks();
    stopPolling();
    // #77: Clear dismissed IDs on disconnect to prevent unbounded growth
    _locallyDismissedIds.clear();
    _userId = null;
    _userRole = null;
    _isInitialized = false;
  }

  List<AppNotification> get notifications => _notifications;
  int get unreadCount => _notifications.where((n) => !n.isRead).length;
  
  List<ApprovalRequest> get approvalRequests => _approvalRequests;
  List<ApprovalRequest> get pendingApprovals => 
      _approvalRequests.where((r) => r.status == 'pending').toList();
  int get pendingApprovalCount => pendingApprovals.length;
  bool get isLoadingApprovals => _isLoadingApprovals;
  
  // User's own requests
  List<ApprovalRequest> get myRequests => _myRequests; // All requests (for My Requests screen)
  List<ApprovalRequest> get myRequestsUnread => _myRequestsUnread; // Unread only (for popup/badge)
  List<ApprovalRequest> get myPendingRequests =>
      _myRequestsUnread.where((r) => r.status == 'pending').toList();
  int get myPendingCount => myPendingRequests.length;
  int get myUnreadCount => _myRequestsUnread.length; // Total unread (pending + resolved not dismissed)

  void markAsRead(String id) {
    final index = _notifications.indexWhere((n) => n.id == id);
    if (index != -1) {
      _notifications[index].isRead = true;
      notifyListeners();
    }
  }

  Future<void> markAllAsRead() async {
    // 1. Clear system notifications entirely (users expect them to vanish)
    _notifications.clear();
    // 2. Clear ALL items from MY REQUESTS unread list (pending + resolved)
    final dismissFutures = <Future>[];
    for (final req in _myRequestsUnread) {
      _locallyDismissedIds.add(req.id);
      // Persist dismissal to backend for resolved requests
      if (req.status != 'pending') {
        dismissFutures.add(
          _apiService.dismissRequest(req.id).catchError((e) {
            debugPrint('[NotificationService] Error dismissing request ${req.id}: $e');
          }),
        );
      }
    }
    _myRequestsUnread.clear();
    notifyListeners();
    // 3. Mark persisted notifications as read on server
    dismissFutures.add(
      _apiService.markAllNotificationsRead().catchError((e) {
        debugPrint('[NotificationService] Error marking notifications read: $e');
      }),
    );
    // Await all dismiss calls — retry once on failure
    try {
      await Future.wait(dismissFutures);
    } catch (e) {
      debugPrint('[NotificationService] Some dismiss calls failed, retrying: $e');
      // Retry failed dismissals once
      for (final req in _myRequests.where((r) => r.status != 'pending')) {
        _apiService.dismissRequest(req.id).catchError((_) {});
      }
    }
  }

  void addNotification(AppNotification notification) {
    _notifications.insert(0, notification);
    // Cap at 100 to prevent unbounded growth
    if (_notifications.length > 100) {
      _notifications.removeRange(100, _notifications.length);
    }
    notifyListeners();
  }

  void removeNotification(String id) {
    _notifications.removeWhere((n) => n.id == id);
    notifyListeners();
  }

  /// Add a notification for approval result (for users)
  void addApprovalResultNotification({
    required String requestId,
    required String actionType,
    required bool approved,
    String? adminName,
    String? rejectReason,
  }) {
    final title = approved 
        ? '✅ Request Approved' 
        : '❌ Request Rejected';
    final body = approved
        ? 'Your $actionType request was approved${adminName != null ? ' by $adminName' : ''}.'
        : 'Your $actionType request was rejected.${rejectReason != null ? ' Reason: $rejectReason' : ''}';
    
    addNotification(AppNotification(
      id: 'approval_result_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      body: body,
      timestamp: DateTime.now(),
      type: 'approval_result',
      relatedRequestId: requestId,
    ));
  }

  /// Fetch pending approval requests from API (superadmin only)
  Future<void> fetchApprovalRequests() async {
    // Only superadmin can approve/reject — no need to fetch for other roles
    if (_userRole != 'superadmin') return;
    // Guard against concurrent calls (prevents duplicate in-flight requests)
    if (_isLoadingApprovals) return;
    
    _isLoadingApprovals = true;
    notifyListeners();

    try {
      final response = await _apiService.getPendingApprovalRequests();
      
      if (response.data != null) {
        final List<dynamic> requests = response.data['requests'] ?? [];
        
        _approvalRequests = requests
            .map((r) => ApprovalRequest.fromJson(r as Map<String, dynamic>))
            .toList();
        
        debugPrint('[NotificationService] Loaded ${_approvalRequests.length} pending approval requests');
      }
    } catch (e) {
      debugPrint('[NotificationService] Error fetching approval requests: $e');
    }

    _isLoadingApprovals = false;
    notifyListeners();
  }

  /// Fetch persisted notifications from backend (superadmin only)
  Future<void> fetchPersistedNotifications() async {
    if (_userRole != 'superadmin') return;
    try {
      final response = await _apiService.getNotifications();
      if (response.data != null && response.data['success'] == true) {
        final List<dynamic> items = response.data['notifications'] ?? [];
        for (final item in items) {
          final id = item['id']?.toString() ?? '';
          // Don't add duplicates
          if (id.isNotEmpty && !_notifications.any((n) => n.id == id)) {
            addNotification(AppNotification(
              id: id,
              title: item['title']?.toString() ?? '',
              body: item['body']?.toString() ?? '',
              timestamp: DateTime.tryParse(item['createdAt']?.toString() ?? '') ?? DateTime.now(),
              type: item['type']?.toString() ?? 'general',
            ));
          }
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[NotificationService] Error fetching persisted notifications: $e');
    }
  }

  /// Fetch user's own requests (for employees to see their request status)
  Future<void> fetchMyRequests() async {
    if (_userId == null) return;
    
    // Guard against concurrent calls
    if (_isFetchingMyRequests) return;
    _isFetchingMyRequests = true;

    try {
      // Fetch in parallel: ALL requests (including dismissed) and UNREAD only (not dismissed)
      final results = await Future.wait([
        _apiService.getMyApprovalRequests(_userId!, includeDismissed: true),
        _apiService.getMyApprovalRequests(_userId!, includeDismissed: false),
      ]);

      final responseAll = results[0];
      final responseUnread = results[1];

      if (responseAll.data != null && responseUnread.data != null) {
        final List<dynamic> allRequests = responseAll.data['requests'] ?? [];
        final List<dynamic> unreadRequests = responseUnread.data['requests'] ?? [];

        // Check for status changes in unread requests to notify user
        for (final newReq in unreadRequests) {
          final newStatus = newReq['status']?.toString() ?? 'pending';
          final reqId = (newReq['id'] ?? newReq['_id'] ?? '').toString();

          // Find existing request in unread list
          final existingIdx = _myRequestsUnread.indexWhere((r) => r.id == reqId);
          if (existingIdx != -1) {
            final oldStatus = _myRequestsUnread[existingIdx].status;
            // If status changed from pending to approved/rejected, add notification
            if (oldStatus == 'pending' && newStatus != 'pending') {
              addApprovalResultNotification(
                requestId: reqId,
                actionType: newReq['actionType']?.toString() ?? 'action',
                approved: newStatus == 'approved',
                adminName: newReq['adminName']?.toString(),
                rejectReason: newReq['rejectReason']?.toString(),
              );
            }
          }
        }

        _myRequests = allRequests
            .map((r) => ApprovalRequest.fromJson(r as Map<String, dynamic>))
            .toList();

        _myRequestsUnread = unreadRequests
            .map((r) => ApprovalRequest.fromJson(r as Map<String, dynamic>))
            .where((r) => !_locallyDismissedIds.contains(r.id)) // Filter out locally dismissed items
            .toList();

        debugPrint('[NotificationService] My requests - All: ${_myRequests.length}, Unread: ${_myRequestsUnread.length}');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[NotificationService] Error fetching my requests: $e');
    } finally {
      _isFetchingMyRequests = false;
    }
  }

  /// Approve a request (admin action)
  Future<bool> approveRequest(String requestId, String adminId, String adminName) async {
    try {
      await _apiService.approveRequest(requestId, adminId, adminName);

      // Update local state
      final index = _approvalRequests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _approvalRequests[index].status = 'approved';
        _approvalRequests[index].adminId = adminId;
        _approvalRequests[index].adminName = adminName;
        _approvalRequests[index].resolvedAt = DateTime.now();
      }

      // Persist dismissal on backend so it doesn't reappear on app restart
      _apiService.dismissRequest(requestId).catchError((e) {
        debugPrint('[NotificationService] Error dismissing after approve: $e');
      });

      // Remove from local list immediately to prevent poll-overwrite race
      _approvalRequests.removeWhere((r) => r.id == requestId);

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error approving request: $e');
      return false;
    }
  }

  /// Reject a request (admin action)
  Future<bool> rejectRequest(String requestId, String adminId, String adminName, String reason, {String rejectionCategory = 'other'}) async {
    try {
      await _apiService.rejectRequest(requestId, adminId, adminName, reason, rejectionCategory: rejectionCategory);

      // Update local state
      final index = _approvalRequests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _approvalRequests[index].status = 'rejected';
        _approvalRequests[index].adminId = adminId;
        _approvalRequests[index].adminName = adminName;
        _approvalRequests[index].rejectReason = reason;
        _approvalRequests[index].resolvedAt = DateTime.now();
      }

      // Persist dismissal on backend so it doesn't reappear on app restart
      _apiService.dismissRequest(requestId).catchError((e) {
        debugPrint('[NotificationService] Error dismissing after reject: $e');
      });

      // Remove from local list immediately to prevent poll-overwrite race
      _approvalRequests.removeWhere((r) => r.id == requestId);

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error rejecting request: $e');
      return false;
    }
  }

  /// Dismiss a resolved request (hide from user's view after swiping)
  Future<bool> dismissRequest(String requestId) async {
    // Track locally FIRST to prevent reappearing during polling
    _locallyDismissedIds.add(requestId);

    // Remove from unread list immediately (affects badge and popup)
    _myRequestsUnread.removeWhere((r) => r.id == requestId);

    // Update UI immediately
    notifyListeners();
    debugPrint('🔄 [NotificationService] Dismissing request $requestId...');

    try {
      // Call backend to persist the dismissal
      await _apiService.dismissRequest(requestId);

      // Mark as dismissed in _myRequests (keep for history view)
      final allIndex = _myRequests.indexWhere((r) => r.id == requestId);
      if (allIndex != -1) {
        // Create new instance with dismissed=true (immutable update)
        final old = _myRequests[allIndex];
        _myRequests[allIndex] = ApprovalRequest(
          id: old.id,
          requesterId: old.requesterId,
          requesterName: old.requesterName,
          actionType: old.actionType,
          resourceType: old.resourceType,
          resourceId: old.resourceId,
          resourceData: old.resourceData,
          proposedChanges: old.proposedChanges,
          reason: old.reason,
          createdAt: old.createdAt,
          status: old.status,
          adminId: old.adminId,
          adminName: old.adminName,
          rejectReason: old.rejectReason,
          resolvedAt: old.resolvedAt,
          dismissed: true, // Mark as dismissed
        );
      }

      debugPrint('✅ [NotificationService] Successfully dismissed request $requestId');
      return true;
    } catch (e) {
      debugPrint('❌ [NotificationService] Error dismissing request: $e');

      // Failed - remove from tracking set so it reappears
      _locallyDismissedIds.remove(requestId);

      // Refetch to restore the item to the list
      await fetchMyRequests();

      return false;
    }
  }

  /// Remove a request from ALL lists (after approve/reject action)
  void removeApprovalRequest(String requestId) {
    _approvalRequests.removeWhere((r) => r.id == requestId);
    _myRequestsUnread.removeWhere((r) => r.id == requestId);
    _myRequests.removeWhere((r) => r.id == requestId);
    _locallyDismissedIds.add(requestId); // Prevent reappearing on next poll
    while (_locallyDismissedIds.length > 200) {
      _locallyDismissedIds.remove(_locallyDismissedIds.first);
    }
    notifyListeners();
  }
}
