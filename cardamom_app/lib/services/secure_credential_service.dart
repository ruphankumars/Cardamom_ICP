import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service for securely storing and retrieving user credentials
/// using iOS Keychain / Android EncryptedSharedPreferences.
/// Used for face-login: after a regular login, credentials are stored
/// so that face recognition can retrieve them and re-authenticate.
class SecureCredentialService {
  static final SecureCredentialService _instance = SecureCredentialService._();
  static SecureCredentialService get instance => _instance;

  SecureCredentialService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _keyUsername = 'face_login_username';
  static const _keyPassword = 'face_login_password';

  /// Store credentials after a successful regular login
  Future<void> storeCredentials(String username, String password) async {
    try {
      await _storage.write(key: _keyUsername, value: username);
      await _storage.write(key: _keyPassword, value: password);
      debugPrint('[SecureCredentials] Credentials stored for $username');
    } catch (e) {
      debugPrint('[SecureCredentials] Error storing credentials: $e');
    }
  }

  /// Retrieve stored credentials for face login
  Future<({String username, String password})?> getCredentials() async {
    try {
      final username = await _storage.read(key: _keyUsername);
      final password = await _storage.read(key: _keyPassword);
      if (username != null && password != null) {
        return (username: username, password: password);
      }
      return null;
    } catch (e) {
      debugPrint('[SecureCredentials] Error reading credentials: $e');
      return null;
    }
  }

  /// Check if stored credentials exist (face login available)
  Future<bool> hasStoredCredentials() async {
    try {
      final username = await _storage.read(key: _keyUsername);
      return username != null;
    } catch (e) {
      return false;
    }
  }

  /// Clear credentials on logout
  Future<void> clearCredentials() async {
    try {
      await _storage.delete(key: _keyUsername);
      await _storage.delete(key: _keyPassword);
      debugPrint('[SecureCredentials] Credentials cleared');
    } catch (e) {
      debugPrint('[SecureCredentials] Error clearing credentials: $e');
    }
  }
}
