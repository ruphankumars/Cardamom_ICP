import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Native WhatsApp sharing via UIDocumentInteractionController on iOS.
/// Opens WhatsApp directly (no generic iOS share sheet).
class WhatsAppService {
  static const _channel = MethodChannel('com.sygt.cardamom/whatsapp');

  /// Share an image file directly to WhatsApp.
  /// Returns true if WhatsApp opened, false if not installed.
  static Future<bool> shareImage(String filePath) async {
    try {
      final result = await _channel.invokeMethod<bool>('shareToWhatsApp', {
        'filePath': filePath,
      });
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Open WhatsApp chat with a specific phone number and pre-filled message.
  /// Works immediately — no template approval needed.
  /// [phone] should be digits only with country code (e.g. "919940715653")
  static Future<bool> openChat({
    required String phone,
    String? message,
  }) async {
    // Clean phone: remove +, spaces, dashes
    final cleanPhone = phone.replaceAll(RegExp(r'[^\d]'), '');
    final encoded = message != null ? Uri.encodeComponent(message) : '';
    final url = Uri.parse('https://wa.me/$cleanPhone${encoded.isNotEmpty ? '?text=$encoded' : ''}');

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }
}
