import 'dart:io' show Platform;
import 'dart:ui';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'navigation_service.dart' show navigatorKey;
import 'notification_service.dart';

/// Top-level handler for background messages (must be top-level function).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM] Background message: ${message.notification?.title}');
  // No need to show notification — Firebase handles it automatically
  // when the app is in background/terminated.
}

/// Service to manage Firebase Cloud Messaging for push notifications.
///
/// Handles:
/// - Requesting notification permissions (iOS)
/// - Registering FCM token with backend
/// - Foreground message handling
/// - Notification tap navigation
class PushNotificationService {
  PushNotificationService._();
  static final PushNotificationService instance = PushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _initialized = false;
  String? _currentToken;

  /// Initialize FCM — call once after Firebase.initializeApp().
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Set background message handler
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Request permission (iOS will show the system permission dialog)
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    debugPrint('[FCM] Permission status: ${settings.authorizationStatus}');

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('[FCM] Notifications denied by user');
      return;
    }

    // Get APNs token first (iOS requirement) — may need retries
    if (Platform.isIOS) {
      String? apnsToken = await _messaging.getAPNSToken();
      if (apnsToken == null) {
        // APNs token may not be ready immediately; retry up to 3 times
        for (int i = 0; i < 3 && apnsToken == null; i++) {
          debugPrint('[FCM] APNs token not ready, retry ${i + 1}/3...');
          await Future.delayed(const Duration(seconds: 2));
          apnsToken = await _messaging.getAPNSToken();
        }
      }
      debugPrint('[FCM] APNs token: ${apnsToken != null ? "present (${apnsToken.length} chars)" : "⚠️ NULL — push notifications will NOT work!"}');
    }

    // Get FCM token
    try {
      _currentToken = await _messaging.getToken();
      debugPrint('[FCM] Token: ${_currentToken != null ? "${_currentToken!.substring(0, 20)}..." : "⚠️ NULL"}');
    } catch (e) {
      debugPrint('[FCM] Error getting token: $e');
    }

    // Listen for token refresh
    _messaging.onTokenRefresh.listen((newToken) {
      debugPrint('[FCM] Token refreshed');
      _currentToken = newToken;
      _registerTokenWithBackend(newToken);
    });

    // Foreground messages — show a local notification-style banner
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // When user taps notification (app in background)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // Check if app was opened from a terminated-state notification
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      // Defer popup until the app UI is fully built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 800), () {
          _showPopupFromMessage(initialMessage);
        });
      });
    }

    // Clear iOS badge on app open
    _clearBadge();
  }

  /// Register the current FCM token with the backend for the logged-in user.
  Future<void> registerToken() async {
    if (_currentToken == null) {
      // Try getting token again
      try {
        _currentToken = await _messaging.getToken();
      } catch (e) {
        debugPrint('[FCM] Failed to get token: $e');
        return;
      }
    }
    if (_currentToken != null) {
      await _registerTokenWithBackend(_currentToken!);
    }
  }

  /// Unregister FCM token on logout.
  Future<void> unregisterToken() async {
    if (_currentToken == null) return;
    try {
      final api = ApiService();
      await api.removeFcmToken(_currentToken!);
      debugPrint('[FCM] Token unregistered from backend');
    } catch (e) {
      debugPrint('[FCM] Error unregistering token: $e');
    }
  }

  Future<void> _registerTokenWithBackend(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      if (userId == null) {
        debugPrint('[FCM] No userId — skipping token registration');
        return;
      }
      final api = ApiService();
      await api.registerFcmToken(token);
      debugPrint('[FCM] Token registered with backend');
    } catch (e) {
      debugPrint('[FCM] Error registering token: $e');
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('[FCM] Foreground message: ${message.notification?.title}');

    final notification = message.notification;
    if (notification == null) return;

    final dataType = message.data['type']?.toString() ?? '';

    // Add to NotificationService for bell badge count + notification center
    final context = navigatorKey.currentContext;
    if (context != null) {
      try {
        final notifType = (dataType == 'new_order' || dataType == 'new_orders_batch')
            ? 'orders'
            : (dataType.startsWith('approval'))
                ? 'approvals'
                : (dataType == 'dispatch_doc' || dataType == 'transport_doc')
                    ? 'documents'
                    : 'general';
        final notifService = Provider.of<NotificationService>(context, listen: false);
        notifService.addNotification(AppNotification(
          id: 'fcm_${DateTime.now().millisecondsSinceEpoch}',
          title: notification.title ?? 'Notification',
          body: notification.body ?? '',
          timestamp: DateTime.now(),
          type: notifType,
        ));
      } catch (e) {
        debugPrint('[FCM] Could not add to NotificationService: $e');
      }
    }

    // Show popup for all notification types
    _showPopupFromMessage(message);
  }

  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('[FCM] Notification tapped: ${message.data}');
    final nav = navigatorKey.currentState;
    if (nav != null) {
      nav.pushNamedAndRemoveUntil('/', (route) => false);
    }
    // Delay popup so dashboard loads first
    Future.delayed(const Duration(milliseconds: 600), () {
      _showPopupFromMessage(message);
    });
  }

  void _navigateFromData(Map<String, dynamic> data) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;

    final dataType = data['type']?.toString() ?? '';
    // For order notifications, go to View Orders with client pre-filled
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
      _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: false,
        sound: true,
      );
      // Clear badge count via platform channel
      const channel = MethodChannel('com.sygt.cardamom/badge');
      channel.invokeMethod('clearBadge').catchError((_) {
        // Badge channel not set up — use Firebase approach
        debugPrint('[FCM] Badge channel not available, using Firebase');
      });
    }
  }

  /// Route incoming message to the appropriate popup.
  void _showPopupFromMessage(RemoteMessage message) {
    final data = message.data;
    final dataType = data['type']?.toString() ?? '';

    if (dataType == 'new_order' || dataType == 'new_orders_batch') {
      final createdBy = data['createdBy']?.toString() ?? '';
      final client = data['client']?.toString() ?? '';
      final orderDetails = data['orderDetails']?.toString()
          ?? message.notification?.body ?? '';
      _showOrderNotificationPopup(
        title: message.notification?.title ?? 'New Orders Added',
        createdBy: createdBy,
        client: client,
        orderDetails: orderDetails,
        data: data,
      );
    } else if (dataType == 'approval_request' || dataType == 'approval_resolved') {
      _showGeneralNotificationPopup(
        title: message.notification?.title ?? 'Notification',
        body: message.notification?.body ?? '',
        data: data,
      );
    } else {
      // Any other notification type — show general popup
      _showGeneralNotificationPopup(
        title: message.notification?.title ?? 'Notification',
        body: message.notification?.body ?? '',
        data: data,
      );
    }

    _clearBadge();
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

    // Parse order lines from the details string
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
