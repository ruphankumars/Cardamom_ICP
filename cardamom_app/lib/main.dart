import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/push_notification_service.dart';
import 'services/auth_provider.dart';
import 'services/notification_service.dart';
import 'screens/login_screen.dart';
import 'screens/admin_dashboard.dart';
import 'screens/client_dashboard.dart';
import 'screens/view_orders_screen.dart';
import 'screens/negotiation_screen.dart';
import 'screens/client_create_request_screen.dart';
import 'screens/admin_requests_screen.dart';
import 'screens/new_order_screen.dart';
import 'screens/sales_summary_screen.dart';
import 'screens/grade_allocator_screen.dart';
import 'screens/daily_cart_screen.dart';
import 'screens/add_to_cart_screen.dart';
import 'screens/stock_calculator_screen.dart';
import 'screens/admin_screen.dart';
import 'screens/audit_trail_screen.dart';
import 'screens/notification_center_screen.dart';
import 'screens/task_management_screen.dart';
import 'screens/worker_tasks_screen.dart';
import 'screens/pending_approvals_screen.dart';
import 'screens/attendance_dashboard.dart';
import 'screens/attendance_calendar.dart';
import 'screens/daily_expense_sheet.dart';
import 'screens/gate_pass/gate_pass_list.dart';
import 'screens/my_requests_screen.dart';
import 'screens/dropdown_management_screen.dart';
import 'screens/change_password_screen.dart';
import 'screens/face_attendance_screen.dart';
import 'screens/worker_face_management_screen.dart';
import 'screens/liveness_check_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/offer_price_screen.dart';
import 'screens/outstanding_payments_screen.dart';
import 'screens/dispatch_documents_screen.dart';
import 'screens/transport_list_screen.dart';
import 'screens/transport_send_screen.dart';
import 'screens/transport_history_screen.dart';
import 'screens/report_filter_screen.dart';
import 'screens/ledger_screen.dart';
import 'screens/grade_detail_screen.dart';
import 'services/attendance_service.dart';
import 'services/expense_service.dart';
import 'services/expense_cart_service.dart';
import 'services/gate_pass_service.dart';
import 'services/gate_pass_cache.dart';
import 'services/api_service.dart';
import 'services/connectivity_service.dart';
import 'services/cache_manager.dart';
import 'widgets/protected_route.dart';
import 'widgets/app_shell.dart';
import 'services/navigation_service.dart';
import 'services/ai_provider.dart';
import 'services/operation_queue.dart';
import 'services/persistent_operation_queue.dart';
import 'services/sync_manager.dart';
import 'theme/app_theme.dart';
import 'widgets/ai_fab.dart';
import 'widgets/operation_status_listener.dart';
import 'screens/ai_overlay_screen.dart';
import 'screens/whatsapp_logs_screen.dart';
import 'screens/packed_box_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Global error handling for Flutter framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('⚠️ Flutter error: ${details.exception}');
    // Don't crash the app, just log the error
  };

  // Catch unhandled async errors at the platform level
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('⚠️ Unhandled platform error: $error');
    return true; // Prevent crash
  };
  
  // Initialize push notification polling (replaces Firebase Cloud Messaging)
  try {
    await PushNotificationService.instance.initialize();
    debugPrint('Push notification polling initialized');
  } catch (e) {
    debugPrint('Push notification initialization failed: $e');
    // Continue anyway — app works without push notifications
  }

  // Initialize cache
  final gatePassCache = GatePassCache();
  try {
    await gatePassCache.initialize();
  } catch (e) {
    debugPrint('⚠️ GatePassCache initialization failed: $e');
    // Continue anyway to avoid blocking app startup
  }
  
  // Initialize connectivity monitoring
  final connectivityService = ConnectivityService();
  try {
    await connectivityService.initialize();
  } catch (e) {
    debugPrint('ConnectivityService initialization failed: $e');
  }

  // Initialize cache manager
  final cacheManager = CacheManager(connectivityService);

  // Create services
  final apiService = ApiService();
  final gatePassService = GatePassService(apiService);
  gatePassService.setCache(gatePassCache);

  // Initialize persistent operation queue (offline write queue)
  final persistentQueue = PersistentOperationQueue();
  try {
    await persistentQueue.initialize();
    persistentQueue.setConnectivity(connectivityService);
  } catch (e) {
    debugPrint('⚠️ PersistentOperationQueue initialization failed: $e');
  }

  // Initialize sync manager
  final syncManager = SyncManager(
    apiService: apiService,
    persistentQueue: persistentQueue,
    cacheManager: cacheManager,
    connectivityService: connectivityService,
  );
  
  // Wrap in runZonedGuarded to catch ALL unhandled async errors
  runZonedGuarded(() {
    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: connectivityService),
          ChangeNotifierProvider.value(value: cacheManager),
          ChangeNotifierProvider(create: (_) => OperationQueue()),
          ChangeNotifierProvider.value(value: persistentQueue),
          ChangeNotifierProvider.value(value: syncManager),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => NotificationService(), lazy: true),
          ChangeNotifierProvider(create: (_) => AttendanceService(apiService), lazy: true),
          ChangeNotifierProvider(create: (_) => ExpenseService(apiService), lazy: true),
          ChangeNotifierProvider(create: (_) {
            final cart = ExpenseCartService();
            cart.loadCart().catchError((e) {
              debugPrint('⚠️ ExpenseCartService.loadCart failed: $e');
            });
            return cart;
          }, lazy: true),
          ChangeNotifierProvider.value(value: gatePassCache),
          ChangeNotifierProvider.value(value: gatePassService),
          ChangeNotifierProvider(
            create: (_) => AiProvider(),
            lazy: true, // Only created when AI FAB is accessed
          ),
        ],
        child: const CardamomApp(),
      ),
    );
  }, (error, stack) {
    debugPrint('⚠️ Unhandled zone error: $error');
    // Don't crash — just log
  });
}

// Navigation globals are in services/navigation_service.dart

class CardamomApp extends StatelessWidget {
  const CardamomApp({super.key});

  // Persists across rebuilds — tracks pointer down position to detect scrolls/drags
  static Offset? _pointerDownPos;

  @override
  Widget build(BuildContext context) {
    return OperationStatusListener(
      navigatorKey: navigatorKey,
      child: MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: [appRouteObserver, routeObserver],
      title: 'ICP Cardamom App',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      initialRoute: '/',
      builder: (context, child) {
        // Dismiss keyboard when tapping on empty space outside text fields.
        // Uses Listener (not GestureDetector) to avoid competing with
        // PopupMenuButton and other gesture-based widgets.
        // Uses onPointerUp (not onPointerDown) so scroll/drag gestures
        // don't trigger premature unfocus and layout jumps.
        Widget dismissKeyboardWrapper(Widget content) {
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (PointerDownEvent event) {
              _pointerDownPos = event.position;
            },
            onPointerUp: (PointerUpEvent event) {
              final downPos = _pointerDownPos;
              _pointerDownPos = null;
              if (downPos == null) return;

              // If pointer moved > 20px, it was a scroll/drag — don't unfocus
              if ((event.position - downPos).distance > 20) return;

              final currentFocus = FocusManager.instance.primaryFocus;
              if (currentFocus == null || currentFocus.context == null) return;

              // If tap is inside the focused text field, keep focus
              // (allows double-tap to select word, drag to select text)
              final renderObject = currentFocus.context!.findRenderObject();
              if (renderObject is RenderBox && renderObject.hasSize) {
                final localPos = renderObject.globalToLocal(event.position);
                if (renderObject.paintBounds.contains(localPos)) {
                  return; // Tap inside focused widget — keep focus
                }
              }

              currentFocus.unfocus();
            },
            onPointerCancel: (_) {
              _pointerDownPos = null;
            },
            child: content,
          );
        }

        // On desktop (>= 1200px), show permanent sidebar for authenticated users
        final screenWidth = MediaQuery.of(context).size.width;
        final isDesktop = screenWidth >= 1200;
        final auth = context.watch<AuthProvider>();

        if (!isDesktop || child == null || !auth.isLoggedIn) {
          // Add AI FAB overlay for superadmin only on mobile
          if (auth.isLoggedIn && child != null) {
            final isSuperAdmin = auth.role?.toLowerCase() == 'superadmin';
            return dismissKeyboardWrapper(
              Stack(
                children: [
                  child,
                  if (isSuperAdmin)
                    Positioned(
                      left: 16,
                      bottom: 100,
                      child: SafeArea(
                        top: false,
                        child: const AiFab(),
                      ),
                    ),
                ],
              ),
            );
          }
          return dismissKeyboardWrapper(child ?? const SizedBox.shrink());
        }

        const sidebarWidth = 260.0;
        return dismissKeyboardWrapper(
          Row(
            children: [
              SizedBox(
                width: sidebarWidth,
                child: Material(
                  child: DesktopSidePanel(
                    onNavigate: (route) {
                      final nav = navigatorKey.currentState;
                      if (nav == null) return;
                      // Dashboard routes: clear stack and set as base
                      if (route == '/admin_dashboard' || route == '/client_dashboard') {
                        nav.pushNamedAndRemoveUntil(route, (r) => false);
                      } else {
                        // Other routes: push on clean stack with dashboard as base
                        final dashRoute = auth.role?.toLowerCase() == 'client'
                            ? '/client_dashboard'
                            : '/admin_dashboard';
                        nav.pushNamedAndRemoveUntil(dashRoute, (r) => false);
                        nav.pushNamed(route);
                      }
                    },
                  ),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        size: Size(screenWidth - sidebarWidth, MediaQuery.of(context).size.height),
                      ),
                      child: child,
                    ),
                    if (auth.role?.toLowerCase() == 'superadmin')
                      const Positioned(
                        right: 16,
                        bottom: 100,
                        child: AiFab(),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/negotiation' || settings.name == '/client_negotiation') {
          final args = settings.arguments as Map<String, dynamic>? ?? {};
          final requestId = args['id']?.toString();
          if (requestId == null || requestId.isEmpty) {
            return MaterialPageRoute(
              builder: (_) => const Scaffold(
                body: Center(child: Text('Invalid request ID')),
              ),
            );
          }
          return MaterialPageRoute(
            builder: (context) => NegotiationScreen(requestId: requestId),
          );
        }
        if (settings.name == '/create_request') {
          final args = settings.arguments as Map<String, dynamic>? ?? {};
          return MaterialPageRoute(
            builder: (context) => ClientCreateRequestScreen(initialType: args['type']),
          );
        }
        if (settings.name == '/new_order') {
          final args = settings.arguments as Map<String, dynamic>?;
          return MaterialPageRoute(
            builder: (context) => ProtectedRoute(
              pageKey: 'new_order',
              child: NewOrderScreen(prefillData: args),
            ),
          );
        }
        // Handle /view_orders with optional URL parameters
        if (settings.name != null && settings.name!.startsWith('/view_orders')) {
          String? status, billing, search;
          // Parse URL parameters (e.g., /view_orders?status=pending&billing=SYGT)
          final uri = Uri.tryParse(settings.name!);
          if (uri != null && uri.queryParameters.isNotEmpty) {
            status = uri.queryParameters['status'];
            billing = uri.queryParameters['billing'];
            search = uri.queryParameters['search'] ?? 
                     uri.queryParameters['client'] ?? 
                     uri.queryParameters['grade'];
          }
          // Also check for arguments passed directly
          final args = settings.arguments as Map<String, dynamic>?;
          if (args != null) {
            status ??= args['status'];
            billing ??= args['billing'];
            search ??= args['search'];
          }
          return MaterialPageRoute(
            settings: RouteSettings(
              name: settings.name, // Preserve route name (including query params if any)
              arguments: settings.arguments,
            ),
            builder: (context) => ProtectedRoute(
              pageKey: 'view_orders',
              child: ViewOrdersScreen(
                initialStatus: status,
                initialBilling: billing,
                initialSearch: search,
              ),
            ),
          );
        }
        // Handle /report_filter with report type argument
        if (settings.name == '/report_filter') {
          final args = settings.arguments as Map<String, dynamic>? ?? {};
          final reportType = args['reportType'];
          if (reportType is! ReportType) return null;
          return MaterialPageRoute(
            builder: (context) => ProtectedRoute(
              pageKey: 'sales_summary',
              child: ReportFilterScreen(reportType: reportType),
            ),
          );
        }
        // Handle /grade_detail with arguments
        if (settings.name == '/grade_detail') {
          final args = settings.arguments as Map<String, dynamic>? ?? {};
          final grade = args['grade']?.toString() ?? '';
          if (grade.isEmpty) {
            return MaterialPageRoute(
              builder: (_) => const Scaffold(body: Center(child: Text('No grade specified'))),
            );
          }
          return MaterialPageRoute(
            builder: (context) => ProtectedRoute(
              pageKey: 'sales_summary',
              child: GradeDetailScreen(
                grade: grade,
                statusFilter: args['status']?.toString() ?? '',
                billingFilter: args['billingFrom']?.toString() ?? '',
                clientFilter: args['client']?.toString() ?? '',
                dateFilter: args['date']?.toString(),
              ),
            ),
          );
        }
        // Handle /attendance with optional date parameter
        if (settings.name == '/attendance') {
          final args = settings.arguments as Map<String, dynamic>?;
          final date = args?['date'] as String?;
          return MaterialPageRoute(
            builder: (context) => ProtectedRoute(
              pageKey: 'attendance',
              child: AttendanceDashboardScreen(initialDate: date),
            ),
          );
        }
        return null;
      },
      routes: {
        '/': (context) => const AuthWrapper(),
        '/login': (context) => const LoginScreen(),
        '/change_password': (context) => const ChangePasswordScreen(),
        '/client_dashboard': (context) => const ClientDashboard(),
        '/admin_dashboard': (context) => const AdminDashboard(),
        '/order_requests': (context) => const ProtectedRoute(pageKey: 'order_requests', child: AdminRequestsScreen()),
        '/sales_summary': (context) => const ProtectedRoute(pageKey: 'sales_summary', child: SalesSummaryScreen()),
        '/grade_allocator': (context) => const ProtectedRoute(pageKey: 'grade_allocator', child: GradeAllocatorScreen()),
        '/daily_cart': (context) => const ProtectedRoute(pageKey: 'daily_cart', child: DailyCartScreen()),
        '/add_to_cart': (context) => const ProtectedRoute(pageKey: 'add_to_cart', child: AddToCartScreen()),
        '/stock_tools': (context) => const ProtectedRoute(pageKey: 'stock_tools', child: StockCalculatorScreen()),
        '/admin': (context) => const ProtectedRoute(pageKey: 'admin', child: AdminScreen()),
        '/audit_trail': (context) => const AuditTrailScreen(),
        '/notifications': (context) => const NotificationCenterScreen(),
        '/task_management': (context) => const ProtectedRoute(pageKey: 'task_management', child: TaskManagementScreen()),
        '/worker_tasks': (context) => const WorkerTasksScreen(),
        '/pending_approvals': (context) => const ProtectedRoute(pageKey: 'pending_approvals', child: PendingApprovalsScreen()),
        // Note: /attendance is handled in onGenerateRoute to support date parameter
        '/attendance/calendar': (context) => const ProtectedRoute(pageKey: 'attendance', child: AttendanceCalendarScreen()),
        '/expenses': (context) => const ProtectedRoute(pageKey: 'expenses', child: DailyExpenseSheet()),
        '/gate_passes': (context) => const ProtectedRoute(pageKey: 'gate_passes', child: GatePassList()),
        '/my_requests': (context) => const MyRequestsScreen(),
        '/dropdown_management': (context) => const ProtectedRoute(pageKey: 'admin', child: DropdownManagementScreen()),
        '/reports': (context) => const ProtectedRoute(pageKey: 'sales_summary', child: ReportsScreen()),
        '/face_attendance': (context) => const ProtectedRoute(pageKey: 'attendance', child: FaceAttendanceScreen(mode: 'rollcall')),
        '/face_enroll': (context) => const ProtectedRoute(pageKey: 'attendance', child: FaceAttendanceScreen(mode: 'enroll')),
        '/face_management': (context) => const ProtectedRoute(pageKey: 'attendance', child: WorkerFaceManagementScreen()),
        '/liveness_check': (context) => const ProtectedRoute(pageKey: 'attendance', child: LivenessCheckScreen()),
        '/offer_price': (context) => const ProtectedRoute(pageKey: 'offer_price', child: OfferPriceScreen()),
        '/outstanding': (context) => const ProtectedRoute(pageKey: 'outstanding', child: OutstandingPaymentsScreen()),
        '/dispatch_documents': (context) => const ProtectedRoute(pageKey: 'dispatch_documents', child: DispatchDocumentsScreen()),
        '/transport_list': (context) => const ProtectedRoute(pageKey: 'dispatch_documents', child: TransportListScreen()),
        '/transport_send': (context) => const ProtectedRoute(pageKey: 'dispatch_documents', child: TransportSendScreen()),
        '/transport_history': (context) => const ProtectedRoute(pageKey: 'dispatch_documents', child: TransportHistoryScreen()),
        '/ledger': (context) => const ProtectedRoute(pageKey: 'ledger', child: LedgerScreen()),
        '/ai_overlay': (context) => const ProtectedRoute(pageKey: 'ai_overlay', child: AiOverlayScreen()),
        '/whatsapp_logs': (context) => const ProtectedRoute(pageKey: 'whatsapp_logs', child: WhatsappLogsScreen()),
        '/packed_boxes': (context) => const ProtectedRoute(pageKey: 'packed_boxes', child: PackedBoxScreen()),
      },
    ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _isInitialized = false;
  bool _hasNavigated = false;

  @override
  void initState() {
    super.initState();
    // Wait for auth provider to load from SharedPreferences
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuthAndNavigate();
    });
  }

  void _checkAuthAndNavigate() {
    if (!mounted || _hasNavigated) return;

    final authProvider = context.read<AuthProvider>();

    // Wait for auth provider to finish loading session from SharedPreferences
    if (authProvider.isLoading) {
      // Use a one-shot listener to avoid leak
      void onAuthLoaded() {
        authProvider.removeListener(onAuthLoaded);
        _checkAuthAndNavigate();
      }
      authProvider.addListener(onAuthLoaded);
      return;
    }

    // Mark as initialized so we show proper content
    setState(() {
      _isInitialized = true;
    });

    // If logged in, navigate to appropriate screen
    if (authProvider.isLoggedIn) {
      _hasNavigated = true;
      final role = authProvider.role?.toLowerCase(); // Normalize role for case-insensitive check
      // Use pushReplacement to ensure there's a route in history
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (authProvider.mustChangePassword) {
            Navigator.of(context).pushReplacementNamed('/change_password');
          } else {
            Navigator.of(context).pushReplacementNamed(
              role == 'client' ? '/client_dashboard' : '/admin_dashboard',
            );
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Show loading splash while initializing
        if (!_isInitialized) {
          return Scaffold(
            body: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFF1F5F9), Color(0xFFE2E8F0)],
                ),
              ),
              child: const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF5D6E7E),
                ),
              ),
            ),
          );
        }
        
        // After initialization, just show login if not logged in
        // (If logged in, we'll navigate away in _checkAuthAndNavigate)
        if (authProvider.isLoggedIn && !_hasNavigated) {
          // Trigger navigation if auth state changed
          _hasNavigated = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              if (authProvider.mustChangePassword) {
                Navigator.of(context).pushReplacementNamed('/change_password');
              } else {
                final role = authProvider.role?.toLowerCase(); // Normalize role
                Navigator.of(context).pushReplacementNamed(
                  role == 'client' ? '/client_dashboard' : '/admin_dashboard',
                );
              }
            }
          });
          // Show loading while navigating
          return Scaffold(
            body: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFF1F5F9), Color(0xFFE2E8F0)],
                ),
              ),
              child: const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF5D6E7E),
                ),
              ),
            ),
          );
        }
        
        return const LoginScreen();
      },
    );
  }
}

class PlaceholderScreen extends StatelessWidget {
  final String title;
  const PlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(child: Text('Welcome to $title')),
    );
  }
}
