import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

/// Service for downloading and sharing generated reports.
///
/// Uses the existing ApiService base URL and JWT authentication.
/// Reports are downloaded as binary streams, saved to temp directory,
/// and shared via the native share sheet.
class ReportService {
  late final Dio _dio;

  ReportService() {
    _dio = Dio();
    _dio.options.connectTimeout = const Duration(seconds: 60);
    _dio.options.receiveTimeout = const Duration(seconds: 60);
  }

  /// Load auth token from SharedPreferences
  Future<String?> _getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  /// Download a report from the backend
  ///
  /// Returns the local file path on success.
  /// [reportType] is the endpoint name (e.g., 'invoice', 'dispatch-summary')
  /// [params] is the request body with filters and format
  /// [filename] is the desired filename for the downloaded file
  Future<String> downloadReport({
    required String reportType,
    required Map<String, dynamic> params,
    required String filename,
  }) async {
    final token = await _getToken();
    if (token == null) {
      throw Exception('Not authenticated. Please log in again.');
    }

    try {
      final response = await _dio.post(
        '${ApiService.baseUrl}/reports/$reportType',
        data: params,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to generate report: HTTP ${response.statusCode}');
      }

      final bytes = response.data as List<int>;

      if (kIsWeb) {
        // On web, we cannot easily save files. Return a placeholder path.
        // The caller should handle web download differently if needed.
        return filename;
      }

      // Save to temp directory
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/$filename';
      final file = File(filePath);
      await file.writeAsBytes(Uint8List.fromList(bytes));
      return filePath;
    } on DioException catch (e) {
      if (e.response != null && e.response!.statusCode == 504) {
        throw Exception('Report generation timed out. Try a smaller date range.');
      }
      if (e.response != null && e.response!.statusCode == 503) {
        throw Exception('Server busy generating reports. Please try again in a moment.');
      }
      // Try to parse error message from response body
      if (e.response != null && e.response!.data != null) {
        try {
          final data = e.response!.data;
          if (data is Map && data['error'] != null) {
            throw Exception(data['error']);
          }
          // If response is bytes (binary), try to decode
          if (data is List<int>) {
            final body = String.fromCharCodes(data);
            if (body.contains('"error"')) {
              // Simple JSON extraction
              final match = RegExp(r'"error"\s*:\s*"([^"]+)"').firstMatch(body);
              if (match != null) {
                throw Exception(match.group(1));
              }
            }
          }
        } catch (parseError) {
          if (parseError is Exception) rethrow;
        }
      }
      throw Exception('Network error: ${e.message}');
    }
  }

  /// Share a downloaded report file via the native share sheet
  Future<void> shareReport(String filePath, String filename) async {
    if (kIsWeb) return;

    final xFile = XFile(filePath);
    await Share.shareXFiles(
      [xFile],
      subject: filename,
      text: 'Report from Emperor Spices - $filename',
    );
  }

  /// Get the file extension for a format
  static String extensionForFormat(String format) {
    switch (format) {
      case 'excel':
        return 'xlsx';
      case 'zip':
        return 'zip';
      case 'pdf':
      default:
        return 'pdf';
    }
  }
}
