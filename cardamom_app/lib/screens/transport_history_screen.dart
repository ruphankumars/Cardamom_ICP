import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

/// Screen showing history of transport documents sent via WhatsApp.
class TransportHistoryScreen extends StatefulWidget {
  const TransportHistoryScreen({super.key});

  @override
  State<TransportHistoryScreen> createState() => _TransportHistoryScreenState();
}

class _TransportHistoryScreenState extends State<TransportHistoryScreen> {
  final ApiService _apiService = ApiService();
  List<Map<String, dynamic>> _documents = [];
  List<String> _transportNames = [];
  String? _selectedTransport;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      // Load transport names for filter
      final ddResp = await _apiService.getDropdownCategory('transports');
      final names = (ddResp.data['items'] as List?)?.map((e) => e.toString()).toList() ?? [];
      names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      // Load documents
      final resp = await _apiService.getTransportDocuments(
        transportName: _selectedTransport,
        limit: 100,
      );
      final data = resp.data;
      final docs = (data['documents'] as List?)
              ?.map((d) => Map<String, dynamic>.from(d as Map))
              .toList() ??
          [];

      if (!mounted) return;
      setState(() {
        _transportNames = names;
        _documents = docs;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load history: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '';
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('dd MMM yyyy, h:mm a').format(date);
    } catch (_) {
      return dateStr;
    }
  }

  String _formatShortDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '';
    try {
      if (dateStr.length == 10) {
        // yyyy-MM-dd format
        final date = DateFormat('yyyy-MM-dd').parse(dateStr);
        return DateFormat('dd MMM').format(date);
      }
      final date = DateTime.parse(dateStr);
      return DateFormat('dd MMM').format(date);
    } catch (_) {
      return dateStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Transport History',
      disableInternalScrolling: true,
      content: Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _loadData,
                    child: _documents.isEmpty
                        ? _buildEmptyState()
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                            itemCount: _documents.length,
                            itemBuilder: (context, index) => _buildDocumentCard(_documents[index]),
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.titaniumBorder),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _selectedTransport,
                  isExpanded: true,
                  hint: Text('All Transports', style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                  style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.title),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All Transports'),
                    ),
                    ..._transportNames.map((name) => DropdownMenuItem<String?>(
                          value: name,
                          child: Text(name, overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: (value) {
                    setState(() => _selectedTransport = value);
                    _loadData();
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Refresh button
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.titaniumBorder),
            ),
            child: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20, color: AppTheme.primary),
              onPressed: _loadData,
              tooltip: 'Refresh',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.2),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history_rounded, size: 56, color: Colors.grey[400]),
              const SizedBox(height: 12),
              Text(
                _selectedTransport != null
                    ? 'No documents sent to $_selectedTransport'
                    : 'No documents sent yet',
                style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Send documents from the transport list',
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDocumentCard(Map<String, dynamic> doc) {
    final transportName = doc['transportName']?.toString() ?? '';
    final date = doc['date']?.toString() ?? '';
    final imageCount = doc['imageCount'] ?? 0;
    final caption = doc['caption']?.toString() ?? '';
    final sentPhones = (doc['sentToPhones'] as List?)?.length ?? 0;
    final totalPhones = (doc['phones'] as List?)?.length ?? 0;
    final pdfUrl = doc['pdfUrl']?.toString() ?? '';
    final createdAt = doc['createdAt']?.toString() ?? '';
    final allSent = sentPhones > 0 && sentPhones >= totalPhones;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: pdfUrl.isNotEmpty ? () => _openPdf(pdfUrl) : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status icon
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: allSent
                        ? AppTheme.success.withOpacity(0.1)
                        : sentPhones > 0
                            ? Colors.orange.withOpacity(0.1)
                            : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    allSent
                        ? Icons.check_circle_rounded
                        : sentPhones > 0
                            ? Icons.warning_amber_rounded
                            : Icons.error_outline_rounded,
                    color: allSent ? AppTheme.success : sentPhones > 0 ? Colors.orange : Colors.red,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                // Details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              transportName,
                              style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.title),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            _formatShortDate(date),
                            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.picture_as_pdf, size: 13, color: Colors.red[400]),
                          const SizedBox(width: 4),
                          Text(
                            '$imageCount page${imageCount > 1 ? 's' : ''}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            Icons.send_rounded,
                            size: 12,
                            color: allSent ? AppTheme.success : Colors.grey[500],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$sentPhones/$totalPhones sent',
                            style: TextStyle(
                              fontSize: 12,
                              color: allSent ? AppTheme.success : Colors.grey[600],
                              fontWeight: allSent ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                      if (caption.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          caption,
                          style: TextStyle(fontSize: 12, color: Colors.grey[600], fontStyle: FontStyle.italic),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (createdAt.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          _formatDate(createdAt),
                          style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                        ),
                      ],
                    ],
                  ),
                ),
                // PDF view icon
                if (pdfUrl.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(Icons.open_in_new, size: 16, color: Colors.grey[400]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openPdf(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open PDF: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }
}
