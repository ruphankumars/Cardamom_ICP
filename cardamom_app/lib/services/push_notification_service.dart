import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'navigation_service.dart' show navigatorKey;
import 'notification_service.dart';

/// Service to manage push notifications via HTTP polling (ICP backend).
///
/// Replaces Firebase Cloud Messaging with periodic polling of
/// GET /api/notifications/poll?since=<timestamp>.
///
/// Handles:
/// - Polling for new notifications from ICP canister
/// - Foreground notification popups
/// - Notification tap navigation
class PushNotificationService {
  PushNotificationService._();
  static final PushNotificationService instance = PushNotificationService._();

  bool _initialized = false;
  Timer? _pollTimer;
  String? _lastPollTimestamp;

  /// Initialize notification polling.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Load last poll timestamp from prefs
    final prefs = await SharedPreferences.getInstance();
    _lastPollTimestamp = prefs.getString('lastNotifPollTimestamp');

    // Clear iOS badge on app open
    _clearBadge();

    debugPrint('[PushNotif] Polling-based notification service initialized');
  }

  /// Start polling for notifications (called after login).
  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _poll());
    // Do an immediate poll
    _poll();
    debugPrint('[PushNotif] Polling started (30s interval)');
  }

  /// Stop polling (called on logout).
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    debugPrint('[PushNotif] Polling stopped');
  }

  /// Register token — no-op on ICP (FCM tokens are not used).
  Future<void> registerToken() async {
    // No FCM tokens on ICP — notifications are polled via HTTP
  }

  /// Unregister token — no-op on ICP.
  Future<void> unregisterToken() async {
    // No FCM tokens on ICP
  }

  Future<void> _poll() async {
    try {
      final api = ApiService();
      final since = _lastPollTimestamp ?? DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String();
      final response = await api.dio.get('/notifications/poll', queryParameters: {'since': since});
      final data = response.data;

      if (data is Map && data['success'] == true) {
        final notifications = (data['notifications'] as List?) ?? [];
        if (notifications.isNotEmpty) {
          _lastPollTimestamp = DateTime.now().toIso8601String();
          // Persist last poll timestamp
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('lastNotifPollTimestamp', _lastPollTimestamp!);

          // Add to NotificationService and show popups
          for (final notif in notifications) {
            _handlePolledNotification(notif as Map<String, dynamic>);
          }
        }
      }
    } catch (e) {
      // Silently fail — polling will retry on next tick
      debugPrint('[PushNotif] Poll error: $e');
    }
  }

  void _handlePolledNotification(Map<String, dynamic> notif) {
    final title = notif['title']?.toString() ?? 'Notification';
    final body = notif['body']?.toString() ?? '';
    final type = notif['type']?.toString() ?? 'general';
    final metadata = notif['metadata'] as Map<String, dynamic>? ?? {};

    // Add to NotificationService for bell badge + notification center
    final context = navigatorKey.currentContext;
    if (context != null) {
      try {
        final notifService = Provider.of<NotificationService>(context, listen: false);
        notifService.addNotification(AppNotification(
          id: notif['id']?.toString() ?? 'poll_${DateTime.now().millisecondsSinceEpoch}',
          title: title,
          body: body,
          timestamp: DateTime.now(),
          type: type,
        ));
      } catch (e) {
        debugPrint('[PushNotif] Could not add to NotificationService: $e');
      }
    }

    // Show popup for important notification types
    if (type == 'new_order' || type == 'new_orders_batch') {
      _showOrderNotificationPopup(
        title: title,
        createdBy: metadata['createdBy']?.toString() ?? '',
        client: metadata['client']?.toString() ?? '',
        orderDetails: body,
        data: {...metadata, 'type': type},
      );
    } else if (type == 'approval_request' || type == 'approval_resolved' ||
               type == 'approval_escalation' || type == 'stock_drift') {
      _showGeneralNotificationPopup(title: title, body: body, data: {...metadata, 'type': type});
    }
    // Other types silently appear in notification center
  }

  void _navigateFromData(Map<String, dynamic> data) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;

    final dataType = data['type']?.toString() ?? '';
    if (dataType == 'new_order' || dataType == 'new_orders_batch') {
      final client = data['client']?.toString() ?? '';
      final billingFrom = data['billingFrom']?.toString() ?? '';
      nav.pushNamedAndRemoveUntil('/', (route) => false);
      nav.pushNamed('/view_orders', arguments: {
        if (client.isNotEmpty) 'search': client,
        if (billingFrom.isNotEmpty) 'billing': billingFrom,
      });
    } else {
      nav.pushNamedAndRemoveUntil('/', (route) => false);
    }
  }

  /// Clear iOS badge count when the app is opened.
  void _clearBadge() {
    if (Platform.isIOS) {
      const channel = MethodChannel('com.sygt.cardamom/badge');
      channel.invokeMethod('clearBadge').catchError((_) {
        debugPrint('[PushNotif] Badge channel not available');
      });
    }
  }

  /// Show a general-purpose notification popup (approvals, etc.)
  void _showGeneralNotificationPopup({
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    final dataType = data['type']?.toString() ?? '';
    final isApproval = dataType.startsWith('approval');
    final isApproved = data['status']?.toString() == 'approved';

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox(),
      transitionBuilder: (ctx, anim1, anim2, child) {
        final curved = CurvedAnimation(parent: anim1, curve: Curves.easeOutBack);
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.3),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: anim1,
            child: Align(
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 400),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.12),
                          blurRadius: 30,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Header
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                            color: isApproval
                                ? (dataType == 'approval_resolved'
                                    ? (isApproved ? const Color(0xFF078838) : const Color(0xFFE73908))
                                    : const Color(0xFF2C3A5A))
                                : const Color(0xFF2C3A5A),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    isApproval
                                        ? (dataType == 'approval_resolved'
                                            ? (isApproved ? Icons.check_circle_rounded : Icons.cancel_rounded)
                                            : Icons.approval_rounded)
                                        : Icons.notifications_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    title,
                                    style: GoogleFonts.inter(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Body
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                            child: Text(
                              body,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: const Color(0xFF131416),
                                height: 1.5,
                              ),
                            ),
                          ),
                          // Button
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  _navigateFromData(data);
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2C3A5A),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(
                                  'OK',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
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
          ),
        );
      },
    );
  }

  /// Show a modern popup dialog with order details.
  void _showOrderNotificationPopup({
    required String title,
    required String createdBy,
    required String client,
    required String orderDetails,
    required Map<String, dynamic> data,
  }) {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    final lines = orderDetails.split('\n').where((l) => l.trim().isNotEmpty).toList();

    String clientDisplay = client;
    final List<String> orderLines = [];
    for (final line in lines) {
      if (line.startsWith('Client:')) {
        clientDisplay = line.replaceFirst('Client:', '').trim();
      } else {
        orderLines.add(line);
      }
    }

    final billingFrom = data['billingFrom']?.toString() ?? '';
    final orderCount = int.tryParse(data['orderCount']?.toString() ?? '1') ?? 1;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox(),
      transitionBuilder: (ctx, anim1, anim2, child) {
        final curved = CurvedAnimation(parent: anim1, curve: Curves.easeOutBack);
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.3),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: anim1,
            child: _OrderPopupContent(
              createdBy: createdBy,
              clientDisplay: clientDisplay,
              billingFrom: billingFrom,
              orderLines: orderLines,
              orderCount: orderCount,
              onDismiss: () => Navigator.of(ctx).pop(),
              onViewOrders: () {
                Navigator.of(ctx).pop();
                _navigateFromData(data);
              },
            ),
          ),
        );
      },
    );
  }
}

/// Modern Zomato-inspired order notification popup widget.
class _OrderPopupContent extends StatelessWidget {
  final String createdBy;
  final String clientDisplay;
  final String billingFrom;
  final List<String> orderLines;
  final int orderCount;
  final VoidCallback onDismiss;
  final VoidCallback onViewOrders;

  const _OrderPopupContent({
    required this.createdBy,
    required this.clientDisplay,
    required this.billingFrom,
    required this.orderLines,
    required this.orderCount,
    required this.onDismiss,
    required this.onViewOrders,
  });

  @override
  Widget build(BuildContext context) {
    const titaniumLight = Color(0xFFE3E3DE);
    const titaniumBorder = Color(0xFFC4C4BC);
    const steelBlue = Color(0xFF2C3A5A);
    const primary = Color(0xFF5D6E7E);
    const success = Color(0xFF078838);
    const titleColor = Color(0xFF131416);

    return Align(
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 30,
                  spreadRadius: 0,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header bar
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                    decoration: const BoxDecoration(
                      color: steelBlue,
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.shopping_bag_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'New Order${orderCount > 1 ? 's' : ''} Added',
                                style: GoogleFonts.inter(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'by $createdBy',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (orderCount > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: success,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '$orderCount',
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Client card
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: titaniumLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: titaniumBorder),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: steelBlue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.business_rounded,
                            color: steelBlue,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (billingFrom.isNotEmpty)
                                Text(
                                  billingFrom,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: primary,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              Text(
                                clientDisplay,
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: titleColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Order lines
                  if (orderLines.isNotEmpty)
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: orderLines.length,
                        itemBuilder: (ctx, i) {
                          final parts = orderLines[i].split(' - ');
                          final grade = parts.isNotEmpty ? parts[0].trim() : '';
                          final qtyRate = parts.length > 1 ? parts[1].trim() : '';
                          final brand = parts.length > 2 ? parts[2].trim() : '';
                          final notes = parts.length > 3 ? parts.sublist(3).join(' - ').trim() : '';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF7F7F5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: titaniumBorder.withOpacity(0.5)),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: success.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '${i + 1}',
                                    style: GoogleFonts.inter(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: success,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        grade,
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: titleColor,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      if (qtyRate.isNotEmpty)
                                        Text(
                                          qtyRate,
                                          style: GoogleFonts.inter(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: const Color(0xFFD97706),
                                          ),
                                        ),
                                      if (brand.isNotEmpty || notes.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Text(
                                            [brand, notes].where((s) => s.isNotEmpty).join(' · '),
                                            style: GoogleFonts.inter(
                                              fontSize: 12,
                                              color: primary,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),

                  // Action buttons
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: onDismiss,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: titaniumBorder),
                              ),
                            ),
                            child: Text(
                              'Dismiss',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: onViewOrders,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: success,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.visibility_rounded, size: 18),
                            label: Text(
                              'View Orders',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
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
      ),
    );
  }
}
