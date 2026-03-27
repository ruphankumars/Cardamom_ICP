import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import '../services/api_service.dart';
import '../services/analytics_service.dart';
import '../services/push_notification_service.dart';
import '../services/secure_credential_service.dart';

class AuthProvider extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  bool _isLoggedIn = false;
  bool _isLoading = true;
  String? _username;
  String? _role;
  String? _clientName;
  String? _userId;
  Map<String, dynamic>? _pageAccess;
  bool _mustChangePassword = false;

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get username => _username;
  String? get role => _role;
  String? get clientName => _clientName;
  String? get userId => _userId;
  Map<String, dynamic>? get pageAccess => _pageAccess;
  bool get mustChangePassword => _mustChangePassword;

  AuthProvider() {
    _loadSession();
  }

  Future<void> _loadSession() async {
    _isLoading = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
      _username = prefs.getString('username');
      _role = prefs.getString('userRole');
      _clientName = prefs.getString('clientName');
      _userId = prefs.getString('userId');

      // Load pageAccess from JSON string
      final pageAccessJson = prefs.getString('pageAccess');
      if (pageAccessJson != null && pageAccessJson.isNotEmpty) {
        try {
          _pageAccess = jsonDecode(pageAccessJson) as Map<String, dynamic>;
        } catch (e) {
          debugPrint('Error parsing pageAccess: $e');
          _pageAccess = null;
        }
      }
      _isLoading = false;
      notifyListeners();

      // If already logged in, register FCM token (e.g., after app restart)
      if (_isLoggedIn) {
        PushNotificationService.instance.registerToken().catchError((e) {
          debugPrint('⚠️ FCM token registration on session load failed: $e');
        });
      }
    } catch (e) {
      debugPrint('⚠️ Error loading session: $e');
      // Reset to safe defaults on error
      _isLoggedIn = false;
      _username = null;
      _role = null;
      _clientName = null;
      _userId = null;
      _pageAccess = null;
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Clear in-memory session state (called when token expires in interceptor)
  void clearSession() {
    _isLoggedIn = false;
    _username = null;
    _role = null;
    _clientName = null;
    _userId = null;
    _pageAccess = null;
    _isLoading = false;
    notifyListeners();
  }

  String? _lastError;

  String? get lastError => _lastError;

  Future<bool> login(String username, String password) async {
    _lastError = null;
    try {
      final response = await _apiService.login(username, password);
      
      // Check response status
      if (response.statusCode == 200) {
        final data = response.data;
        
        // Check if login was successful
        if (data != null && data['success'] == true) {
          final userData = data['user'];
          final token = data['token'];  // JWT token from backend
          final prefs = await SharedPreferences.getInstance();

          // Store JWT token for authentication
          if (token != null) {
            await _apiService.setAuthToken(token);
            debugPrint('🔐 [AuthProvider] JWT token stored');
          } else {
            debugPrint('⚠️ [AuthProvider] No JWT token in response - using old auth');
          }

          await prefs.setBool('isLoggedIn', true);
          await prefs.setString('username', username);
          
          // Safely get role with null handling - normalize to lowercase
          String role = 'employee';
          if (userData is Map) {
            role = (userData['role']?.toString() ?? 'employee').toLowerCase().trim();
          } else if (data['role'] != null) {
            role = data['role'].toString().toLowerCase().trim();
          }
          debugPrint('🔐 [AuthProvider] Login role: "$role"');
          await prefs.setString('userRole', role);
          
          // Safely get clientName
          String? clientName;
          if (userData is Map && userData['clientName'] != null) {
            clientName = userData['clientName'].toString();
            if (clientName.isNotEmpty) {
              await prefs.setString('clientName', clientName);
            }
          }

          // Safely get userId
          String? userId;
          if (userData is Map && userData['id'] != null) {
            userId = userData['id'].toString();
            await prefs.setString('userId', userId);
          }

          // Safely get pageAccess
          Map<String, dynamic>? pageAccess;
          if (userData is Map && userData['pageAccess'] != null) {
            pageAccess = Map<String, dynamic>.from(userData['pageAccess']);
            await prefs.setString('pageAccess', jsonEncode(pageAccess));
          }

          // Check mustChangePassword flag
          _mustChangePassword = data['mustChangePassword'] == true;

          _isLoggedIn = true;
          _username = username;
          _role = role;
          _clientName = clientName;
          _userId = userId;
          _pageAccess = pageAccess;

          notifyListeners();

          // Register FCM token for push notifications (fire-and-forget)
          PushNotificationService.instance.registerToken().catchError((e) {
            debugPrint('⚠️ FCM token registration failed: $e');
          });

          // Store credentials securely for face login (fire-and-forget)
          SecureCredentialService.instance
              .storeCredentials(username, password)
              .catchError((e) {
            debugPrint('⚠️ Secure credential storage failed: $e');
          });

          return true;
        } else {
          // Login failed - get error message
          final errorMsg = data?['error']?.toString() ?? 
                         data?['message']?.toString() ?? 
                         'Invalid username or password';
          _lastError = errorMsg;
          debugPrint('Login failed: $_lastError');
          debugPrint('Response data: $data');
          notifyListeners();
          return false;
        }
      } else {
        // Non-200 status code
        final errorMsg = response.data?['error']?.toString() ?? 
                        response.data?['message']?.toString() ?? 
                        'Login failed. Please try again.';
        _lastError = errorMsg;
        debugPrint('Login error (status ${response.statusCode}): $_lastError');
        debugPrint('Response data: ${response.data}');
        notifyListeners();
        return false;
      }
    } on DioException catch (e) {
      // Handle Dio errors (network, timeout, etc.)
      if (e.response != null) {
        final errorData = e.response?.data;
        _lastError = errorData?['error']?.toString() ?? 
                    errorData?['message']?.toString() ?? 
                    'Invalid username or password';
      } else {
        _lastError = e.message?.toString() ?? 'Failed to connect to server. Please check your connection.';
      }
      debugPrint('Login DioException: $_lastError');
      debugPrint('Error type: ${e.type}');
      debugPrint('Error message: ${e.message}');
      debugPrint('Error response: ${e.response?.data}');
      notifyListeners();
      return false;
    } catch (e, stackTrace) {
      _lastError = 'An unexpected error occurred: ${e.toString()}';
      debugPrint('Login error: $e');
      debugPrint('Stack trace: $stackTrace');
      notifyListeners();
      return false;
    }
  }

  void clearMustChangePassword() {
    _mustChangePassword = false;
    notifyListeners();
  }

  Future<void> logout() async {
    // Unregister FCM token before clearing auth
    try {
      await PushNotificationService.instance.unregisterToken();
    } catch (e) {
      debugPrint('⚠️ FCM token unregister failed: $e');
    }

    // Clear JWT token
    await _apiService.clearAuthToken();

    // Clear secure credentials (face login)
    await SecureCredentialService.instance.clearCredentials();

    final prefs = await SharedPreferences.getInstance();
    // Only remove auth-related keys, preserve offline caches
    for (final key in ['isLoggedIn', 'username', 'userRole', 'clientName', 'userId', 'pageAccess', 'auth_token']) {
      await prefs.remove(key);
    }
    // #76: Clear static caches to prevent stale data across sessions
    AnalyticsService.clearCache();

    _isLoggedIn = false;
    _username = null;
    _role = null;
    _clientName = null;
    _userId = null;
    _pageAccess = null;
    _mustChangePassword = false;
    notifyListeners();

    debugPrint('🔓 [AuthProvider] User logged out, token + caches cleared');
  }

  // ========== Face Login ==========

  /// Attempt face-based login via server-verified face match.
  /// The matched username is resolved client-side, then the server
  /// re-verifies the face data and issues a JWT token.
  Future<bool> loginWithFace(Map<String, double> landmarks,
      {String? matchedUsername}) async {
    _lastError = null;
    try {
      String username;

      if (matchedUsername != null && matchedUsername.isNotEmpty) {
        username = matchedUsername;
      } else {
        // Fallback: resolve username via local matching
        final response = await _apiService.getAllUserFaceData();
        final List<dynamic> enrolledUsers =
            response.data is List ? response.data : [];

        if (enrolledUsers.isEmpty) {
          _lastError = 'No users have enrolled their face yet';
          notifyListeners();
          return false;
        }

        final match = _findBestUserMatch(landmarks, enrolledUsers);
        if (match == null) {
          _lastError = 'Face not recognized. Please use password login.';
          notifyListeners();
          return false;
        }
        username = match['username'] as String;
      }

      debugPrint('👤 [FaceLogin] Sending face-login for user: $username');

      // Server-side verification — re-matches face data and returns JWT
      final response = await _apiService.faceLogin(username, landmarks);

      if (response.statusCode == 200) {
        final data = response.data;
        if (data != null && data['success'] == true) {
          final userData = data['user'];
          final token = data['token'];
          final prefs = await SharedPreferences.getInstance();

          // Store JWT token
          if (token != null) {
            await _apiService.setAuthToken(token);
            debugPrint('🔐 [FaceLogin] JWT token stored');
          }

          await prefs.setBool('isLoggedIn', true);
          await prefs.setString('username', username);

          String role = 'employee';
          if (userData is Map) {
            role = (userData['role']?.toString() ?? 'employee')
                .toLowerCase()
                .trim();
          } else if (data['role'] != null) {
            role = data['role'].toString().toLowerCase().trim();
          }
          await prefs.setString('userRole', role);

          String? clientName;
          if (userData is Map && userData['clientName'] != null) {
            clientName = userData['clientName'].toString();
            if (clientName.isNotEmpty) {
              await prefs.setString('clientName', clientName);
            }
          }

          String? userId;
          if (userData is Map && userData['id'] != null) {
            userId = userData['id'].toString();
            await prefs.setString('userId', userId);
          }

          Map<String, dynamic>? pageAccess;
          if (userData is Map && userData['pageAccess'] != null) {
            pageAccess = Map<String, dynamic>.from(userData['pageAccess']);
            await prefs.setString('pageAccess', jsonEncode(pageAccess));
          }

          _mustChangePassword = data['mustChangePassword'] == true;
          _isLoggedIn = true;
          _username = username;
          _role = role;
          _clientName = clientName;
          _userId = userId;
          _pageAccess = pageAccess;

          notifyListeners();

          PushNotificationService.instance.registerToken().catchError((e) {
            debugPrint('⚠️ FCM token registration failed: $e');
          });

          return true;
        } else {
          _lastError = data?['error']?.toString() ?? 'Face login failed';
          notifyListeners();
          return false;
        }
      } else {
        _lastError = 'Face login failed (${response.statusCode})';
        notifyListeners();
        return false;
      }
    } on DioException catch (e) {
      final errData = e.response?.data;
      _lastError = (errData is Map ? errData['error']?.toString() : null) ??
          e.message ??
          'Network error during face login';
      debugPrint('[FaceLogin] DioError: $_lastError');
      notifyListeners();
      return false;
    } catch (e) {
      _lastError = 'Face login error: $e';
      debugPrint('[FaceLogin] Error: $e');
      notifyListeners();
      return false;
    }
  }

  /// Find best matching user from enrolled face data using Mean Relative Error
  Map<String, dynamic>? _findBestUserMatch(
      Map<String, double> landmarks, List<dynamic> enrolledUsers) {
    double bestScore = 0;
    Map<String, dynamic>? bestMatch;

    final isMeshScan = landmarks.containsKey('leftEyeWidth');

    for (final enrolled in enrolledUsers) {
      final storedData = enrolled['faceData'];
      if (storedData == null || storedData is! Map) continue;

      final storedLandmarks = Map<String, double>.from(
        storedData.map((k, v) => MapEntry(k.toString(), (v as num).toDouble())),
      );
      if (storedLandmarks.isEmpty) continue;

      final isStoredMesh = storedLandmarks.containsKey('leftEyeWidth');

      List<String> compareKeys;
      double threshold;

      if (isMeshScan && isStoredMesh) {
        compareKeys = [
          'leftEyeWidth', 'rightEyeWidth', 'leftEyeHeight', 'rightEyeHeight',
          'leftBrowWidth', 'rightBrowWidth', 'leftBrowToEye', 'rightBrowToEye',
          'noseLength', 'noseWidth', 'noseTipToLeftEye', 'noseTipToRightEye',
          'mouthWidth', 'mouthHeight', 'noseToMouth',
          'faceWidth', 'faceHeight', 'chinToMouth', 'foreheadToNose', 'foreheadToBrow',
          'eyeWidthRatio', 'browWidthRatio', 'noseToFaceWidth', 'mouthToFaceWidth',
        ];
        threshold = 0.95;
      } else {
        compareKeys = ['noseTipToLeftEye', 'noseTipToRightEye', 'mouthWidth', 'noseToMouth', 'faceWidth', 'mouthToFaceWidth'];
        threshold = 0.90;
      }

      // Mean Relative Error — measures actual geometric differences.
      // Cosine similarity returns ~0.99 for ALL faces on positive vectors,
      // making it useless. MRE yields ~0.93-0.97 for same person and
      // ~0.75-0.85 for different people, making thresholds effective.
      double totalRelErr = 0;
      int matched = 0;
      for (final key in compareKeys) {
        final a = landmarks[key];
        final b = storedLandmarks[key];
        if (a == null || b == null || a == 0 || b == 0) continue;
        final mean = (a + b) / 2.0;
        if (mean > 0) {
          totalRelErr += (a - b).abs() / mean;
          matched++;
        }
      }

      final minKeys = (isMeshScan && isStoredMesh) ? 8 : 3;
      if (matched < minKeys) continue;

      final similarity = 1.0 - (totalRelErr / matched);

      if (similarity > bestScore && similarity >= threshold) {
        bestScore = similarity;
        bestMatch = {
          'userId': enrolled['userId'],
          'username': enrolled['username'],
          'role': enrolled['role'],
          'fullName': enrolled['fullName'],
          'matchScore': similarity,
          'matchPercent': '${(similarity * 100).toStringAsFixed(1)}%',
        };
      }
    }

    return bestMatch;
  }

  /// Enroll face for the current logged-in user
  Future<bool> enrollFaceForCurrentUser(Map<String, double> landmarks) async {
    try {
      final response = await _apiService.storeUserFaceData(landmarks);
      final data = response.data;
      if (data is Map && data['success'] == true) {
        debugPrint('✅ [AuthProvider] Face enrolled for user $_username');
        return true;
      }
      debugPrint('❌ [AuthProvider] Face enrollment failed: $data');
      return false;
    } catch (e) {
      debugPrint('❌ [AuthProvider] Face enrollment error: $e');
      return false;
    }
  }
}
