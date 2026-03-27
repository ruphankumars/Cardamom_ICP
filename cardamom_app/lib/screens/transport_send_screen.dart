import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../theme/app_theme.dart';

/// Compress image in isolate — same pattern as dispatch_documents_screen.
Uint8List _compressForPdf(Uint8List rawBytes) {
  var decoded = img.decodeImage(rawBytes);
  if (decoded == null) throw Exception('Failed to decode image');
  decoded = img.bakeOrientation(decoded);
  // Max 1600px wide, JPEG quality 75% — fast upload, still readable
  final resized = decoded.width > 1600
      ? img.copyResize(decoded, width: 1600, interpolation: img.Interpolation.cubic)
      : decoded;
  return Uint8List.fromList(img.encodeJpg(resized, quality: 75));
}

/// Screen to capture multiple images, generate PDF, and send to a transport.
class TransportSendScreen extends StatefulWidget {
  const TransportSendScreen({super.key});

  @override
  State<TransportSendScreen> createState() => _TransportSendScreenState();
}

class _TransportSendScreenState extends State<TransportSendScreen>
    with WidgetsBindingObserver {
  final ApiService _apiService = ApiService();
  final TextEditingController _captionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  String _transportName = '';
  List<String> _phones = [];
  String _billingFrom = 'SYGT';
  bool _argsLoaded = false;

  /// Captured images: each is compressed JPEG bytes
  final List<Uint8List> _capturedImages = [];
  bool _isSending = false;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsLoaded) return;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic>) {
      _transportName = args['transportName']?.toString() ?? '';
      _phones = (args['phones'] as List?)?.map((e) => e.toString()).toList() ?? [];
      _argsLoaded = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _captionController.dispose();
    super.dispose();
  }

  /// Reload auth token when app resumes from camera — iOS may kill the
  /// process and _authToken is lost in memory.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _apiService.reloadTokenFromStorage();
    }
  }

  // ── Image capture ──

  Future<void> _captureImage({bool fromGallery = false}) async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final XFile? file;
      if (fromGallery) {
        final files = await _picker.pickMultiImage(imageQuality: 100);
        for (final f in files) {
          final raw = await f.readAsBytes();
          final compressed = await compute(_compressForPdf, raw);
          if (mounted) setState(() => _capturedImages.add(compressed));
        }
        setState(() => _isCapturing = false);
        return;
      } else {
        file = await _picker.pickImage(source: ImageSource.camera, imageQuality: 100);
      }
      if (file == null) {
        setState(() => _isCapturing = false);
        return;
      }
      final raw = await file.readAsBytes();
      final compressed = await compute(_compressForPdf, raw);
      if (mounted) setState(() => _capturedImages.add(compressed));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
    if (mounted) setState(() => _isCapturing = false);
  }

  void _removeImage(int index) {
    HapticFeedback.lightImpact();
    setState(() => _capturedImages.removeAt(index));
  }

  // ── PDF generation ──

  Future<Uint8List> _generatePdf() async {
    final pdfDoc = pw.Document();
    for (final imageBytes in _capturedImages) {
      final image = pw.MemoryImage(imageBytes);
      pdfDoc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(12),
          build: (context) => pw.Center(
            child: pw.Image(image, fit: pw.BoxFit.contain),
          ),
        ),
      );
    }
    final saved = await pdfDoc.save();
    return Uint8List.fromList(saved);
  }

  // ── Send ──

  Future<void> _send() async {
    if (_capturedImages.isEmpty || _isSending) return;
    setState(() => _isSending = true);

    try {
      // 1. Generate PDF
      final pdfBytes = await _generatePdf();
      final pdfBase64 = base64Encode(pdfBytes);

      // 2. Call API
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final date = DateFormat('yyyy-MM-dd').format(DateTime.now());

      final resp = await _apiService.createTransportDocument(
        pdfBase64: pdfBase64,
        transportName: _transportName,
        phones: _phones,
        caption: _captionController.text.trim(),
        imageCount: _capturedImages.length,
        date: date,
        createdBy: auth.username ?? '',
        companyName: _billingFrom,
      );

      if (!mounted) return;
      final data = resp.data;

      if (data['success'] == true) {
        final sentCount = data['sentCount'] ?? 0;
        final totalCount = data['totalCount'] ?? _phones.length;
        HapticFeedback.mediumImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sent ${_capturedImages.length} images as PDF to $_transportName ($sentCount/$totalCount delivered)'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 3),
          ),
        );
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: ${data['error'] ?? 'Unknown error'}'),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _isSending = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent),
        );
        setState(() => _isSending = false);
      }
    }
  }

  String _formatPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+91 $digits';
    for (final cc in ['971', '966', '974', '968', '973', '965', '91', '44', '65', '60', '1']) {
      if (digits.startsWith(cc) && digits.length > cc.length) {
        return '+$cc ${digits.substring(cc.length)}';
      }
    }
    return '+$digits';
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTransportInfo(),
                      const SizedBox(height: 16),
                      _buildCompanySelector(),
                      const SizedBox(height: 16),
                      _buildCaptionField(),
                      const SizedBox(height: 16),
                      _buildImageGrid(),
                      const SizedBox(height: 16),
                      _buildCaptureButtons(),
                      const SizedBox(height: 24),
                      _buildSendButton(),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 44,
              height: 44,
              decoration: AppTheme.machinedDecoration,
              child: const Icon(Icons.arrow_back_rounded, color: AppTheme.primary, size: 22),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SEND DOCUMENTS',
                  style: GoogleFonts.manrope(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.primary,
                    letterSpacing: 2.5,
                  ),
                ),
                Text(
                  _transportName,
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportInfo() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.local_shipping_rounded, color: AppTheme.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _transportName,
                  style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.title),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.phone, size: 12, color: Color(0xFF25D366)),
                    const SizedBox(width: 4),
                    Text(
                      _phones.map(_formatPhone).join(', '),
                      style: const TextStyle(fontSize: 12, color: Color(0xFF25D366), fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompanySelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.business_rounded, color: AppTheme.primary, size: 20),
          const SizedBox(width: 12),
          Text('Billing From', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.muted)),
          const Spacer(),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _billingFrom,
              style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.title),
              items: const [
                DropdownMenuItem(value: 'SYGT', child: Text('SYGT', style: TextStyle(fontWeight: FontWeight.w600))),
                DropdownMenuItem(value: 'ESPL', child: Text('ESPL', style: TextStyle(fontWeight: FontWeight.w600))),
              ],
              onChanged: (v) { if (v != null) setState(() => _billingFrom = v); },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptionField() {
    return TextField(
      controller: _captionController,
      textCapitalization: TextCapitalization.sentences,
      maxLines: 2,
      decoration: InputDecoration(
        labelText: 'Caption / Note (optional)',
        hintText: 'e.g. Invoice #123, E-way bill attached',
        prefixIcon: const Icon(Icons.note_alt_outlined, size: 20),
        filled: true,
        fillColor: Colors.white.withOpacity(0.9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppTheme.titaniumBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppTheme.titaniumBorder),
        ),
      ),
    );
  }

  Widget _buildImageGrid() {
    if (_capturedImages.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 48),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.withOpacity(0.2), style: BorderStyle.solid),
        ),
        child: Column(
          children: [
            Icon(Icons.add_photo_alternate_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              'Capture invoice & e-way bill images',
              style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.muted, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'All images will be combined into one PDF',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_capturedImages.length} image${_capturedImages.length > 1 ? 's' : ''} → 1 PDF',
          style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary),
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.75,
          ),
          itemCount: _capturedImages.length,
          itemBuilder: (context, index) {
            return Stack(
              children: [
                // Image thumbnail
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.titaniumBorder),
                    image: DecorationImage(
                      image: MemoryImage(_capturedImages[index]),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                // Page number badge
                Positioned(
                  bottom: 4,
                  left: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Page ${index + 1}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                // Delete button
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => _removeImage(index),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildCaptureButtons() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isCapturing ? null : () => _captureImage(fromGallery: false),
            icon: _isCapturing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.camera_alt_rounded, size: 20),
            label: const Text('Camera'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _isCapturing ? null : () => _captureImage(fromGallery: true),
            icon: const Icon(Icons.photo_library_rounded, size: 20),
            label: const Text('Gallery'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.primary,
              side: const BorderSide(color: AppTheme.primary),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSendButton() {
    final canSend = _capturedImages.isNotEmpty && !_isSending;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton.icon(
        onPressed: canSend ? _send : null,
        icon: _isSending
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : const Icon(Icons.send_rounded, size: 22),
        label: Text(
          _isSending
              ? 'Sending...'
              : _capturedImages.isEmpty
                  ? 'Capture images first'
                  : 'Send ${_capturedImages.length} image${_capturedImages.length > 1 ? 's' : ''} as PDF',
          style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: canSend ? const Color(0xFF25D366) : Colors.grey[400],
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: canSend ? 4 : 0,
        ),
      ),
    );
  }
}
