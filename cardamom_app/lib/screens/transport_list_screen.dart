import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

/// Screen showing list of transport companies.
/// Tap a transport → navigate to send documents screen.
class TransportListScreen extends StatefulWidget {
  const TransportListScreen({super.key});

  @override
  State<TransportListScreen> createState() => _TransportListScreenState();
}

class _TransportListScreenState extends State<TransportListScreen> {
  final ApiService _apiService = ApiService();
  List<String> _transports = [];
  Map<String, List<String>> _transportPhones = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTransports();
  }

  Future<void> _loadTransports() async {
    setState(() => _isLoading = true);
    try {
      // Load transport names — try category endpoint, fall back to public dropdowns
      List<String> items;
      try {
        final resp = await _apiService.getDropdownCategory('transports');
        items = (resp.data['items'] as List?)?.map((e) => e.toString()).toList() ?? [];
      } catch (_) {
        // Fallback: public endpoint (no auth required)
        final resp = await _apiService.getDropdownOptions();
        items = (resp.data['transport'] as List?)?.map((e) => e.toString()).toList() ?? [];
      }

      // Load phone numbers from client_contacts (non-blocking — cards show even if this fails)
      final phones = <String, List<String>>{};
      try {
        final contactsResp = await _apiService.getAllClientContacts();
        final contactsData = contactsResp.data;
        final Map<String, dynamic> body;
        if (contactsData is Map<String, dynamic>) {
          body = contactsData;
        } else if (contactsData is String) {
          body = Map<String, dynamic>.from(jsonDecode(contactsData) as Map);
        } else {
          body = <String, dynamic>{};
        }

        if (body['success'] == true && body['contacts'] != null) {
          final contacts = body['contacts'] as List;
          final lowerToName = <String, String>{};
          for (final t in items) {
            lowerToName[t.toLowerCase().trim()] = t;
          }
          for (final c in contacts) {
            final name = c['name']?.toString() ?? '';
            final key = lowerToName[name.toLowerCase().trim()];
            if (key == null) continue;
            List<String> pList = [];
            if (c['phones'] is List && (c['phones'] as List).isNotEmpty) {
              pList = (c['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
            } else if (c['phone'] != null && c['phone'].toString().trim().isNotEmpty) {
              pList = [c['phone'].toString().trim()];
            }
            if (pList.isNotEmpty) phones[key] = pList;
          }
        }
      } catch (e) {
        debugPrint('Error loading contacts for transports: $e');
      }

      if (!mounted) return;
      setState(() {
        _transports = items..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        _transportPhones = phones;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load transports: $e'), backgroundColor: Colors.redAccent),
      );
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

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Transport Documents',
      disableInternalScrolling: true,
      topActions: [
        IconButton(
          icon: const Icon(Icons.history_rounded, color: AppTheme.primary),
          onPressed: () => Navigator.pushNamed(context, '/transport_history'),
          tooltip: 'Send History',
        ),
        IconButton(
          icon: const Icon(Icons.settings_rounded, color: AppTheme.primary, size: 22),
          onPressed: () => Navigator.pushNamed(context, '/dropdown_management'),
          tooltip: 'Manage Transports',
        ),
      ],
      content: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadTransports,
              child: _transports.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                      itemCount: _transports.length,
                      itemBuilder: (context, index) => _buildTransportCard(_transports[index]),
                    ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.25),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_shipping_outlined, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                'No transports added yet',
                style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.muted),
              ),
              const SizedBox(height: 8),
              Text(
                'Go to Dropdown Manager → Transports tab to add transport companies',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => Navigator.pushNamed(context, '/dropdown_management'),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Transport'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTransportCard(String name) {
    final phones = _transportPhones[name] ?? [];
    final hasPhone = phones.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.titaniumBorder),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            if (!hasPhone) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Add a phone number for "$name" first'),
                  backgroundColor: Colors.orange,
                  action: SnackBarAction(
                    label: 'Add',
                    textColor: Colors.white,
                    onPressed: () => Navigator.pushNamed(context, '/dropdown_management'),
                  ),
                ),
              );
              return;
            }
            HapticFeedback.lightImpact();
            Navigator.pushNamed(context, '/transport_send', arguments: {
              'transportName': name,
              'phones': phones,
            });
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Transport icon
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: hasPhone
                        ? AppTheme.primary.withOpacity(0.1)
                        : Colors.grey.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.local_shipping_rounded,
                    color: hasPhone ? AppTheme.primary : Colors.grey,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                // Name + phone
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: GoogleFonts.manrope(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.title,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (hasPhone)
                        Row(
                          children: [
                            const Icon(Icons.phone, size: 12, color: Color(0xFF25D366)),
                            const SizedBox(width: 4),
                            Text(
                              _formatPhone(phones.first),
                              style: const TextStyle(fontSize: 12, color: Color(0xFF25D366), fontWeight: FontWeight.w500),
                            ),
                          ],
                        )
                      else
                        Text(
                          'No phone number — tap to add',
                          style: TextStyle(fontSize: 12, color: Colors.grey[400], fontStyle: FontStyle.italic),
                        ),
                    ],
                  ),
                ),
                // Arrow
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 16,
                  color: hasPhone ? AppTheme.primary : Colors.grey[400],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
