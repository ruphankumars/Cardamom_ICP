import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'auth_provider.dart';
import 'navigation_service.dart' show navigatorKey;

class ApiService {
  static ApiService? _instance;
  late final Dio _dio;
  String? _authToken;  // JWT token for authentication
  static Timer? _fallbackResetTimer;  // Cancellable DNS fallback timer

  /// Expose Dio instance for PersistentOperationQueue replay.
  Dio get dio => _dio;

  factory ApiService() => _instance ??= ApiService._internal();

  /// Protected constructor for subclassing in tests
  @protected
  ApiService.forTesting() {
    _dio = _createDioWithCertificateBypass();
    _dio.options.baseUrl = baseUrl;
    _dio.options.connectTimeout = const Duration(seconds: 30);
    _dio.options.receiveTimeout = const Duration(seconds: 120);
    _dio.options.sendTimeout = const Duration(seconds: 120);
  }

  // ICP canister backend URL
  // Local dev: http://uxrrr-q7777-77774-qaaaq-cai.localhost:4943/api
  // Production: update canister ID after mainnet deploy (dfx deploy --network ic)
  static const String _cloudUrl = 'https://ur3eo-5iaaa-aaaah-avewa-cai.raw.icp0.io/api';

  // Fallback URL (local development)
  static const String _fallbackIpUrl = 'http://localhost:4943/api';

  // Local development URL
  static const String _localUrl = 'http://172.20.10.4:3000/api';
  
  // Track if we should use fallback
  static bool _useFallback = false;

  /// Activate IP fallback (called by ConnectivityService when DNS fails).
  static void activateFallback() {
    if (_useFallback) return;
    _useFallback = true;
    debugPrint('🔄 [ApiService] Fallback activated by ConnectivityService');
    _fallbackResetTimer?.cancel();
    _fallbackResetTimer = Timer(const Duration(minutes: 5), () {
      _useFallback = false;
      debugPrint('🔄 [ApiService] Fallback reset — will try primary DNS next request');
    });
  }
  
  static String get baseUrl {
    // In Web builds, use cloud URL (browsers handles DNS)
    if (kIsWeb) {
      return _cloudUrl; // Always use cloud URL
      // return kDebugMode ? 'http://127.0.0.1:3000/api' : _cloudUrl; 
    }

    // Always use cloud URL for release builds on native
    if (!kDebugMode) {
      return _useFallback ? _fallbackIpUrl : _cloudUrl;
    }
    
    // In debug mode, use local only for desktop (macOS)
    // Physical devices should use cloud URL
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return 'http://127.0.0.1:3000/api';
    }
    
    // For iOS and Android physical devices, always use cloud URL
    return _useFallback ? _fallbackIpUrl : _cloudUrl;
  }
  
  // Create a Dio instance that accepts all certificates (for IP fallback)
  static Dio _createDioWithCertificateBypass() {
    final dio = Dio();
    
    // Only bypass cert check on mobile platforms (not web)
    if (!kIsWeb) {
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        final client = HttpClient();
        client.badCertificateCallback = (X509Certificate cert, String host, int port) {
          // Only bypass certificate check for fallback IP in debug mode.
          // Production domain uses valid Render-managed TLS certificate.
          return !kReleaseMode && host == '216.24.57.7';
        };
        return client;
      };
    }
    
    return dio;
  }

  ApiService._internal() {
    _dio = _createDioWithCertificateBypass();
    _dio.options.baseUrl = baseUrl;
    _dio.options.connectTimeout = const Duration(seconds: 30);
    _dio.options.receiveTimeout = const Duration(seconds: 120);
    _dio.options.sendTimeout = const Duration(seconds: 120);

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        // Update baseUrl in case fallback was triggered
        options.baseUrl = baseUrl;
        
        // Host header override removed — ICP canister handles routing directly
        
        options.headers['Content-Type'] = 'application/json';

        // Don't add auth headers for public endpoints
        if (options.path.contains('/auth/login') ||
            options.path.contains('/auth/face-login') ||
            options.path.contains('/users/face-data/all')) {
          debugPrint('🔵 Public Request: ${options.baseUrl}${options.path}');
          return handler.next(options);
        }

        // Use JWT authentication (secure)
        if (_authToken != null) {
          options.headers['Authorization'] = 'Bearer $_authToken';
          debugPrint('🔐 Auth Token: Bearer ${_authToken!.length > 20 ? '${_authToken!.substring(0, 20)}...' : '***'}');
        } else {
          // Fallback: Load token from SharedPreferences if not in memory
          final prefs = await SharedPreferences.getInstance();
          final storedToken = prefs.getString('auth_token');

          if (storedToken != null) {
            _authToken = storedToken;
            options.headers['Authorization'] = 'Bearer $storedToken';
            debugPrint('🔐 Auth Token (from storage): Bearer ${storedToken.length > 20 ? '${storedToken.substring(0, 20)}...' : '***'}');
          } else {
            debugPrint('⚠️ No auth token found - request may fail');
          }
        }

        return handler.next(options);
      },
      onResponse: (response, handler) {
        // Only log responses in debug mode (skip in release/profile for performance)
        assert(() { debugPrint('✅ ${response.requestOptions.path} - ${response.statusCode}'); return true; }());
        return handler.next(response);
      },
      onError: (error, handler) async {
        debugPrint('❌ API Error: ${error.requestOptions.path}');
        debugPrint('❌ Error Type: ${error.type}');
        debugPrint('❌ Error Message: ${error.message}');
        
        // Check if this is a DNS resolution error and we haven't tried fallback yet
        if (!_useFallback && 
            error.message != null && 
            (error.message!.contains('Failed host lookup') || 
             error.message!.contains('SocketException') ||
             error.type == DioExceptionType.connectionError)) {
          debugPrint('🔄 DNS error detected, switching to IP fallback...');
          _useFallback = true;
          // Auto-reset fallback after 5 minutes to retry primary DNS (cancellable)
          _fallbackResetTimer?.cancel();
          _fallbackResetTimer = Timer(const Duration(minutes: 5), () {
            _useFallback = false;
            debugPrint('🔄 Fallback reset — will try primary DNS next request');
          });
          
          // Retry the request with fallback URL
          try {
            final opts = error.requestOptions;
            opts.baseUrl = _fallbackIpUrl;
            // Host header override removed — ICP canister handles routing directly
            final response = await _dio.fetch(opts);
            return handler.resolve(response);
          } catch (retryError) {
            debugPrint('❌ Fallback also failed: $retryError');
          }
        }
        
        if (error.response != null) {
          debugPrint('❌ Response Status: ${error.response?.statusCode}');
          debugPrint('❌ Response Data: ${error.response?.data}');

          // Token expired — try reloading from storage before giving up
          // Handle both 401 and 403 with token-related error messages
          final statusCode = error.response?.statusCode;
          final errorMsg = error.response?.data?['error']?.toString() ?? '';
          final isTokenExpiry = statusCode == 401 ||
              (statusCode == 403 && errorMsg.toLowerCase().contains('token'));
          if (isTokenExpiry &&
              !error.requestOptions.path.contains('/auth/login') &&
              !error.requestOptions.path.contains('/auth/face-login') &&
              !error.requestOptions.extra.containsKey('_tokenRetried')) {
            // One-time retry: reload token from storage (app may have been
            // killed by iOS during camera use and _authToken lost in memory)
            final prefs = await SharedPreferences.getInstance();
            final storedToken = prefs.getString('auth_token');
            if (storedToken != null && storedToken != _authToken) {
              debugPrint('🔄 Token mismatch — retrying with stored token');
              _authToken = storedToken;
              final opts = error.requestOptions;
              opts.headers['Authorization'] = 'Bearer $storedToken';
              opts.extra['_tokenRetried'] = true; // prevent infinite retry
              try {
                final response = await _dio.fetch(opts);
                return handler.resolve(response);
              } catch (retryError) {
                debugPrint('❌ Token retry also failed: $retryError');
              }
            }

            // Token genuinely expired — clear and redirect to login
            debugPrint('🔒 Token expired — redirecting to login');
            await clearAuthToken();
            // Only remove auth-related keys, preserve offline caches
            final prefsForClear = await SharedPreferences.getInstance();
            for (final key in ['isLoggedIn', 'username', 'userRole', 'clientName', 'userId', 'pageAccess']) {
              await prefsForClear.remove(key);
            }
            // Notify AuthProvider so in-memory state is also cleared
            try {
              final ctx = navigatorKey.currentContext;
              if (ctx != null) {
                final authProvider = Provider.of<AuthProvider>(ctx, listen: false);
                authProvider.clearSession();
              }
            } catch (_) {}
            navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (_) => false);
          }
        }
        return handler.next(error);
      },
    ));
  }


  // Dashboard
  Future<Response> getDashboard() => _dio.get('/dashboard');

  // Stock
  Future<Response> getNetStock() => _dio.get('/stock/net');
  
  Future<Response> addPurchase(List<num> qtyArray, {String? date}) =>
      _dio.post('/stock/purchase', data: {'qtyArray': qtyArray, if (date != null) 'date': date});

  Future<Response> recalcStock() => _dio.post('/stock/recalc');

  Future<Response> getDeltaStatus() => _dio.get('/stock/delta-status');

  Future<Response> addStockAdjustment(Map<String, dynamic> payload, {String? date}) =>
      _dio.post('/stock/adjust', data: {...payload, if (date != null) 'date': date});

  Future<Response> clearRejectionAdjustments() =>
      _dio.post('/stock/clear-rejection');

  Future<Response> getStockPurchaseHistory({int limit = 100, String? startDate, String? endDate}) {
    final params = <String, dynamic>{'limit': limit};
    if (startDate != null) params['startDate'] = startDate;
    if (endDate != null) params['endDate'] = endDate;
    return _dio.get('/stock/purchase-history', queryParameters: params);
  }

  Future<Response> getStockAdjustmentHistory({int limit = 100, String? startDate, String? endDate}) {
    final params = <String, dynamic>{'limit': limit};
    if (startDate != null) params['startDate'] = startDate;
    if (endDate != null) params['endDate'] = endDate;
    return _dio.get('/stock/adjustment-history', queryParameters: params);
  }

  // Orders
  Future<Response> getOrders() => _dio.get('/orders', queryParameters: {'all': 'true'});

  /// Fetch orders with server-side filtering.
  /// Only queries the Firestore collection(s) matching [status],
  /// then applies [client], [billing], [grade] filters on doc fields.
  Future<Response> getFilteredOrders({
    String status = '',
    String client = '',
    String billing = '',
    String grade = '',
  }) {
    final params = <String, dynamic>{};
    params['status'] = status.isNotEmpty ? status : 'all';
    if (client.isNotEmpty) params['client'] = client;
    if (billing.isNotEmpty) params['billing'] = billing;
    if (grade.isNotEmpty) params['grade'] = grade;
    return _dio.get('/orders', queryParameters: params);
  }

  Future<Response> addOrder(Map<String, dynamic> order) =>
      _dio.post('/orders', data: order);

  Future<Response> addOrders(List<Map<String, dynamic>> orders) => 
      _dio.post('/orders/batch', data: orders);

  Future<Response> updateOrder(dynamic orderId, Map<String, dynamic> order) =>
      _dio.put('/orders/$orderId', data: order);

  Future<Response> updatePackedOrder(String docId, Map<String, dynamic> data) =>
      _dio.put('/orders/packed/$docId', data: data);

  Future<Response> deleteOrder(dynamic orderId) =>
      _dio.delete('/orders/$orderId');

  Future<Response> getNextLotNumber(String client) =>
      _dio.get('/orders/next-lot', queryParameters: {'client': client});

  Future<Response> getDropdownOptions() => _dio.get('/orders/dropdowns');

  // Offer Price
  Future<Response> createOffer(Map<String, dynamic> data) =>
      _dio.post('/offers', data: data);

  Future<Response> getOfferHistory({String? client, String? grade, String? dateFrom, String? dateTo, int? limit}) {
    final params = <String, dynamic>{};
    if (client != null) params['client'] = client;
    if (grade != null) params['grade'] = grade;
    if (dateFrom != null) params['dateFrom'] = dateFrom;
    if (dateTo != null) params['dateTo'] = dateTo;
    if (limit != null) params['limit'] = limit;
    return _dio.get('/offers', queryParameters: params);
  }

  Future<Response> getOfferSuggestions() => _dio.get('/offers/suggestions');

  Future<Response> getOfferAnalytics({String? dateFrom, String? dateTo}) {
    final params = <String, dynamic>{};
    if (dateFrom != null) params['dateFrom'] = dateFrom;
    if (dateTo != null) params['dateTo'] = dateTo;
    return _dio.get('/offers/analytics', queryParameters: params);
  }

  Future<Response> getExchangeRate() => _dio.get('/offers/exchange-rate');

  Future<Response> deleteOffer(String id) => _dio.delete('/offers/$id');

  Future<Response> bulkDeleteOffers(List<String> ids) =>
      _dio.post('/offers/bulk-delete', data: {'ids': ids});

  // Dropdown CRUD
  Future<Response> searchDropdownItems(String category, String query) =>
      _dio.get('/dropdowns/$category/search', queryParameters: {'q': query});

  Future<Response> addDropdownItem(String category, String value) =>
      _dio.post('/dropdowns/$category/add', data: {'value': value});

  Future<Response> forceAddDropdownItem(String category, String value) =>
      _dio.post('/dropdowns/$category/force-add', data: {'value': value});

  Future<Response> getDropdownCategory(String category) =>
      _dio.get('/dropdowns/$category');

  Future<Response> updateDropdownItem(String category, String oldValue, String newValue) =>
      _dio.put('/dropdowns/$category/item', data: {'oldValue': oldValue, 'newValue': newValue});

  Future<Response> deleteDropdownItem(String category, String value) =>
      _dio.delete('/dropdowns/$category/item', data: {'value': value});

  Future<Response> getSalesSummary([Map<String, dynamic>? filters]) =>
      _dio.get('/orders/sales-summary', queryParameters: filters);

  Future<Response> getOrdersByGrade(String grade, [Map<String, dynamic>? filters]) =>
      _dio.get('/orders/by-grade', queryParameters: {'grade': grade, ...?filters});

  Future<Response> getPendingOrders() => _dio.get('/orders/pending');
  
  Future<Response> getTodayCart() => _dio.get('/orders/today-cart');

  Future<Response> addToCart(List<dynamic> selectedOrders, {String? cartDate, bool markBilled = false}) =>
      _dio.post('/orders/add-to-cart', data: {
        'selectedOrders': selectedOrders,
        if (cartDate != null) 'cartDate': cartDate,
        if (markBilled) 'markBilled': true,
      });

  Future<Response> removeFromCart(String lot, String client, String billingFrom, {String? docId}) =>
      _dio.post('/orders/remove-from-cart', data: {'lot': lot, 'client': client, 'billingFrom': billingFrom, if (docId != null) 'docId': docId});

  // Transport assignments (daily client→transport mapping, synced across users)
  Future<Response> getTransportAssignments(String date) =>
      _dio.get('/orders/transport-assignments', queryParameters: {'date': date});

  Future<Response> saveTransportAssignments(String date, Map<String, String> assignments, {List<String> removals = const []}) =>
      _dio.put('/orders/transport-assignments', data: {'date': date, 'assignments': assignments, 'removals': removals});

  Future<Response> batchRemoveFromCart(List<dynamic> items) => 
      _dio.post('/orders/batch-remove-from-cart', data: {'items': items});

  Future<Response> partialDispatch(dynamic order, double dispatchQty) => 
      _dio.post('/orders/partial-dispatch', data: {'order': order, 'dispatchQty': dispatchQty});

  Future<Response> cancelPartialDispatch(String lot, String client) =>
      _dio.post('/orders/cancel-partial-dispatch', data: {'lot': lot, 'client': client});

  Future<Response> getClientOrders(String clientName) =>
      _dio.get('/orders/client-summary', queryParameters: {'clientName': clientName});

  Future<Response> getLedgerClients() => _dio.get('/orders/ledger-clients');

  Future<Response> archiveCartToPackedOrders({String? targetDate}) => 
      _dio.post('/orders/archive-cart', data: targetDate != null ? {'targetDate': targetDate} : {});

  // Client Contact - for WhatsApp sharing
  Future<Response> getClientContact(String clientName) =>
      _dio.get('/clients/contact/${Uri.encodeComponent(clientName)}');

  Future<Response> getAllClientContacts() =>
      _dio.get('/clients/contacts/all');

  Future<Response> updateClientContact(String name, {String? oldName, String? phone, List<String>? phones, String? address, String? gstin}) =>
      _dio.put('/clients/contact', data: {
        'name': name,
        if (oldName != null) 'oldName': oldName,
        if (phones != null) 'phones': phones,
        if (phone != null && phones == null) 'phone': phone,
        if (address != null) 'address': address,
        if (gstin != null) 'gstin': gstin,
      });

  /// Verify if a phone number is active on WhatsApp
  Future<Response> verifyWhatsAppNumber(String phone) =>
      _dio.get('/whatsapp/verify/${Uri.encodeComponent(phone)}');

  /// Send an image to WhatsApp number(s) via Cloud API
  Future<Response> sendWhatsAppImage({
    required String imageBase64,
    String? phone,
    List<String>? phones,
    String? caption,
    String? clientName,
    String? operationType,
    String? companyName,
  }) {
      // #69: Validate at least one recipient is provided
      if ((phones == null || phones.isEmpty) && (phone == null || phone.isEmpty)) {
        return Future.error(ArgumentError('At least one phone number is required to send WhatsApp image'));
      }
      return _dio.post('/whatsapp/send-image', data: {
        'imageBase64': imageBase64,
        if (phones != null && phones.isNotEmpty) 'phones': phones,
        if (phone != null && (phones == null || phones.isEmpty)) 'phone': phone,
        if (caption != null) 'caption': caption,
        if (clientName != null) 'clientName': clientName,
        if (operationType != null) 'operationType': operationType,
        if (companyName != null) 'companyName': companyName,
      });
  }

  /// Fire-and-forget: send outstanding payment reminders via backend.
  /// Backend generates images + sends WhatsApp. Returns immediately.
  Future<Response> sendOutstandingReminders(List<Map<String, dynamic>> clients) =>
      _dio.post('/outstanding/send-reminders', data: { 'clients': clients });

  /// Send a text-only WhatsApp message to phone(s)
  Future<Response> sendWhatsAppText({
    String? phone,
    List<String>? phones,
    String? clientName,
    String? orderId,
    String? orderDetails,
    String? totalAmount,
  }) =>
      _dio.post('/whatsapp/send-text', data: {
        if (phones != null && phones.isNotEmpty) 'phones': phones,
        if (phone != null && (phones == null || phones.isEmpty)) 'phone': phone,
        if (clientName != null) 'clientName': clientName,
        if (orderId != null) 'orderId': orderId,
        if (orderDetails != null) 'orderDetails': orderDetails,
        if (totalAmount != null) 'totalAmount': totalAmount,
      });

  // ===== Dispatch Documents =====

  /// Create dispatch document: upload image, server enhances + generates PDF, sends WhatsApp
  Future<Response> createDispatchDocument({
    required List<String> imagesBase64,
    required String clientName,
    required String date,
    required String companyName,
    String? notes,
    String? lrNumber,
    String? invoiceNumber,
    String? invoiceDate,
    List<String>? linkedOrderIds,
    List<Map<String, dynamic>>? linkedOrders,
    required List<String> phones,
    required String createdBy,
  }) =>
      _dio.post('/dispatch-documents', data: {
        'imagesBase64': imagesBase64,
        'clientName': clientName,
        'date': date,
        'companyName': companyName,
        if (notes != null) 'notes': notes,
        if (lrNumber != null && lrNumber.isNotEmpty) 'lrNumber': lrNumber,
        if (invoiceNumber != null && invoiceNumber.isNotEmpty) 'invoiceNumber': invoiceNumber,
        if (invoiceDate != null && invoiceDate.isNotEmpty) 'invoiceDate': invoiceDate,
        if (linkedOrderIds != null && linkedOrderIds.isNotEmpty) 'linkedOrderIds': linkedOrderIds,
        if (linkedOrders != null && linkedOrders.isNotEmpty) 'linkedOrders': linkedOrders,
        'phones': phones,
        'createdBy': createdBy,
      }, options: Options(sendTimeout: const Duration(seconds: 300), receiveTimeout: const Duration(seconds: 300)));

  /// List dispatch documents with optional filters
  Future<Response> getDispatchDocuments({
    String? clientName,
    String? dateFrom,
    String? dateTo,
    String? companyName,
    int? limit,
  }) {
    final params = <String, dynamic>{};
    if (clientName != null) params['clientName'] = clientName;
    if (dateFrom != null) params['dateFrom'] = dateFrom;
    if (dateTo != null) params['dateTo'] = dateTo;
    if (companyName != null) params['companyName'] = companyName;
    if (limit != null) params['limit'] = limit;
    return _dio.get('/dispatch-documents', queryParameters: params);
  }

  /// Get single dispatch document
  Future<Response> getDispatchDocument(String id) =>
      _dio.get('/dispatch-documents/$id');

  /// Update dispatch document (notes, linked orders)
  Future<Response> updateDispatchDocument(String id, Map<String, dynamic> data) =>
      _dio.put('/dispatch-documents/$id', data: data);

  /// Delete dispatch document (soft delete)
  Future<Response> deleteDispatchDocument(String id) =>
      _dio.delete('/dispatch-documents/$id');

  /// Resend dispatch document via WhatsApp
  Future<Response> resendDispatchDocument(String id, List<String> phones) =>
      _dio.post('/dispatch-documents/$id/resend', data: {'phones': phones});

  /// Check which packed orders have dispatch documents
  Future<Response> getDocumentsForOrders(List<String> orderIds) =>
      _dio.post('/dispatch-documents/for-orders', data: {'orderIds': orderIds});

  /// Server-side OCR using Google Cloud Vision API (fallback when on-device ML Kit fails)
  Future<Response> runServerOcr({
    required String imageBase64,
    List<String>? clientNames,
  }) =>
      _dio.post('/dispatch-documents/ocr', data: {
        'imageBase64': imageBase64,
        if (clientNames != null) 'clientNames': clientNames,
      });

  // ===== Transport Documents =====

  /// Create transport document: generate PDF, upload, send WhatsApp, store
  Future<Response> createTransportDocument({
    required String pdfBase64,
    required String transportName,
    required List<String> phones,
    required String caption,
    required int imageCount,
    required String date,
    required String createdBy,
    String companyName = 'SYGT',
  }) =>
      _dio.post('/transport-documents', data: {
        'pdfBase64': pdfBase64,
        'transportName': transportName,
        'phones': phones,
        'caption': caption,
        'imageCount': imageCount,
        'date': date,
        'createdBy': createdBy,
        'companyName': companyName,
      }, options: Options(sendTimeout: const Duration(seconds: 300), receiveTimeout: const Duration(seconds: 300)));

  /// List transport documents with optional filters
  Future<Response> getTransportDocuments({
    String? transportName,
    String? dateFrom,
    String? dateTo,
    int? limit,
  }) {
    final params = <String, dynamic>{};
    if (transportName != null) params['transportName'] = transportName;
    if (dateFrom != null) params['dateFrom'] = dateFrom;
    if (dateTo != null) params['dateTo'] = dateTo;
    if (limit != null) params['limit'] = limit;
    return _dio.get('/transport-documents', queryParameters: params);
  }

  /// Get single transport document
  Future<Response> getTransportDocument(String id) =>
      _dio.get('/transport-documents/$id');

  /// Delete transport document (soft delete)
  Future<Response> deleteTransportDocument(String id) =>
      _dio.delete('/transport-documents/$id');

  /// Resend transport document via WhatsApp
  Future<Response> resendTransportDocument(String id, List<String> phones) =>
      _dio.post('/transport-documents/$id/resend', data: {'phones': phones});

  // ── Sync (offline-first) ──────────────────────────────────────────
  /// Fetch incremental sync data with per-collection timestamps and role.
  Future<Response> sync({
    required String collections,
    Map<String, String?>? sinceMap,
    String? since,
    String? role,
  }) =>
      _dio.get('/sync', queryParameters: {
        'collections': collections,
        if (sinceMap != null) 'sinceMap': jsonEncode(sinceMap),
        if (since != null && sinceMap == null) 'since': since,
        if (role != null) 'role': role,
      });

  /// Lightweight check: get only the "As on" dates from outstanding sheets.
  Future<Response> checkOutstandingDates() =>
      _dio.get('/outstanding/check-date');

  // Outstanding Payments
  Future<Response> getOutstandingPayments({String company = 'all'}) =>
      _dio.get('/outstanding', queryParameters: {'company': company});

  Future<Response> saveOutstandingNameMapping({
    required String sheetName,
    required String company,
    required String firebaseClientName,
  }) =>
      _dio.put('/outstanding/name-mapping', data: {
        'sheetName': sheetName,
        'company': company,
        'firebaseClientName': firebaseClientName,
      });

  // Admin
  Future<Response> recalcAdmin() => _dio.post('/admin/recalc');

  Future<Response> rebuildAdmin() => _dio.post('/admin/rebuild');

  Future<Response> resetPointerAdmin() => _dio.post('/admin/reset-pointer');

  Future<Response> getPointer() => _dio.get('/admin/pointer');

  // Get current user role from stored preferences
  Future<String?> getUserRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('userRole');
  }


  // Auth
  Future<Response> login(String username, String password) {
    debugPrint('🔐 Attempting login for: $username');
    return _dio.post('/auth/login', data: {
      'username': username,
      'password': password,
    });
  }

  /// Face login — server verifies face match and returns JWT
  Future<Response> faceLogin(String username, Map<String, double> faceData) {
    debugPrint('🔐 Attempting face login for: $username');
    return _dio.post('/auth/face-login', data: {
      'username': username,
      'faceData': faceData,
    });
  }

  Future<Map<String, dynamic>> changePassword(String currentPassword, String newPassword) async {
    final response = await _dio.post('/auth/change-password', data: {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    });
    return response.data;
  }

  // Admin Settings
  Future<Response> getNotificationNumbers() =>
      _dio.get('/admin/settings/notification-numbers');

  Future<Response> updateNotificationNumbers(List<String> phones) =>
      _dio.put('/admin/settings/notification-numbers', data: {'phones': phones});

  // User Management
  Future<Response> getUsers() => _dio.get('/users');
  
  Future<Response> getUser(String id) => _dio.get('/users/$id');
  
  Future<Response> addUser(Map<String, dynamic> userData) => 
      _dio.post('/users', data: userData);
  
  Future<Response> updateUser(String id, Map<String, dynamic> userData) => 
      _dio.put('/users/$id', data: userData);
  
  Future<Response> deleteUser(String id) => _dio.delete('/users/$id');

  // Client Requests
  Future<Response> createClientRequest(Map<String, dynamic> requestData) => 
      _dio.post('/client-requests', data: requestData);

  Future<Response> getMyRequests() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'anonymous';
    return _dio.get('/client-requests/my', queryParameters: {
      'username': username
    });
  }
  
  Future<Response> getAllRequests([Map<String, dynamic>? filters]) => 
      _dio.get('/client-requests', queryParameters: filters);

  Future<Response> getRequest(String requestId) => 
      _dio.get('/client-requests/$requestId');

  Future<Response> getRequestDetails(String requestId) async {
    final results = await Future.wait([
      getRequest(requestId),
      getRequestChat(requestId)
    ]);
    
    final meta = results[0].data['request'];
    final messages = results[1].data['messages'];
    
    return Response(
      requestOptions: results[0].requestOptions,
      data: {'request': meta, 'messages': messages},
      statusCode: 200,
    );
  }

  Future<Response> cancelRequest(String requestId, String reason) => 
      _dio.post('/client-requests/$requestId/cancel', data: {'reason': reason});

  Future<Response> cancelRequestItem(String requestId, int index, String role, String reason) => 
      _dio.post('/client-requests/$requestId/cancel-item', data: {
        'index': index,
        'role': role,
        'reason': reason
      });

  Future<Response> getRequestChat(String requestId, [String? since]) {
    final params = <String, dynamic>{};
    if (since != null) params['since'] = since;
    return _dio.get('/client-requests/$requestId/chat', queryParameters: params);
  }

  Future<Response> sendChatMessage(String requestId, Map<String, dynamic> messageData) => 
      _dio.post('/client-requests/$requestId/chat', data: messageData);

  Future<Response> sendNegotiationMessage(String requestId, String text) async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'anonymous';
    final role = prefs.getString('userRole') ?? 'client';
    
    return sendChatMessage(requestId, {
      'message': text,
      'messageType': 'TEXT',
      'username': username,
      'role': role,
    });
  }

  Future<Response> saveAgreedItems(String requestId, List<dynamic> agreedItems) => 
      _dio.post('/client-requests/$requestId/agreed-items', data: {'agreedItems': agreedItems});

  Future<Response> convertRequestToOrder(String requestId, Map<String, dynamic> orderData) => 
      _dio.post('/client-requests/$requestId/convert-to-order', data: orderData);

  Future<Response> updateRequestStatus(String requestId, String status) => 
      _dio.post('/client-requests/$requestId/status', data: {'status': status});

  Future<Response> confirmRequest(String requestId) => 
      _dio.post('/client-requests/$requestId/confirm');

  // Client Request - Panel-based negotiation
  Future<Response> clientStartBargain(String requestId) => 
      _dio.post('/client-requests/$requestId/bargain');

  Future<Response> clientSaveDraft(String requestId, Map<String, dynamic> panelDraft) => 
      _dio.post('/client-requests/$requestId/draft', data: {'panelDraft': panelDraft});

  Future<Response> clientSendPanel(String requestId, Map<String, dynamic> panelSnapshot, [String? optionalText]) => 
      _dio.post('/client-requests/$requestId/send', data: {
        'panelSnapshot': panelSnapshot,
        'optionalText': optionalText
      });

  // Admin Request Routes
  Future<Response> adminGetAllRequests([Map<String, dynamic>? filters]) => 
      _dio.get('/admin/client-requests', queryParameters: filters);

  Future<Response> adminStartDraft(String requestId) => 
      _dio.post('/admin/client-requests/$requestId/start-draft');

  Future<Response> adminSaveDraft(String requestId, Map<String, dynamic> panelDraft) => 
      _dio.post('/admin/client-requests/$requestId/draft', data: {'panelDraft': panelDraft});

  Future<Response> adminSendPanel(String requestId, Map<String, dynamic> panelSnapshot, [String? optionalText]) => 
      _dio.post('/admin/client-requests/$requestId/send', data: {
        'panelSnapshot': panelSnapshot,
        'optionalText': optionalText
      });

  Future<Response> adminConfirmRequest(String requestId) =>
      _dio.post('/admin/client-requests/$requestId/confirm');

  Future<Response> reinitiateNegotiation(String requestId) =>
      _dio.post('/admin/client-requests/$requestId/reinitiate');

  Future<Response> adminCancelRequest(String requestId, String reason) => 
      _dio.post('/admin/client-requests/$requestId/cancel', data: {'reason': reason});

  Future<Response> adminConvertRequestToOrder(String requestId, Map<String, dynamic> orderData) => 
      _dio.post('/admin/client-requests/$requestId/convert-to-order', data: orderData);

  // Tasks
  Future<Response> getTasks({String? assigneeId}) => 
      _dio.get('/tasks', queryParameters: assigneeId != null ? {'assigneeId': assigneeId} : null);

  Future<Response> createTask(Map<String, dynamic> taskData) => 
      _dio.post('/tasks', data: taskData);

  Future<Response> updateTask(String taskId, Map<String, dynamic> taskData) => 
      _dio.put('/tasks/$taskId', data: taskData);

  Future<Response> deleteTask(String taskId) => 
      _dio.delete('/tasks/$taskId');

  Future<Response> getTaskStats() => _dio.get('/tasks/stats');

  // =============================================
  // APPROVAL REQUESTS API
  // =============================================

  /// Create a new approval request (for users requesting edit/delete)
  Future<Response> createApprovalRequest(Map<String, dynamic> requestData) =>
      _dio.post('/approval-requests', data: requestData);

  /// Get all pending approval requests (admin only)
  Future<Response> getPendingApprovalRequests() =>
      _dio.get('/approval-requests/pending');

  /// Get all approval requests (admin only)
  Future<Response> getAllApprovalRequests() =>
      _dio.get('/approval-requests');

  /// Get current user's approval requests
  Future<Response> getMyApprovalRequests(String userId, {bool includeDismissed = false}) =>
      _dio.get('/approval-requests/my/$userId',
        queryParameters: {'includeDismissed': includeDismissed.toString()});

  /// Get pending approval count (for badge)
  Future<Response> getApprovalRequestCount() =>
      _dio.get('/approval-requests/count');

  /// Approve a request (admin only)
  Future<Response> approveRequest(String requestId, String adminId, String adminName) =>
      _dio.put('/approval-requests/$requestId/approve', data: {
        'adminId': adminId,
        'adminName': adminName,
      });

  /// Reject a request (admin only)
  Future<Response> rejectRequest(String requestId, String adminId, String adminName, String reason, {String rejectionCategory = 'other'}) =>
      _dio.put('/approval-requests/$requestId/reject', data: {
        'adminId': adminId,
        'adminName': adminName,
        'reason': reason,
        'rejectionCategory': rejectionCategory,
      });

  /// Dismiss a resolved request (hide from user's view after reading)
  Future<Response> dismissRequest(String requestId) =>
      _dio.put('/approval-requests/$requestId/dismiss');

  // =============================================
  // WORKERS & ATTENDANCE API
  // =============================================

  /// Get all workers
  Future<Response> getWorkers({bool includeInactive = false}) =>
      _dio.get('/workers', queryParameters: {'includeInactive': includeInactive.toString()});

  /// Search workers with fuzzy matching
  Future<Response> searchWorkers(String query) =>
      _dio.get('/workers/search', queryParameters: {'q': query});

  /// Get worker teams
  Future<Response> getWorkerTeams() => _dio.get('/workers/teams');

  /// Add new worker (with duplicate check)
  Future<Response> addWorker(Map<String, dynamic> workerData) =>
      _dio.post('/workers', data: workerData);

  /// Force add worker (skip duplicate check)
  Future<Response> forceAddWorker(Map<String, dynamic> workerData) =>
      _dio.post('/workers/force', data: workerData);

  /// Update worker
  Future<Response> updateWorker(String workerId, Map<String, dynamic> updates) =>
      _dio.put('/workers/$workerId', data: updates);

  /// Delete worker (soft delete - marks as Inactive)
  Future<Response> deleteWorker(String workerIdOrName) =>
      _dio.delete('/workers/$workerIdOrName');

  /// Get attendance for a specific date
  Future<Response> getAttendance(String date) =>
      _dio.get('/attendance/$date');

  /// Get attendance summary for a date
  Future<Response> getAttendanceSummary(String date) =>
      _dio.get('/attendance/$date/summary');

  /// Mark attendance for a worker
  Future<Response> markAttendance(Map<String, dynamic> attendanceData) =>
      _dio.post('/attendance', data: attendanceData);

  /// Remove attendance record
  Future<Response> removeAttendance(String date, String workerId) =>
      _dio.delete('/attendance/$date/$workerId');

  /// Copy previous day's workers to today
  Future<Response> copyPreviousDayWorkers(String fromDate, String toDate, String markedBy) =>
      _dio.post('/attendance/copy-previous', data: {
        'fromDate': fromDate,
        'toDate': toDate,
        'markedBy': markedBy,
      });

  /// Get calendar data for a month
  Future<Response> getAttendanceCalendar(int year, int month) =>
      _dio.get('/attendance/calendar/$year/$month');

  // ========== EXPENSES API ==========
  
  /// Get expense sheet for a date
  Future<Response> getExpenseSheet(String date) =>
      _dio.get('/expenses/$date');
  
  /// Create or update expense sheet with items
  Future<Response> saveExpenseSheet(Map<String, dynamic> data) =>
      _dio.post('/expenses', data: data);
  
  /// Submit expense sheet for approval
  Future<Response> submitExpenseSheet(String sheetId, String submittedBy) =>
      _dio.post('/expenses/$sheetId/submit', data: {'submittedBy': submittedBy});
  
  /// Approve expense sheet (admin only)
  Future<Response> approveExpenseSheet(String sheetId, String approvedBy) =>
      _dio.post('/expenses/$sheetId/approve', data: {'approvedBy': approvedBy});
  
  /// Reject expense sheet with reason (admin only)
  Future<Response> rejectExpenseSheet(String sheetId, String rejectedBy, String reason) =>
      _dio.post('/expenses/$sheetId/reject', data: {
        'rejectedBy': rejectedBy,
        'reason': reason,
      });
  
  /// Get expense calendar for a month
  Future<Response> getExpenseCalendar(int year, int month) =>
      _dio.get('/expenses/calendar/$year/$month');
  
  /// Withdraw pending expense sheet (user cancels before admin review)
  Future<Response> withdrawExpenseSheet(String sheetId) =>
      _dio.post('/expenses/$sheetId/withdraw');
  
  /// Get all pending expense sheets for admin approval
  Future<Response> getPendingExpenses() =>
      _dio.get('/expenses/pending/all');

  // ========== Gate Passes ==========
  
  /// Get all gate passes with optional filters
  Future<Response> getGatePasses({String? status, String? type, String? requestedBy}) {
    final params = <String, dynamic>{};
    if (status != null) params['status'] = status;
    if (type != null) params['type'] = type;
    if (requestedBy != null) params['requestedBy'] = requestedBy;
    return _dio.get('/gate-passes', queryParameters: params);
  }
  
  /// Get pending gate passes for admin
  Future<Response> getPendingGatePasses() => _dio.get('/gate-passes/pending');
  
  /// Get single gate pass by ID
  Future<Response> getGatePass(String id) => _dio.get('/gate-passes/$id');
  
  /// Create new gate pass
  Future<Response> createGatePass(Map<String, dynamic> data) =>
      _dio.post('/gate-passes', data: data);
  
  /// Update gate pass (before approval only)
  Future<Response> updateGatePass(String id, Map<String, dynamic> data) =>
      _dio.put('/gate-passes/$id', data: data);
  
  /// Approve gate pass (confirmation-based, no signature required)
  Future<Response> approveGatePass(String id) =>
      _dio.post('/gate-passes/$id/approve', data: {});
  
  /// Reject gate pass with reason
  Future<Response> rejectGatePass(String id, String reason) =>
      _dio.post('/gate-passes/$id/reject', data: {'reason': reason});
  
  /// Record entry time
  Future<Response> recordGatePassEntry(String id) =>
      _dio.post('/gate-passes/$id/record-entry');
  
  /// Record exit time
  Future<Response> recordGatePassExit(String id) =>
      _dio.post('/gate-passes/$id/record-exit');
  
  /// Mark gate pass as completed
  Future<Response> completeGatePass(String id) =>
      _dio.post('/gate-passes/$id/complete');

  // ========== AI Brain ==========

  Future<Response> getAiDailyBriefing() => _dio.get('/ai/daily-briefing');

  Future<Response> getAiGradeAnalysis(String grade) =>
      _dio.get('/ai/grade-analysis/${Uri.encodeComponent(grade)}');

  Future<Response> getAiClientAnalysis(String clientName) =>
      _dio.get('/ai/client-analysis/${Uri.encodeComponent(clientName)}');

  Future<Response> getAiRecommendations() => _dio.get('/ai/recommendations');

  // ========== Rejected Offers Analytics ==========

  /// Get rejected offers analytics (aggregated gaps by client/grade)
  Future<Map<String, dynamic>> getRejectedOffersAnalytics(Map<String, dynamic> filters) async {
    final response = await _dio.get('/analytics/rejected-offers/summary', queryParameters: filters);
    final data = response.data;
    if (data is Map && data['success'] == false) {
      throw Exception(data['error'] ?? 'Failed to fetch rejected offers analytics');
    }
    return Map<String, dynamic>.from(data ?? {});
  }

  /// Get list of rejected offers with details
  Future<List<dynamic>> getRejectedOffersList(Map<String, dynamic> filters) async {
    final response = await _dio.get('/client-requests/rejected-offers', queryParameters: filters);
    final data = response.data;
    if (data is Map && data['success'] == false) {
      throw Exception(data['error'] ?? 'Failed to fetch rejected offers list');
    }
    return data is List ? data : [];
  }

  // ========== Face Attendance ==========

  /// Get all enrolled face data for roll call matching
  Future<Response> getAllFaceData() =>
      _dio.get('/workers/face-data');

  /// Store face landmark data for a worker (enrollment)
  Future<Response> storeFaceData(String workerId, Map<String, double> landmarks) =>
      _dio.post('/workers/$workerId/face-data', data: {'faceData': landmarks});

  /// Mark attendance via face scan
  Future<Response> markAttendanceByFace(String workerId, String workerName) =>
      _dio.post('/attendance/face-mark', data: {
        'workerId': workerId,
        'workerName': workerName,
        'date': DateTime.now().toIso8601String().split('T')[0],
        'status': 'present',
        'markedBy': 'face_scan',
      });

  // ========== User Face Login ==========

  /// Get all user face data (PUBLIC - no auth required, for face login matching)
  Future<Response> getAllUserFaceData() =>
      _dio.get('/users/face-data/all');

  /// Store face data for current logged-in user
  Future<Response> storeUserFaceData(Map<String, double> landmarks) =>
      _dio.post('/users/me/face-data', data: {'faceData': landmarks});

  /// Get face data for current logged-in user
  Future<Response> getUserFaceData() =>
      _dio.get('/users/me/face-data');

  /// Store face data for a specific user (admin only)
  Future<Response> storeUserFaceDataById(String userId, Map<String, double> landmarks) =>
      _dio.post('/users/$userId/face-data', data: {'faceData': landmarks});

  /// Get face data for a specific user (admin only)
  Future<Response> getUserFaceDataById(String userId) =>
      _dio.get('/users/$userId/face-data');

  /// Delete face data for current logged-in user
  Future<Response> deleteMyFaceData() =>
      _dio.delete('/users/me/face-data');

  /// Delete face data for a specific user (admin only)
  Future<Response> deleteUserFaceDataById(String userId) =>
      _dio.delete('/users/$userId/face-data');

  /// Delete face data for a worker (admin only)
  Future<Response> deleteWorkerFaceData(String workerId) =>
      _dio.delete('/workers/$workerId/face-data');

  // ========== FCM Token Management (no-op on ICP) ==========

  /// Register FCM token — no-op on ICP (kept for API compatibility)
  Future<Response> registerFcmToken(String token) =>
      _dio.post('/users/fcm-token', data: {'token': token});

  /// Remove FCM token — no-op on ICP (kept for API compatibility)
  Future<Response> removeFcmToken(String token) =>
      _dio.delete('/users/fcm-token', data: {'token': token});

  // ── Persisted Notifications (SQLite on ICP) ──────────────────────────
  /// Fetch unread notifications
  Future<Response> getNotifications() => _dio.get('/notifications');

  /// Mark all notifications as read
  Future<Response> markAllNotificationsRead() =>
      _dio.post('/notifications/mark-read');

  // ========== JWT Token Management ==========

  /// Set JWT authentication token (called after successful login)
  Future<void> setAuthToken(String token) async {
    _authToken = token;
    // Persist to SharedPreferences for app restarts
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    debugPrint('🔐 Auth token stored');
  }

  /// Clear JWT authentication token (called on logout)
  Future<void> clearAuthToken() async {
    _authToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    debugPrint('🔓 Auth token cleared');
  }

  /// Get current auth token (if any)
  String? getAuthToken() => _authToken;

  /// Force-reload token from SharedPreferences into memory.
  /// Called when app resumes from background (e.g. after camera) where
  /// iOS may have killed the process and _authToken is null.
  Future<void> reloadTokenFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('auth_token');
    if (stored != null && stored.isNotEmpty && stored != _authToken) {
      _authToken = stored;
      debugPrint('🔄 Auth token reloaded from storage');
    }
  }

  // =============================================
  // PAGINATED API METHODS
  // =============================================

  /// Get paginated orders with cursor-based pagination.
  Future<Response> getOrdersPaginated({int limit = 25, String? cursor}) {
    final params = <String, dynamic>{'limit': limit};
    if (cursor != null) params['cursor'] = cursor;
    return _dio.get('/orders', queryParameters: params);
  }

  /// Get paginated tasks with cursor-based pagination.
  Future<Response> getTasksPaginated({int limit = 25, String? cursor, String? assigneeId}) {
    final params = <String, dynamic>{'limit': limit};
    if (cursor != null) params['cursor'] = cursor;
    if (assigneeId != null) params['assigneeId'] = assigneeId;
    return _dio.get('/tasks', queryParameters: params);
  }

  /// Get paginated approval requests with cursor-based pagination.
  Future<Response> getAllApprovalRequestsPaginated({int limit = 25, String? cursor}) {
    final params = <String, dynamic>{'limit': limit};
    if (cursor != null) params['cursor'] = cursor;
    return _dio.get('/approval-requests', queryParameters: params);
  }

  /// Get paginated user approval requests.
  Future<Response> getMyApprovalRequestsPaginated(String userId, {int limit = 25, String? cursor, bool includeDismissed = false}) {
    final params = <String, dynamic>{
      'limit': limit,
      'includeDismissed': includeDismissed.toString(),
    };
    if (cursor != null) params['cursor'] = cursor;
    return _dio.get('/approval-requests/my/$userId', queryParameters: params);
  }

  /// Get paginated client requests (admin).
  Future<Response> getAllRequestsPaginated({int limit = 25, String? cursor, Map<String, dynamic>? filters}) {
    final params = <String, dynamic>{'limit': limit};
    if (cursor != null) params['cursor'] = cursor;
    if (filters != null) params.addAll(filters);
    return _dio.get('/client-requests', queryParameters: params);
  }

  /// Get paginated client's own requests.
  Future<Response> getMyRequestsPaginated({int limit = 25, String? cursor}) async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'anonymous';
    final params = <String, dynamic>{
      'username': username,
      'limit': limit,
    };
    if (cursor != null) params['cursor'] = cursor;
    return _dio.get('/client-requests/my', queryParameters: params);
  }

  /// Get paginated gate passes.
  Future<Response> getGatePassesPaginated({int limit = 25, String? cursor, String? status, String? type, String? requestedBy}) {
    final params = <String, dynamic>{'limit': limit};
    if (cursor != null) params['cursor'] = cursor;
    if (status != null) params['status'] = status;
    if (type != null) params['type'] = type;
    if (requestedBy != null) params['requestedBy'] = requestedBy;
    return _dio.get('/gate-passes', queryParameters: params);
  }

  // =============================================
  // REJECTED OFFERS ANALYTICS
  // =============================================
  
  /// Get rejected offers with optional filters
  Future<Response> getRejectedOffers({String? clientId, String? grade, String? dateFrom, String? dateTo, int? limit}) {
    final params = <String, dynamic>{};
    if (clientId != null) params['clientId'] = clientId;
    if (grade != null) params['grade'] = grade;
    if (dateFrom != null) params['dateFrom'] = dateFrom;
    if (dateTo != null) params['dateTo'] = dateTo;
    if (limit != null) params['limit'] = limit;
    return _dio.get('/analytics/rejected-offers', queryParameters: params);
  }
  
  /// Get aggregated rejected offers summary
  Future<Response> getRejectedOffersSummary({String? dateFrom, String? dateTo}) {
    final params = <String, dynamic>{};
    if (dateFrom != null) params['dateFrom'] = dateFrom;
    if (dateTo != null) params['dateTo'] = dateTo;
    return _dio.get('/analytics/rejected-offers/summary', queryParameters: params);
  }

  // =============================================
  // INTELLIGENT ORDER FLAGGING
  // =============================================
  
  /// Get similar previous orders for comparison (for flagging)
  Future<Response> getSimilarOrders(String client, String grade, {int limit = 5}) =>
      _dio.get('/orders/similar', queryParameters: {
        'client': client,
        'grade': grade,
        'limit': limit
      });
  
  /// Check for price/qty drift against recent orders
  Future<Response> checkOrderDrift(Map<String, dynamic> orderData) =>
      _dio.post('/orders/check-drift', data: orderData);

  /// L1433: Log access restriction event to notify admins
  Future<Response> logAccessRestriction({
    required String userId,
    required String userName,
    required String userRole,
    required String pageKey,
  }) => _dio.post('/access-restriction-log', data: {
    'userId': userId,
    'userName': userName,
    'userRole': userRole,
    'pageKey': pageKey,
    'timestamp': DateTime.now().toIso8601String(),
  });

  // ── WhatsApp Send Logs ──
  Future<List<dynamic>> getWhatsappLogs({String? channel, String? type, String? status, int limit = 100}) async {
    final params = <String, dynamic>{'limit': limit};
    if (channel != null) params['channel'] = channel;
    if (type != null) params['type'] = type;
    if (status != null) params['status'] = status;
    final res = await _dio.get('/whatsapp-logs', queryParameters: params);
    return res.data is List ? res.data : [];
  }

  Future<Map<String, dynamic>> getWhatsappLogStats() async {
    final res = await _dio.get('/whatsapp-logs/stats');
    return res.data is Map ? Map<String, dynamic>.from(res.data) : {};
  }

  // ── Packed Boxes ──
  Future<Response> getPackedBoxesToday(String date) =>
      _dio.get('/packed-boxes/today', queryParameters: {'date': date});

  Future<Response> addPackedBoxes(Map<String, dynamic> data) =>
      _dio.post('/packed-boxes/add', data: data);

  Future<Response> updateBilledBoxes(Map<String, dynamic> data) =>
      _dio.put('/packed-boxes/bill', data: data);

  Future<Response> getRemainingBoxes() =>
      _dio.get('/packed-boxes/remaining');

  Future<Response> getPackedBoxHistory(String date) =>
      _dio.get('/packed-boxes/history', queryParameters: {'date': date});

  Future<Response> deletePackedBoxEntry(String id) =>
      _dio.delete('/packed-boxes/$id');
}
