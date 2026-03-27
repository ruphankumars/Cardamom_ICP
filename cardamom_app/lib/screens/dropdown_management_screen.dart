import 'dart:convert';
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/cache_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

class DropdownManagementScreen extends StatefulWidget {
  const DropdownManagementScreen({super.key});

  @override
  State<DropdownManagementScreen> createState() => _DropdownManagementScreenState();
}

class _DropdownManagementScreenState extends State<DropdownManagementScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;
  bool _isLoading = true;

  final List<_TabInfo> _tabs = [
    _TabInfo('Clients', 'clients', Icons.people),
    _TabInfo('Grades', 'grades', Icons.grain),
    _TabInfo('Bag/Box', 'bagbox', Icons.inventory_2),
    _TabInfo('Brands', 'brands', Icons.branding_watermark),
    _TabInfo('Workers', 'workers', Icons.badge),
    _TabInfo('Transports', 'transports', Icons.local_shipping),
  ];

  final Map<String, List<String>> _data = {
    'clients': [],
    'grades': [],
    'bagbox': [],
    'brands': [],
    'workers': [],
    'transports': [],
  };

  // Cache client phone numbers and addresses for display
  final Map<String, List<String>> _clientPhones = {};
  final Map<String, String> _clientAddresses = {};

  // Cache transport phone numbers for display
  final Map<String, List<String>> _transportPhones = {};

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          _searchController.clear();
          _searchQuery = '';
        });
      }
    });
    _loadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getDropdownOptions();
      final d = response.data;
      if (!mounted) return;

      _data['clients'] = List<String>.from(d['client'] ?? []);
      _data['grades'] = List<String>.from(d['grade'] ?? []);
      _data['bagbox'] = List<String>.from(d['bagbox'] ?? []);
      _data['brands'] = List<String>.from(d['brand'] ?? []);
      _data['transports'] = List<String>.from(d['transport'] ?? []);

      // Load workers separately — don't let it fail the whole load
      try {
        final workersResponse = await _apiService.getWorkers();
        final workers = workersResponse.data is List
            ? (workersResponse.data as List).map((w) => w['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList()
            : <String>[];
        _data['workers'] = List<String>.from(workers);
      } catch (e) {
        debugPrint('Error loading workers (non-fatal): $e');
        _data['workers'] = [];
      }

      // Load client + transport phone numbers BEFORE setting isLoading=false
      await Future.wait([_loadClientPhones(), _loadTransportPhones()]);

      if (!mounted) return;
      setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('Error loading dropdowns: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  /// Load phone numbers and addresses for all clients in one call
  Future<void> _loadClientPhones() async {
    // Clear maps so stale data doesn't persist across reloads
    _clientPhones.clear();
    _clientAddresses.clear();
    try {
      final resp = await _apiService.getAllClientContacts();
      final data = resp.data;
      // Handle both Map and String responses from Dio
      final Map<String, dynamic> body;
      if (data is Map<String, dynamic>) {
        body = data;
      } else if (data is String) {
        body = Map<String, dynamic>.from(jsonDecode(data) as Map);
      } else {
        body = <String, dynamic>{};
      }

      if (body['success'] == true && body['contacts'] != null) {
        final contacts = body['contacts'] as List;
        debugPrint('[_loadClientPhones] Got ${contacts.length} contacts');
        // Build a lowercase → actual dropdown name map for matching
        final dropdownClients = _data['clients'] ?? [];
        final lowerToDropdown = <String, String>{};
        for (final d in dropdownClients) {
          lowerToDropdown[d.toString().toLowerCase().trim()] = d.toString();
        }

        int matched = 0;
        for (final c in contacts) {
          final contactName = c['name']?.toString() ?? '';
          if (contactName.isEmpty) continue;

          // Match contact name to the actual dropdown item name (case-insensitive)
          final key = lowerToDropdown[contactName.toLowerCase().trim()] ?? contactName;

          // Read phones array, fall back to single phone string
          List<String> phones = [];
          if (c['phones'] is List && (c['phones'] as List).isNotEmpty) {
            phones = (c['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
          } else if (c['phone'] != null && c['phone'].toString().trim().isNotEmpty) {
            phones = [c['phone'].toString().trim()];
          }
          if (phones.isNotEmpty) {
            _clientPhones[key] = phones;
            matched++;
          }

          final address = c['address']?.toString().trim() ?? '';
          if (address.isNotEmpty) {
            _clientAddresses[key] = address;
          }
        }
        debugPrint('[_loadClientPhones] Matched $matched contacts with phones');
      } else {
        debugPrint('[_loadClientPhones] API returned success=${body['success']}, contacts=${body['contacts'] != null}');
      }
    } catch (e, stack) {
      debugPrint('[_loadClientPhones] ERROR: $e');
      debugPrint('[_loadClientPhones] Stack: $stack');
    }
    if (mounted) setState(() {});
  }

  /// Load phone numbers for all transports (reuses client_contacts API)
  Future<void> _loadTransportPhones() async {
    _transportPhones.clear();
    try {
      final resp = await _apiService.getAllClientContacts();
      final data = resp.data;
      final Map<String, dynamic> body;
      if (data is Map<String, dynamic>) {
        body = data;
      } else if (data is String) {
        body = Map<String, dynamic>.from(jsonDecode(data) as Map);
      } else {
        body = <String, dynamic>{};
      }

      if (body['success'] == true && body['contacts'] != null) {
        final contacts = body['contacts'] as List;
        final transportNames = _data['transports'] ?? [];
        final lowerToTransport = <String, String>{};
        for (final t in transportNames) {
          lowerToTransport[t.toString().toLowerCase().trim()] = t.toString();
        }

        for (final c in contacts) {
          final contactName = c['name']?.toString() ?? '';
          if (contactName.isEmpty) continue;
          final key = lowerToTransport[contactName.toLowerCase().trim()];
          if (key == null) continue; // Only match transport names

          List<String> phones = [];
          if (c['phones'] is List && (c['phones'] as List).isNotEmpty) {
            phones = (c['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
          } else if (c['phone'] != null && c['phone'].toString().trim().isNotEmpty) {
            phones = [c['phone'].toString().trim()];
          }
          if (phones.isNotEmpty) {
            _transportPhones[key] = phones;
          }
        }
      }
    } catch (e) {
      debugPrint('[_loadTransportPhones] ERROR: $e');
    }
    if (mounted) setState(() {});
  }

  String get _currentCategory => _tabs[_tabController.index].category;

  List<String> get _filteredItems {
    final items = List<String>.from(_data[_currentCategory] ?? []);
    // Always sort alphabetically (case-insensitive)
    items.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (_searchQuery.isEmpty) return items;
    return items
        .where((i) => i.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // ADD
  // ---------------------------------------------------------------------------
  void _showAddDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add ${_tabs[_tabController.index].label}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: 'Enter new value',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onSubmitted: (_) async {
            Navigator.pop(ctx);
            await _addItem(controller.text.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _addItem(controller.text.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF22C55E),
              foregroundColor: Colors.white,
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _addItem(String value) async {
    if (value.isEmpty) return;

    // For clients, workers, and transports, check for similar names first
    if (_currentCategory == 'clients' || _currentCategory == 'workers' || _currentCategory == 'transports') {
      List<Map<String, dynamic>> similarItems = [];
      try {
        final response = _currentCategory == 'workers'
            ? await _apiService.searchWorkers(value)
            : await _apiService.searchDropdownItems(_currentCategory, value);
        final data = response.data as Map<String, dynamic>;
        final exact = (data['exactMatches'] as List<dynamic>?) ?? [];
        final similar = (data['similarMatches'] as List<dynamic>?) ?? [];
        similarItems = [...exact, ...similar].cast<Map<String, dynamic>>();
      } catch (e) {
        debugPrint('Error searching for similar items: $e');
      }

      if (!mounted) return;

      bool shouldAdd = true;
      if (similarItems.isNotEmpty) {
        final label = _currentCategory == 'workers' ? 'Worker' : _currentCategory == 'transports' ? 'Transport' : 'Client';
        shouldAdd = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text('Similar $label Found', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Found ${label.toLowerCase()}s with similar names:'),
                const SizedBox(height: 12),
                ...similarItems.take(5).map((c) {
                  final itemName = c['value'] ?? c['name'] ?? '';
                  final similarity = c['similarity'];
                  final pct = similarity != null
                      ? (similarity is int ? '$similarity% similar' : '${(similarity * 100).toInt()}% similar')
                      : '';
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: const Color(0xFFE2E8F0),
                      child: Text(
                        itemName.isNotEmpty ? itemName[0].toUpperCase() : '?',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E)),
                      ),
                    ),
                    title: Text(itemName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: pct.isNotEmpty
                        ? Text(pct, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12))
                        : null,
                  );
                }),
                const SizedBox(height: 12),
                Text('Do you still want to add "$value" as a new ${label.toLowerCase()}?'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
                child: const Text('Add Anyway', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ) ?? false;
      }

      if (!shouldAdd || !mounted) return;

      // Use force-add if similar items were found (user confirmed)
      try {
        final Response result;
        if (_currentCategory == 'workers') {
          result = similarItems.isNotEmpty
              ? await _apiService.forceAddWorker({'name': value})
              : await _apiService.addWorker({'name': value});
        } else {
          result = similarItems.isNotEmpty
              ? await _apiService.forceAddDropdownItem(_currentCategory, value)
              : await _apiService.addDropdownItem(_currentCategory, value);
        }
        if (!mounted) return;
        if (result.data['success'] == true) {
          setState(() => _data[_currentCategory]?.add(value));
          // Invalidate dropdown cache so other screens see the new item
          context.read<CacheManager>().dropdownCache.clear();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_currentCategory == 'transports'
                  ? '"$value" added — now add phone number'
                  : '"$value" added — now add phone & address'),
              backgroundColor: const Color(0xFF22C55E),
            ),
          );
          // Auto-open edit dialog for clients/transports so user can add phone
          if (_currentCategory == 'clients') {
            Future.delayed(const Duration(milliseconds: 300), () {
              if (mounted) _showClientEditDialog(value);
            });
          } else if (_currentCategory == 'transports') {
            Future.delayed(const Duration(milliseconds: 300), () {
              if (mounted) _showTransportEditDialog(value);
            });
          }
        } else if (result.data['isDuplicate'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('"${result.data['existingValue']}" already exists'), backgroundColor: Colors.orange),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
      return;
    }

    // For other categories (grades, bagbox, brands) — direct add
    try {
      final result = await _apiService.addDropdownItem(_currentCategory, value);
      if (!mounted) return;
      if (result.data['success'] == true) {
        setState(() => _data[_currentCategory]?.add(value));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$value" added'), backgroundColor: const Color(0xFF22C55E)),
        );
      } else if (result.data['isDuplicate'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${result.data['existingValue']}" already exists'), backgroundColor: Colors.orange),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // EDIT
  // ---------------------------------------------------------------------------
  void _showEditDialog(String oldValue) {
    // For clients, show extended dialog with phone number
    if (_currentCategory == 'clients') {
      _showClientEditDialog(oldValue);
      return;
    }
    // For transports, show dialog with name + phone
    if (_currentCategory == 'transports') {
      _showTransportEditDialog(oldValue);
      return;
    }

    final controller = TextEditingController(text: oldValue);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Value'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onSubmitted: (_) async {
            Navigator.pop(ctx);
            await _editItem(oldValue, controller.text.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _editItem(oldValue, controller.text.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Country code options for WhatsApp numbers
  static const List<Map<String, String>> _countryCodes = [
    {'code': '91', 'flag': '🇮🇳', 'label': '+91 India'},
    {'code': '971', 'flag': '🇦🇪', 'label': '+971 UAE'},
    {'code': '966', 'flag': '🇸🇦', 'label': '+966 Saudi'},
    {'code': '974', 'flag': '🇶🇦', 'label': '+974 Qatar'},
    {'code': '968', 'flag': '🇴🇲', 'label': '+968 Oman'},
    {'code': '973', 'flag': '🇧🇭', 'label': '+973 Bahrain'},
    {'code': '965', 'flag': '🇰🇼', 'label': '+965 Kuwait'},
    {'code': '1', 'flag': '🇺🇸', 'label': '+1 US'},
    {'code': '44', 'flag': '🇬🇧', 'label': '+44 UK'},
    {'code': '65', 'flag': '🇸🇬', 'label': '+65 Singapore'},
    {'code': '60', 'flag': '🇲🇾', 'label': '+60 Malaysia'},
  ];

  /// Parse a stored phone string into {code, number}
  /// Stored numbers are expected to have country code prepended (e.g. '919677395771').
  /// A bare 10-digit Indian number (no code) defaults to code '91'.
  static Map<String, String> _parsePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return {'code': '91', 'number': ''};

    // Bare 10-digit number → assume India
    if (digits.length == 10) {
      return {'code': '91', 'number': digits};
    }

    // Try to match known country codes (longest first)
    for (final cc in ['971', '966', '974', '968', '973', '965', '91', '44', '65', '60', '1']) {
      if (digits.startsWith(cc) && digits.length > cc.length) {
        return {'code': cc, 'number': digits.substring(cc.length)};
      }
    }
    // Fallback: assume the whole thing is the number with India code
    return {'code': '91', 'number': digits};
  }

  /// Format a stored phone for display (e.g. '919677395771' → '+91 9677395771')
  static String _formatPhoneDisplay(String raw) {
    final parsed = _parsePhone(raw);
    final code = parsed['code']!;
    final number = parsed['number']!;
    if (number.isEmpty) return raw;
    return '+$code $number';
  }

  /// Client-specific edit dialog with name + multiple phone numbers + address
  void _showClientEditDialog(String clientName) async {
    final nameController = TextEditingController(text: clientName);
    final addressController = TextEditingController();

    // Use a single list of maps to keep all phone state together (avoids index sync issues)
    final List<_PhoneEntry> phoneEntries = [_PhoneEntry()];

    // Track whether we successfully loaded existing contact data.
    // If fetch fails, we must NOT send empty phones on save (would wipe existing data).
    bool contactLoadedOk = false;
    bool hadExistingPhones = false;

    // Fetch existing contact info
    try {
      final resp = await _apiService.getClientContact(clientName);
      if (resp.data['success'] == true && resp.data['contact'] != null) {
        contactLoadedOk = true;
        final contact = resp.data['contact'];

        List<String> rawPhones = [];
        if (contact['phones'] is List && (contact['phones'] as List).isNotEmpty) {
          rawPhones = (contact['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
        } else if (contact['rawPhones'] is List && (contact['rawPhones'] as List).isNotEmpty) {
          rawPhones = (contact['rawPhones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
        } else if (contact['phone'] != null && contact['phone'].toString().trim().isNotEmpty) {
          rawPhones = [contact['phone'].toString().trim()];
        }

        if (rawPhones.isNotEmpty) {
          hadExistingPhones = true;
          phoneEntries.clear();
          for (final p in rawPhones) {
            final parsed = _parsePhone(p);
            phoneEntries.add(_PhoneEntry(
              controller: TextEditingController(text: parsed['number']),
              code: parsed['code']!,
            ));
          }
        }

        addressController.text = contact['address']?.toString() ?? '';
      } else if (resp.data['success'] == false) {
        // Contact doesn't exist yet — that's OK, we'll create one on save
        contactLoadedOk = true;
      }
    } catch (e) {
      debugPrint('[ClientEdit] Failed to load contact for "$clientName": $e');
      // contactLoadedOk stays false — we'll be careful not to wipe existing phones
    }

    if (!mounted) return;

    bool isSaving = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {

          Future<bool> verifyPhone(int idx) async {
            if (idx < 0 || idx >= phoneEntries.length) return true;
            final entry = phoneEntries[idx];
            final phone = entry.controller.text.trim().replaceAll(RegExp(r'\D'), '');

            if (phone.isEmpty) {
              setDialogState(() { entry.error = null; entry.verified = null; });
              return true;
            }
            if (phone.length < 4) {
              setDialogState(() { entry.error = 'Number too short'; entry.verified = false; });
              return false;
            }
            if (entry.code == '91') {
              if (phone.length != 10) {
                setDialogState(() { entry.error = 'Enter a valid 10-digit number'; entry.verified = false; });
                return false;
              }
              if (!RegExp(r'^[6-9]\d{9}$').hasMatch(phone)) {
                setDialogState(() { entry.error = 'Must start with 6, 7, 8, or 9'; entry.verified = false; });
                return false;
              }
            }

            setDialogState(() { entry.verifying = true; entry.error = null; });
            try {
              final fullNumber = '${entry.code}$phone';
              final resp = await _apiService.verifyWhatsAppNumber(fullNumber);
              if (resp.data['success'] == true) {
                final valid = resp.data['valid'] == true;
                if (ctx.mounted) {
                  setDialogState(() {
                    entry.verifying = false;
                    entry.verified = valid;
                    entry.error = valid ? null : 'Not active on WhatsApp';
                  });
                }
                return valid;
              }
            } catch (_) {}
            if (ctx.mounted) {
              setDialogState(() { entry.verifying = false; entry.verified = true; });
            }
            return true;
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Edit Client', style: TextStyle(fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Client Name
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Client Name',
                        prefixIcon: const Icon(Icons.person_outline, size: 20),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Phone Numbers header
                    Row(
                      children: [
                        Icon(Icons.phone, size: 16, color: Colors.grey[600]),
                        const SizedBox(width: 4),
                        Text('WhatsApp Numbers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[700])),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            setDialogState(() {
                              phoneEntries.add(_PhoneEntry());
                            });
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add', style: TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF22C55E),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Phone fields
                    for (int i = 0; i < phoneEntries.length; i++)
                      Padding(
                        key: ValueKey(phoneEntries[i].key),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Country code dropdown
                            Container(
                              height: 48,
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.only(left: 4),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade400),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: phoneEntries[i].code,
                                  isDense: true,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87),
                                  items: _countryCodes.map((c) => DropdownMenuItem<String>(
                                    value: c['code'],
                                    child: Text('${c['flag']} +${c['code']}', style: const TextStyle(fontSize: 13)),
                                  )).toList(),
                                  onChanged: (val) {
                                    if (val == null) return;
                                    setDialogState(() {
                                      phoneEntries[i].code = val;
                                      phoneEntries[i].verified = null;
                                      phoneEntries[i].error = null;
                                    });
                                  },
                                ),
                              ),
                            ),
                            // Phone number input
                            Expanded(
                              child: TextField(
                                controller: phoneEntries[i].controller,
                                keyboardType: TextInputType.phone,
                                onChanged: (_) {
                                  if (phoneEntries[i].verified != null || phoneEntries[i].error != null) {
                                    setDialogState(() { phoneEntries[i].verified = null; phoneEntries[i].error = null; });
                                  }
                                },
                                decoration: InputDecoration(
                                  labelText: phoneEntries.length > 1 ? 'Phone ${i + 1}' : 'WhatsApp Number',
                                  hintText: phoneEntries[i].code == '91' ? 'e.g. 9876543210' : 'Phone number',
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                  errorBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: Colors.red, width: 1.5),
                                  ),
                                  errorText: phoneEntries[i].error,
                                  errorStyle: const TextStyle(fontSize: 11),
                                  suffixIcon: phoneEntries[i].verifying
                                      ? const Padding(
                                          padding: EdgeInsets.all(10),
                                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                                        )
                                      : phoneEntries[i].verified == true
                                          ? const Icon(Icons.verified, color: Color(0xFF22C55E), size: 20)
                                          : phoneEntries[i].verified == false
                                              ? const Icon(Icons.error_outline, color: Colors.red, size: 20)
                                              : phoneEntries[i].controller.text.trim().isNotEmpty
                                                  ? IconButton(
                                                      icon: const Icon(Icons.check_circle_outline, color: Colors.orange, size: 20),
                                                      tooltip: 'Verify WhatsApp',
                                                      onPressed: () => verifyPhone(i),
                                                    )
                                                  : null,
                                ),
                              ),
                            ),
                            if (phoneEntries.length > 1)
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                                tooltip: 'Remove',
                                onPressed: () {
                                  setDialogState(() {
                                    phoneEntries[i].controller.dispose();
                                    phoneEntries.removeAt(i);
                                  });
                                },
                                padding: const EdgeInsets.only(top: 8),
                                constraints: const BoxConstraints(),
                              ),
                          ],
                        ),
                      ),

                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Order confirmations & offers will be sent to all numbers',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ),

                    // Address section
                    const Divider(height: 16),
                    TextField(
                      controller: addressController,
                      textCapitalization: TextCapitalization.words,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: 'Address (optional)',
                        prefixIcon: const Padding(
                          padding: EdgeInsets.only(bottom: 24),
                          child: Icon(Icons.location_on_outlined, size: 20),
                        ),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: isSaving ? null : () async {
                  // Basic length check — don't block on WhatsApp verification
                  for (final entry in phoneEntries) {
                    final p = entry.controller.text.trim().replaceAll(RegExp(r'\D'), '');
                    if (p.isNotEmpty && entry.code == '91' && p.length != 10) {
                      setDialogState(() { entry.error = 'Enter a valid 10-digit number'; entry.verified = false; });
                      return;
                    }
                    if (p.isNotEmpty && entry.code == '91' && !RegExp(r'^[6-9]').hasMatch(p)) {
                      setDialogState(() { entry.error = 'Must start with 6, 7, 8, or 9'; entry.verified = false; });
                      return;
                    }
                    if (p.isNotEmpty && p.length < 4) {
                      setDialogState(() { entry.error = 'Number too short'; entry.verified = false; });
                      return;
                    }
                  }

                  // Collect non-empty phones with country codes, deduplicate
                  final phones = <String>[];
                  debugPrint('[ClientEdit] phoneEntries count: ${phoneEntries.length}');
                  for (int ei = 0; ei < phoneEntries.length; ei++) {
                    final entry = phoneEntries[ei];
                    final rawText = entry.controller.text;
                    final p = rawText.trim().replaceAll(RegExp(r'\D'), '');
                    debugPrint('[ClientEdit] Entry[$ei] code=${entry.code} raw="$rawText" digits="$p"');
                    if (p.isNotEmpty) {
                      final full = '${entry.code}$p';
                      if (!phones.contains(full)) phones.add(full);
                    }
                  }

                  setDialogState(() { isSaving = true; });

                  final newName = nameController.text.trim();
                  final address = addressController.text.trim();

                  // Save name change if different
                  final nameChanged = newName.isNotEmpty && newName != clientName;
                  if (nameChanged) {
                    await _editItem(clientName, newName);
                  }

                  final effectiveName = newName.isNotEmpty ? newName : clientName;

                  // Decide whether to send phones:
                  // - If contact loaded OK: always send (user saw the current state)
                  // - If contact fetch failed AND user didn't enter any new phone:
                  //   don't send phones (avoids wiping existing data we couldn't load)
                  final bool shouldSendPhones = contactLoadedOk || phones.isNotEmpty;
                  debugPrint('[ClientEdit] Saving $effectiveName phones=$phones address=$address '
                      'nameChanged=$nameChanged contactLoadedOk=$contactLoadedOk '
                      'hadExisting=$hadExistingPhones shouldSendPhones=$shouldSendPhones');
                  try {
                    final saveResp = await _apiService.updateClientContact(
                      effectiveName,
                      oldName: nameChanged ? clientName : null,
                      phones: shouldSendPhones ? phones : null,
                      address: address,
                    );
                    debugPrint('[ClientEdit] Save response: ${saveResp.data}');
                    if (saveResp.data['success'] != true) {
                      final errMsg = saveResp.data['error']?.toString() ?? 'Save failed';
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(errMsg), backgroundColor: Colors.red),
                        );
                      }
                      if (ctx.mounted) setDialogState(() { isSaving = false; });
                      return;
                    }
                    if (mounted) {
                      _clientPhones.remove(clientName);
                      if (phones.isNotEmpty) {
                        _clientPhones[effectiveName] = phones;
                      } else {
                        _clientPhones.remove(effectiveName);
                      }
                      _clientAddresses.remove(clientName);
                      if (address.isNotEmpty) {
                        _clientAddresses[effectiveName] = address;
                      } else {
                        _clientAddresses.remove(effectiveName);
                      }
                      setState(() {});
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error saving: $e'), backgroundColor: Colors.red),
                      );
                    }
                    if (ctx.mounted) setDialogState(() { isSaving = false; });
                    return;
                  }

                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) {
                    final phoneCount = phones.length;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(phoneCount > 0
                            ? 'Saved $phoneCount number${phoneCount > 1 ? 's' : ''}${address.isNotEmpty ? ' + address' : ''} for $effectiveName'
                            : 'Updated $effectiveName'),
                        backgroundColor: const Color(0xFF22C55E),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                ),
                child: isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Build subtitle for item tiles (phones for clients & transports)
  Widget? _buildItemSubtitle(String item) {
    // Determine which phone cache to use
    final Map<String, List<String>> phoneCache;
    if (_currentCategory == 'clients') {
      phoneCache = _clientPhones;
    } else if (_currentCategory == 'transports') {
      phoneCache = _transportPhones;
    } else {
      return null;
    }

    if (phoneCache.containsKey(item) && phoneCache[item]!.isNotEmpty) {
      final phones = phoneCache[item]!;
      return Row(
        children: [
          const Icon(Icons.phone, size: 12, color: Color(0xFF25D366)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              phones.length == 1
                  ? _formatPhoneDisplay(phones[0])
                  : '${_formatPhoneDisplay(phones[0])} +${phones.length - 1} more',
              style: const TextStyle(fontSize: 12, color: Color(0xFF25D366), fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    return Text('No phone', style: TextStyle(fontSize: 11, color: Colors.grey[400], fontStyle: FontStyle.italic));
  }

  /// Transport-specific edit dialog with name + phone number (simpler than client)
  void _showTransportEditDialog(String transportName) async {
    final nameController = TextEditingController(text: transportName);
    final List<_PhoneEntry> phoneEntries = [_PhoneEntry()];
    bool contactLoadedOk = false;
    bool isSaving = false;

    // Fetch existing contact info
    try {
      final resp = await _apiService.getClientContact(transportName);
      if (resp.data['success'] == true && resp.data['contact'] != null) {
        contactLoadedOk = true;
        final contact = resp.data['contact'];
        List<String> rawPhones = [];
        if (contact['phones'] is List && (contact['phones'] as List).isNotEmpty) {
          rawPhones = (contact['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
        } else if (contact['phone'] != null && contact['phone'].toString().trim().isNotEmpty) {
          rawPhones = [contact['phone'].toString().trim()];
        }
        if (rawPhones.isNotEmpty) {
          phoneEntries.clear();
          for (final p in rawPhones) {
            final parsed = _parsePhone(p);
            phoneEntries.add(_PhoneEntry(
              controller: TextEditingController(text: parsed['number']),
              code: parsed['code']!,
            ));
          }
        }
      } else if (resp.data['success'] == false) {
        contactLoadedOk = true;
      }
    } catch (e) {
      debugPrint('[TransportEdit] Failed to load contact for "$transportName": $e');
    }

    if (!mounted) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {

          Future<bool> verifyPhone(int idx) async {
            if (idx < 0 || idx >= phoneEntries.length) return true;
            final entry = phoneEntries[idx];
            final phone = entry.controller.text.trim().replaceAll(RegExp(r'\D'), '');
            if (phone.isEmpty) {
              setDialogState(() { entry.error = null; entry.verified = null; });
              return true;
            }
            if (entry.code == '91' && phone.length != 10) {
              setDialogState(() { entry.error = 'Enter a valid 10-digit number'; entry.verified = false; });
              return false;
            }
            setDialogState(() { entry.verifying = true; entry.error = null; });
            try {
              final fullNumber = '${entry.code}$phone';
              final resp = await _apiService.verifyWhatsAppNumber(fullNumber);
              if (resp.data['success'] == true) {
                final valid = resp.data['valid'] == true;
                if (ctx.mounted) {
                  setDialogState(() {
                    entry.verifying = false;
                    entry.verified = valid;
                    entry.error = valid ? null : 'Not active on WhatsApp';
                  });
                }
                return valid;
              }
            } catch (_) {}
            if (ctx.mounted) {
              setDialogState(() { entry.verifying = false; entry.verified = true; });
            }
            return true;
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Edit Transport', style: TextStyle(fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Transport Name',
                        prefixIcon: const Icon(Icons.local_shipping, size: 20),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(Icons.phone, size: 16, color: Colors.grey[600]),
                        const SizedBox(width: 4),
                        Text('WhatsApp Number', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[700])),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => setDialogState(() => phoneEntries.add(_PhoneEntry())),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add', style: TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF22C55E),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (int i = 0; i < phoneEntries.length; i++)
                      Padding(
                        key: ValueKey(phoneEntries[i].key),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              height: 48,
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.only(left: 4),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade400),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: phoneEntries[i].code,
                                  isDense: true,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87),
                                  items: _countryCodes.map((c) => DropdownMenuItem<String>(
                                    value: c['code'],
                                    child: Text('${c['flag']} +${c['code']}', style: const TextStyle(fontSize: 13)),
                                  )).toList(),
                                  onChanged: (val) {
                                    if (val == null) return;
                                    setDialogState(() {
                                      phoneEntries[i].code = val;
                                      phoneEntries[i].verified = null;
                                      phoneEntries[i].error = null;
                                    });
                                  },
                                ),
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                controller: phoneEntries[i].controller,
                                keyboardType: TextInputType.phone,
                                decoration: InputDecoration(
                                  hintText: 'Phone number',
                                  errorText: phoneEntries[i].error,
                                  suffixIcon: phoneEntries[i].verifying
                                      ? const Padding(
                                          padding: EdgeInsets.all(12),
                                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                                        )
                                      : phoneEntries[i].verified == true
                                          ? const Icon(Icons.check_circle, color: Color(0xFF25D366), size: 20)
                                          : phoneEntries[i].verified == false
                                              ? const Icon(Icons.cancel, color: Colors.red, size: 20)
                                              : IconButton(
                                                  icon: const Icon(Icons.verified, size: 20, color: Color(0xFF94A3B8)),
                                                  onPressed: () => verifyPhone(i),
                                                  tooltip: 'Verify WhatsApp',
                                                ),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                                ),
                                onChanged: (_) {
                                  if (phoneEntries[i].verified != null) {
                                    setDialogState(() { phoneEntries[i].verified = null; phoneEntries[i].error = null; });
                                  }
                                },
                              ),
                            ),
                            if (phoneEntries.length > 1)
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, size: 20, color: Colors.red),
                                onPressed: () => setDialogState(() => phoneEntries.removeAt(i)),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: isSaving ? null : () async {
                  final phones = <String>[];
                  for (final entry in phoneEntries) {
                    final p = entry.controller.text.trim().replaceAll(RegExp(r'\D'), '');
                    if (p.isNotEmpty) {
                      final full = '${entry.code}$p';
                      if (!phones.contains(full)) phones.add(full);
                    }
                  }

                  setDialogState(() { isSaving = true; });

                  final newName = nameController.text.trim();
                  final nameChanged = newName.isNotEmpty && newName != transportName;
                  if (nameChanged) {
                    await _editItem(transportName, newName);
                  }

                  final effectiveName = newName.isNotEmpty ? newName : transportName;
                  final bool shouldSendPhones = contactLoadedOk || phones.isNotEmpty;

                  try {
                    final saveResp = await _apiService.updateClientContact(
                      effectiveName,
                      oldName: nameChanged ? transportName : null,
                      phones: shouldSendPhones ? phones : null,
                    );
                    if (saveResp.data['success'] != true) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(saveResp.data['error']?.toString() ?? 'Save failed'), backgroundColor: Colors.red),
                        );
                      }
                      if (ctx.mounted) setDialogState(() { isSaving = false; });
                      return;
                    }
                    if (mounted) {
                      _transportPhones.remove(transportName);
                      if (phones.isNotEmpty) {
                        _transportPhones[effectiveName] = phones;
                      } else {
                        _transportPhones.remove(effectiveName);
                      }
                      setState(() {});
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error saving: $e'), backgroundColor: Colors.red),
                      );
                    }
                    if (ctx.mounted) setDialogState(() { isSaving = false; });
                    return;
                  }

                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(phones.isNotEmpty
                            ? 'Saved ${phones.length} number${phones.length > 1 ? 's' : ''} for $effectiveName'
                            : 'Updated $effectiveName'),
                        backgroundColor: const Color(0xFF22C55E),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent, foregroundColor: Colors.white),
                child: isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editItem(String oldValue, String newValue) async {
    if (newValue.isEmpty || oldValue == newValue) return;
    try {
      // Workers use a separate API endpoint
      final Response result;
      if (_currentCategory == 'workers') {
        result = await _apiService.updateWorker(oldValue, {'name': newValue});
      } else {
        result = await _apiService.updateDropdownItem(_currentCategory, oldValue, newValue);
      }
      if (!mounted) return;
      if (result.data['success'] == true) {
        setState(() {
          final list = _data[_currentCategory]!;
          final idx = list.indexOf(oldValue);
          if (idx >= 0) list[idx] = newValue;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Renamed "$oldValue" to "$newValue"'), backgroundColor: const Color(0xFF22C55E)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.data['error'] ?? 'Update failed'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // DELETE
  // ---------------------------------------------------------------------------
  void _showDeleteDialog(String value) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Item'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Delete "$value"?'),
            const SizedBox(height: 8),
            Text(
              'Existing orders referencing this value will not be affected, but it will no longer appear in dropdowns.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _deleteItem(value);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteItem(String value) async {
    try {
      // Workers use a separate API endpoint
      final Response result;
      if (_currentCategory == 'workers') {
        result = await _apiService.deleteWorker(value);
      } else {
        result = await _apiService.deleteDropdownItem(_currentCategory, value);
      }
      if (!mounted) return;
      if (result.data['success'] == true) {
        setState(() {
          _data[_currentCategory]?.remove(value);
        });
        // Invalidate dropdown cache so other screens see the deletion
        context.read<CacheManager>().dropdownCache.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$value" deleted'), backgroundColor: const Color(0xFF22C55E)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Dropdown Management',
      disableInternalScrolling: true,
      content: Column(
        children: [
          // Tab bar
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.8),
              borderRadius: BorderRadius.circular(16),
            ),
            child: TabBar(
              controller: _tabController,
              labelColor: AppTheme.accent,
              unselectedLabelColor: const Color(0xFF94A3B8),
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: AppTheme.accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              tabs: _tabs
                  .map((t) => Tab(
                        icon: Icon(t.icon, size: 20),
                        text: '${t.label} (${_data[t.category]?.length ?? 0})',
                      ))
                  .toList(),
            ),
          ),

          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.white.withOpacity(0.8),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),

          // List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: _tabs.map((_) => _buildItemList()).toList(),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        backgroundColor: const Color(0xFF22C55E),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildItemList() {
    final items = _filteredItems;
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isEmpty ? 'No items' : 'No matching items',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.85),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.withOpacity(0.15)),
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            title: Text(item, style: const TextStyle(fontSize: 14)),
            subtitle: _buildItemSubtitle(item),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF3B82F6)),
                  onPressed: () => _showEditDialog(item),
                  tooltip: 'Edit',
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFEF4444)),
                  onPressed: () => _showDeleteDialog(item),
                  tooltip: 'Delete',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TabInfo {
  final String label;
  final String category;
  final IconData icon;
  const _TabInfo(this.label, this.category, this.icon);
}

/// Holds all state for a single phone number entry (avoids parallel-list sync bugs)
class _PhoneEntry {
  final int key; // unique key for ValueKey to avoid widget reuse issues
  final TextEditingController controller;
  String code;
  bool? verified; // null = unchecked, true = valid, false = invalid
  String? error;
  bool verifying;

  static int _nextKey = 0;

  _PhoneEntry({
    TextEditingController? controller,
    this.code = '91',
    this.verified,
    this.error,
    this.verifying = false,
  })  : key = _nextKey++,
        controller = controller ?? TextEditingController();
}
