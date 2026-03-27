import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/cache_manager.dart';
import '../widgets/app_shell.dart';
import '../theme/app_theme.dart';

class OutstandingPaymentsScreen extends StatefulWidget {
  const OutstandingPaymentsScreen({super.key});

  @override
  State<OutstandingPaymentsScreen> createState() => _OutstandingPaymentsScreenState();
}

class _OutstandingPaymentsScreenState extends State<OutstandingPaymentsScreen> {
  final ApiService _apiService = ApiService();
  final NumberFormat _inrFormat = NumberFormat('#,##,##0', 'en_IN');

  bool _loading = true;
  String? _error;
  String _companyFilter = 'all'; // 'all', 'sygt', 'espl'
  List<Map<String, dynamic>> _companyData = [];
  final Set<String> _selectedClients = {};
  final Set<String> _expandedClients = {};
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // For name mapping
  List<Map<String, dynamic>> _allDbContacts = [];
  String? _contactsLoadError;
  bool _isFromCache = false;
  String _cacheAge = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; });
    final cacheManager = context.read<CacheManager>();

    // 1. Load from cache immediately (show cached data fast)
    try {
      final cached = await cacheManager.outstandingCache.load(ignoreExpiry: true);
      if (cached != null && mounted) {
        _companyData = List<Map<String, dynamic>>.from(cached['data'] ?? []);
        _isFromCache = true;
        _cacheAge = cacheManager.outstandingCache.ageString;
        setState(() { _loading = false; });
      }
    } catch (_) {}

    // 2. Check if server data has changed (lightweight date check)
    bool needsRefresh = true; // Default to full refresh
    try {
      final dateResp = await _apiService.checkOutstandingDates();
      final dates = dateResp.data['dates'] as Map<String, dynamic>? ?? {};
      final cachedData = await cacheManager.outstandingCache.load(ignoreExpiry: true);

      // Compare server dates vs cached dates
      needsRefresh = cachedData == null;
      if (!needsRefresh && cachedData != null) {
        final cachedCompanies = cachedData['data'] as List? ?? [];
        for (final entry in dates.entries) {
          final serverDate = (entry.value as Map?)?['date'];
          if (serverDate == null) continue;
          final match = cachedCompanies.where((c) =>
              (c as Map)['company']?.toString().toLowerCase() == entry.key).firstOrNull;
          if (match == null || (match as Map)['asOnDate'] != serverDate) {
            needsRefresh = true;
            break;
          }
        }
      }
    } catch (_) {
      // Endpoint may not be deployed yet or offline — do full refresh
      needsRefresh = true;
    }

    // 3. Full re-fetch if data changed (or date-check unavailable)
    if (needsRefresh) {
      try {
        final resp = await _apiService.getOutstandingPayments(company: 'all');
        final data = resp.data;
        if (data['success'] == true) {
          _companyData = List<Map<String, dynamic>>.from(data['data'] ?? []);
          _isFromCache = false;
          _cacheAge = '';
          await cacheManager.outstandingCache.save({'data': _companyData});
        } else {
          _error = data['error'] ?? 'Failed to load outstanding data';
        }
      } catch (e) {
        // Offline — use whatever cache we loaded in step 1
        if (_companyData.isEmpty) {
          _error = e.toString();
        }
      }
    }

    // 4. Fetch contacts (independent of outstanding data)
    try {
      final contactsResult = await cacheManager.fetchWithCache<List<dynamic>>(
        apiCall: () async {
          final resp = await _apiService.getAllClientContacts();
          return List<dynamic>.from(resp.data['contacts'] ?? []);
        },
        cache: cacheManager.clientContactsCache,
      );
      _allDbContacts = contactsResult.data.cast<Map<String, dynamic>>();

      // 4b. Refresh matchedContact phones from latest contacts data
      // (handles case where contact phone was updated after outstanding data was cached)
      if (_allDbContacts.isNotEmpty) {
        for (final company in _companyData) {
          for (final client in (company['clients'] as List? ?? [])) {
            final matched = client['matchedContact'] as Map<String, dynamic>?;
            if (matched == null) continue;
            final contactName = (matched['name'] ?? '').toString().toLowerCase();
            final freshContact = _allDbContacts.firstWhere(
              (c) => (c['name'] ?? '').toString().toLowerCase() == contactName,
              orElse: () => <String, dynamic>{},
            );
            if (freshContact.isNotEmpty && freshContact['phones'] != null) {
              matched['phones'] = List<String>.from(freshContact['phones']);
            }
          }
        }
      }
    } catch (e) {
      _contactsLoadError = 'Could not load contacts: $e';
    }
    if (mounted) setState(() { _loading = false; });
  }

  List<Map<String, dynamic>> get _filteredClients {
    final result = <Map<String, dynamic>>[];
    final query = _searchQuery.toLowerCase().trim();
    for (final company in _companyData) {
      final companyKey = (company['company'] ?? '').toString().toLowerCase();
      if (_companyFilter != 'all' && companyKey != _companyFilter) continue;
      for (final client in (company['clients'] ?? [])) {
        if (query.isNotEmpty) {
          final name = (client['sheetName'] ?? '').toString().toLowerCase();
          if (!name.contains(query)) continue;
        }
        result.add({
          ...Map<String, dynamic>.from(client),
          '_company': company['company'],
          '_companyFull': company['companyFull'],
          '_asOnDate': company['asOnDate'],
        });
      }
    }
    result.sort((a, b) => (b['oldestDays'] as int? ?? 0).compareTo(a['oldestDays'] as int? ?? 0));
    return result;
  }

  String _clientKey(Map<String, dynamic> client) =>
      '${client['_company']}||${client['sheetName']}';

  Color _daysColor(int days) {
    if (days <= 20) return const Color(0xFFd0f0c0);
    if (days <= 30) return const Color(0xFFfff9c4);
    return const Color(0xFFffcccc);
  }

  Color _daysBadgeColor(int days) {
    if (days <= 20) return const Color(0xFF4CAF50);
    if (days <= 30) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  String _getAsOnDate() {
    // Collect unique asOnDate values across companies matching current filter
    final dates = <String>{};
    for (final company in _companyData) {
      final companyKey = (company['company'] ?? '').toString().toLowerCase();
      if (_companyFilter != 'all' && companyKey != _companyFilter) continue;
      final d = (company['asOnDate'] ?? '').toString().trim();
      if (d.isNotEmpty) dates.add(d);
    }
    return dates.isEmpty ? '—' : dates.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final clients = _filteredClients;
    final totalOutstanding = clients.fold<double>(0, (sum, c) => sum + (c['totalAmount'] as num? ?? 0));

    return AppShell(
      title: 'Outstanding Payments',
      disableInternalScrolling: true,
      floatingActionButton: _selectedClients.isEmpty ? null : FloatingActionButton.extended(
        onPressed: _sendReminders,
        backgroundColor: AppTheme.steelBlue,
        icon: const Icon(Icons.send_rounded, color: Colors.white),
        label: Text(
          'Send (${_selectedClients.length})',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
      content: Column(
        children: [
          // Company filter tabs
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                _buildFilterChip('All', 'all'),
                const SizedBox(width: 8),
                _buildFilterChip('SYGT', 'sygt'),
                const SizedBox(width: 8),
                _buildFilterChip('ESPL', 'espl'),
                const Spacer(),
                if (!_loading)
                  Text(
                    '${clients.length} clients',
                    style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B), fontWeight: FontWeight.w500),
                  ),
              ],
            ),
          ),
          // As on Date
          if (!_loading && _companyData.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_rounded, size: 14, color: const Color(0xFF64748B)),
                  const SizedBox(width: 6),
                  Text(
                    'As on: ${_getAsOnDate()}',
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF475569)),
                  ),
                ],
              ),
            ),
          // Search bar
          if (!_loading && clients.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search client...',
                  hintStyle: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF94A3B8)),
                  prefixIcon: const Icon(Icons.search_rounded, size: 20, color: Color(0xFF94A3B8)),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            setState(() { _searchQuery = ''; });
                          },
                          child: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF94A3B8)),
                        )
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: const Color(0xFFE2E8F0)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: const Color(0xFFE2E8F0)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: AppTheme.steelBlue, width: 1.5),
                  ),
                ),
                style: GoogleFonts.inter(fontSize: 14),
                onChanged: (v) => setState(() { _searchQuery = v; }),
              ),
            ),
          // Summary bar
          if (!_loading && clients.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.steelBlue.withValues(alpha: 0.08), AppTheme.steelBlue.withValues(alpha: 0.04)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.steelBlue.withValues(alpha: 0.12)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Total Outstanding', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: const Color(0xFF475569))),
                        Text('(>Due Date)', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: const Color(0xFF94A3B8))),
                      ],
                    ),
                    Text(
                      '₹${_inrFormat.format(totalOutstanding)}',
                      style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.steelBlue),
                    ),
                  ],
                ),
              ),
            ),
          // Select all / deselect
          if (!_loading && clients.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        final matchedKeys = clients
                            .where((c) => c['matchedContact'] != null && ((c['matchedContact']['phones'] as List?)?.isNotEmpty ?? false))
                            .map(_clientKey)
                            .toSet();
                        if (_selectedClients.containsAll(matchedKeys)) {
                          _selectedClients.clear();
                        } else {
                          _selectedClients.addAll(matchedKeys);
                        }
                      });
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _selectedClients.isNotEmpty ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                          size: 22,
                          color: AppTheme.steelBlue,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _selectedClients.isNotEmpty ? 'Deselect All' : 'Select All (with phone)',
                          style: GoogleFonts.inter(fontSize: 13, color: AppTheme.steelBlue, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          // Main content
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                            const SizedBox(height: 12),
                            Text(_error!, textAlign: TextAlign.center, style: GoogleFonts.inter(color: Colors.red[700])),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: _loadData,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry'),
                            ),
                          ],
                        ),
                      ))
                    : clients.isEmpty
                        ? Center(child: Text('No outstanding data found', style: GoogleFonts.inter(color: Colors.grey[500])))
                        : RefreshIndicator(
                            onRefresh: _loadData,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                              itemCount: clients.length,
                              itemBuilder: (context, index) => _buildClientCard(clients[index]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final selected = _companyFilter == value;
    return GestureDetector(
      onTap: () {
        if (_companyFilter != value) {
          setState(() { _companyFilter = value; _selectedClients.clear(); });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.steelBlue : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(20),
          border: selected ? null : Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: selected ? Colors.white : const Color(0xFF475569)),
        ),
      ),
    );
  }

  Widget _buildClientCard(Map<String, dynamic> client) {
    final key = _clientKey(client);
    final isSelected = _selectedClients.contains(key);
    final isExpanded = _expandedClients.contains(key);
    final oldestDays = client['oldestDays'] as int? ?? 0;
    final totalAmount = (client['totalAmount'] as num? ?? 0).toDouble();
    final billCount = client['billCount'] as int? ?? 0;
    final matched = client['matchedContact'] as Map<String, dynamic>?;
    final hasPhone = matched != null && ((matched['phones'] as List?)?.isNotEmpty ?? false);
    final companyTag = client['_company']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isSelected ? AppTheme.steelBlue.withValues(alpha: 0.04) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected ? AppTheme.steelBlue.withValues(alpha: 0.4) : const Color(0xFFE0E0E0),
          width: isSelected ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header — checkbox and card expansion are separate gesture areas
          // to prevent the InkWell from swallowing checkbox taps.
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 14, 14, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Checkbox — dedicated tap area for selection
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: hasPhone ? () {
                    setState(() {
                      if (isSelected) {
                        _selectedClients.remove(key);
                      } else {
                        _selectedClients.add(key);
                      }
                    });
                  } : null,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Checkbox(
                        value: isSelected,
                        activeColor: AppTheme.steelBlue,
                        onChanged: hasPhone ? (val) {
                          setState(() {
                            if (val == true) {
                              _selectedClients.add(key);
                            } else {
                              _selectedClients.remove(key);
                            }
                          });
                        } : null,
                      ),
                    ),
                  ),
                ),
                // Client info — tap to expand/collapse
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        if (isExpanded) {
                          _expandedClients.remove(key);
                        } else {
                          _expandedClients.add(key);
                        }
                      });
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Client name + company tag
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                client['sheetName'] ?? '',
                                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: const Color(0xFF1E293B)),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: companyTag == 'SYGT' ? const Color(0xFFEDE9FE) : const Color(0xFFDCFCE7),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                companyTag,
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: companyTag == 'SYGT' ? const Color(0xFF7C3AED) : const Color(0xFF16A34A),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // Amount row — prominent
                        Row(
                          children: [
                            Text(
                              '₹${_inrFormat.format(totalAmount)}',
                              style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w800, color: AppTheme.steelBlue),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: _daysBadgeColor(oldestDays).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: _daysBadgeColor(oldestDays).withValues(alpha: 0.3)),
                              ),
                              child: Text(
                                '${oldestDays}d',
                                style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: _daysBadgeColor(oldestDays)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$billCount bill${billCount != 1 ? 's' : ''}',
                              style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF94A3B8)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // Match status row
                        if (hasPhone)
                          Row(
                            children: [
                              const Icon(Icons.check_circle_rounded, size: 15, color: Color(0xFF22C55E)),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  matched['name'] ?? '',
                                  style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF22C55E), fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          )
                        else
                          GestureDetector(
                            onTap: () => _showNameMappingDialog(client),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF3C7),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFD97706)),
                                  const SizedBox(width: 5),
                                  Text(
                                    'Unmatched — tap to map',
                                    style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFFD97706), fontWeight: FontWeight.w500),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedClients.remove(key);
                      } else {
                        _expandedClients.add(key);
                      }
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Icon(isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: const Color(0xFF94A3B8), size: 24),
                  ),
                ),
              ],
            ),
          ),
          // Expanded bill details
          if (isExpanded) ...[
            Divider(height: 1, color: Colors.grey[200]),
            Container(
              margin: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                children: [
                  // Table header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
                      border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
                    ),
                    child: Row(
                      children: [
                        Expanded(flex: 3, child: Text('Date', style: _tableHeaderStyle)),
                        Expanded(flex: 3, child: Text('Ref', style: _tableHeaderStyle)),
                        Expanded(flex: 3, child: Text('Amount', style: _tableHeaderStyle, textAlign: TextAlign.right)),
                        Expanded(flex: 2, child: Text('Days', style: _tableHeaderStyle, textAlign: TextAlign.center)),
                      ],
                    ),
                  ),
                  ...((client['bills'] as List? ?? []).asMap().entries.map<Widget>((entry) {
                    final bill = entry.value;
                    final isLast = entry.key == (client['bills'] as List).length - 1;
                    final days = bill['days'] as int? ?? 0;
                    final amount = (bill['amount'] as num? ?? 0).toDouble();
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      decoration: BoxDecoration(
                        color: _daysColor(days),
                        borderRadius: isLast ? const BorderRadius.vertical(bottom: Radius.circular(9)) : null,
                        border: isLast ? null : Border(bottom: BorderSide(color: Colors.grey[200]!)),
                      ),
                      child: Row(
                        children: [
                          Expanded(flex: 3, child: Text(bill['date'] ?? '', style: _tableCellStyle)),
                          Expanded(flex: 3, child: Text(bill['ref'] ?? '', style: _tableCellStyle)),
                          Expanded(flex: 3, child: Text('₹${_inrFormat.format(amount)}', style: _tableCellStyle.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
                          Expanded(flex: 2, child: Text('$days', style: _tableCellStyle.copyWith(fontWeight: FontWeight.w700, color: _daysBadgeColor(days)), textAlign: TextAlign.center)),
                        ],
                      ),
                    );
                  })),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  TextStyle get _tableHeaderStyle => GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: const Color(0xFF64748B));
  TextStyle get _tableCellStyle => GoogleFonts.inter(fontSize: 13, color: const Color(0xFF334155));

  // ── Name Mapping Dialog ──────────────────────────────────────────────

  void _showNameMappingDialog(Map<String, dynamic> client) {
    String? selectedContact;
    String searchQuery = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final filtered = _allDbContacts.where((c) {
              final name = (c['name'] ?? '').toString().toLowerCase();
              return searchQuery.isEmpty || name.contains(searchQuery.toLowerCase());
            }).toList();

            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Map Client Name', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
                      child: Row(
                        children: [
                          const Icon(Icons.description, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '${client['sheetName']} (${client['_company']})',
                              style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Search contacts...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onChanged: (v) => setModalState(() { searchQuery = v; }),
                    ),
                    const SizedBox(height: 8),
                    if (_allDbContacts.isEmpty && _contactsLoadError != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.orange[50], borderRadius: BorderRadius.circular(8)),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text('Could not load contacts. Pull down to refresh.', style: GoogleFonts.inter(fontSize: 12, color: Colors.orange[800]))),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) {
                          final contact = filtered[i];
                          final name = contact['name'] ?? '';
                          final phones = List<String>.from(contact['phones'] ?? []);
                          final isSelected = selectedContact == name;
                          return ListTile(
                            dense: true,
                            selected: isSelected,
                            selectedTileColor: AppTheme.steelBlue.withValues(alpha: 0.1),
                            leading: Icon(
                              phones.isNotEmpty ? Icons.phone : Icons.phone_disabled,
                              size: 18,
                              color: phones.isNotEmpty ? const Color(0xFF4CAF50) : Colors.grey,
                            ),
                            title: Text(name, style: GoogleFonts.inter(fontSize: 13, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400)),
                            subtitle: phones.isNotEmpty ? Text(phones.first, style: GoogleFonts.inter(fontSize: 11, color: Colors.grey)) : null,
                            onTap: () => setModalState(() { selectedContact = name; }),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.steelBlue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: selectedContact == null ? null : () async {
                          Navigator.pop(ctx);
                          await _saveMapping(client, selectedContact!);
                        },
                        child: const Text('Save Mapping'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _saveMapping(Map<String, dynamic> client, String firebaseClientName) async {
    // Find the matching DB contact for optimistic local update
    final matchedContact = _allDbContacts.firstWhere(
      (c) => c['name'] == firebaseClientName,
      orElse: () => {'name': firebaseClientName, 'phones': <String>[]},
    );

    // Optimistic update — immediately reflect in UI without full reload
    final sheetName = client['sheetName'];
    final companyKey = (client['_company'] ?? '').toString().toLowerCase();
    setState(() {
      for (final company in _companyData) {
        if ((company['company'] ?? '').toString().toLowerCase() != companyKey) continue;
        for (final c in (company['clients'] ?? [])) {
          if (c['sheetName'] == sheetName) {
            c['matchedContact'] = Map<String, dynamic>.from(matchedContact);
            break;
          }
        }
      }
    });

    // Background save — no full reload
    try {
      await _apiService.saveOutstandingNameMapping(
        sheetName: sheetName,
        company: companyKey,
        firebaseClientName: firebaseClientName,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Mapped "$sheetName" → "$firebaseClientName"'), backgroundColor: const Color(0xFF4CAF50)),
        );
      }
    } catch (e) {
      // Revert optimistic update on failure
      setState(() {
        for (final company in _companyData) {
          if ((company['company'] ?? '').toString().toLowerCase() != companyKey) continue;
          for (final c in (company['clients'] ?? [])) {
            if (c['sheetName'] == sheetName) {
              c['matchedContact'] = null;
              break;
            }
          }
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save mapping: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ── Send Reminders via WhatsApp (backend-powered) ───────────────────

  Future<void> _sendReminders() async {
    final clients = _filteredClients.where((c) => _selectedClients.contains(_clientKey(c))).toList();
    if (clients.isEmpty) return;

    // Confirm
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send Payment Reminders'),
        content: Text('Send outstanding payment images to ${clients.length} client(s) via WhatsApp?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.steelBlue, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Build payload — only the data the backend needs to generate images + send
    final payload = clients.map((c) {
      final matched = c['matchedContact'] as Map<String, dynamic>?;
      final phones = List<String>.from(matched?['phones'] ?? []);
      return {
        'sheetName': c['sheetName'],
        'company': c['_company'],
        'companyFull': c['_companyFull'],
        'asOnDate': c['_asOnDate'],
        'totalAmount': c['totalAmount'],
        'oldestDays': c['oldestDays'],
        'bills': c['bills'],
        'phones': phones,
      };
    }).where((c) => (c['phones'] as List).isNotEmpty).toList();

    if (payload.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No clients with phone numbers to send to'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    // Fire-and-forget: backend generates images + sends WhatsApp
    try {
      await _apiService.sendOutstandingReminders(payload);
      if (mounted) {
        setState(() { _selectedClients.clear(); });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${payload.length} reminders queued — sending in background'),
            backgroundColor: const Color(0xFF4CAF50),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to queue reminders: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

}
