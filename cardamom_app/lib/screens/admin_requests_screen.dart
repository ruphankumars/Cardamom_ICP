import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/navigation_service.dart';
import '../mixins/pagination_mixin.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

class AdminRequestsScreen extends StatefulWidget {
  const AdminRequestsScreen({super.key});

  @override
  State<AdminRequestsScreen> createState() => _AdminRequestsScreenState();
}

class _AdminRequestsScreenState extends State<AdminRequestsScreen>
    with PaginationMixin, RouteAware {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _requests = [];
  Map<String, dynamic> _filters = {
    'status': '',
    'type': '',
    'client': '',
  };
  Timer? _pollTimer;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadRequests();
    _startPolling();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _pollTimer?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  void didPopNext() => _loadRequests(silent: true);

  void _startPolling() {
    // Only poll when on the first page to avoid interfering with paginated data
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (paginationInfo.cursor == null) {
        _loadRequests(silent: true);
      }
    });
  }

  Future<void> _loadRequests({bool silent = false}) async {
    if (!silent) {
      paginationInfo.reset();
      setState(() {
        _isLoading = true;
        _requests = [];
      });
    }
    await loadNextPage();
  }

  @override
  Future<void> loadNextPage() async {
    try {
      // Build clean filter params (exclude empty strings)
      final cleanFilters = <String, dynamic>{};
      _filters.forEach((key, value) {
        if (value != null && value.toString().isNotEmpty) {
          cleanFilters[key] = value;
        }
      });

      final response = await _apiService.getAllRequestsPaginated(
        limit: paginationInfo.limit,
        cursor: paginationInfo.cursor,
        filters: cleanFilters.isNotEmpty ? cleanFilters : null,
      );
      if (mounted) {
        final data = response.data as Map<String, dynamic>;
        final newRequests = (data['requests'] as List?) ?? [];
        final pagination = data['pagination'] as Map<String, dynamic>? ?? {};
        setState(() {
          // On first page silent poll, replace data; otherwise append
          if (paginationInfo.cursor == null && _requests.isEmpty) {
            _requests = newRequests;
          } else {
            _requests.addAll(newRequests);
          }
          paginationInfo.cursor = pagination['cursor'] as String?;
          paginationInfo.hasMore = pagination['hasMore'] as bool? ?? false;
          paginationInfo.isLoadingMore = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading requests: $e');
      if (mounted) {
        setState(() {
          paginationInfo.isLoadingMore = false;
          _isLoading = false;
        });
      }
    }
  }

  void _applyFilters() {
    _loadRequests();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: onScrollNotification,
      child: AppShell(
        title: 'Order Requests',
        subtitle: 'Manage client order requests and price enquiries',
        topActions: [
          ElevatedButton.icon(
            onPressed: _loadRequests,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
        content: LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = constraints.maxWidth < 600;
            return Padding(
              padding: EdgeInsets.all(isMobile ? 16.0 : 24.0),
              child: SizedBox(
                width: constraints.maxWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildFiltersCard(isMobile),
                    SizedBox(height: isMobile ? 16 : 24),
                    _buildStatsRow(isMobile),
                    SizedBox(height: isMobile ? 16 : 24),
                    _buildRequestsTable(isMobile),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFiltersCard(bool isMobile) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withOpacity(0.04),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF1E293B).withOpacity(0.08)),
      ),
      padding: EdgeInsets.all(isMobile ? 12 : 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildFilterDropdown(
                  label: 'Status',
                  value: _filters['status'],
                  items: const [
                    {'label': 'All Status', 'value': ''},
                    {'label': 'Open', 'value': 'OPEN'},
                    {'label': 'Admin Sent', 'value': 'ADMIN_SENT'},
                    {'label': 'Client Sent', 'value': 'CLIENT_SENT'},
                    {'label': 'Confirmed', 'value': 'CONFIRMED'},
                    {'label': 'Cancelled', 'value': 'CANCELLED'},
                    {'label': 'Admin Draft', 'value': 'ADMIN_DRAFT'},
                  ],
                  onChanged: (val) {
                    setState(() => _filters['status'] = val);
                    _applyFilters();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildFilterDropdown(
                  label: 'Type',
                  value: _filters['type'],
                  items: const [
                    {'label': 'All Types', 'value': ''},
                    {'label': 'Order Request', 'value': 'REQUEST_ORDER'},
                    {'label': 'Price Enquiry', 'value': 'ENQUIRE_PRICE'},
                  ],
                  onChanged: (val) {
                    setState(() => _filters['type'] = val);
                    _applyFilters();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSearchField(),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Client Search', style: TextStyle(fontSize: 12, color: AppTheme.muted, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        TextField(
          onChanged: (val) {
            setState(() => _filters['client'] = val);
            _debounceTimer?.cancel();
            _debounceTimer = Timer(const Duration(milliseconds: 400), () {
              _applyFilters();
            });
          },
          decoration: InputDecoration(
            hintText: 'Search by client...',
            prefixIcon: const Icon(Icons.search, size: 18),
            filled: true,
            fillColor: Colors.white.withOpacity(0.5),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterDropdown({
    required String label,
    required String value,
    required List<Map<String, String>> items,
    required Function(String) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.muted, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              style: const TextStyle(fontSize: 14, color: Color(0xFF0F172A)),
              dropdownColor: AppTheme.bluishWhite,
              menuMaxHeight: 350,
              items: items.map((e) => DropdownMenuItem(value: e['value']!, child: Text(e['label']!))).toList(),
              onChanged: (val) => onChanged(val!),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsRow(bool isMobile) {
    final total = _requests.length;
    final negotiating = _requests.where((r) =>
      r['status'] == 'ADMIN_SENT' ||
      r['status'] == 'CLIENT_DRAFT' ||
      r['status'] == 'CLIENT_SENT' ||
      r['status'] == 'ADMIN_DRAFT'
    ).length;
    final confirmed = _requests.where((r) => r['status'] == 'CONFIRMED').length;
    final converted = _requests.where((r) => r['status'] == 'CONVERTED_TO_ORDER').length;

    if (isMobile) {
      return GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.6,
        children: [
          _StatMini(label: 'Total', value: '$total', isMobile: true),
          _StatMini(label: 'Open', value: '${_requests.where((r) => r['status'] == 'OPEN').length}', isMobile: true),
          _StatMini(label: 'Negotiating', value: '$negotiating', isMobile: true),
          _StatMini(label: 'Agreed', value: '${confirmed + converted}', isMobile: true),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final double spacing = 16;
        final double itemWidth = (constraints.maxWidth - (spacing * 3)) / 4;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            _StatMini(label: 'Total Requests', value: '$total', width: itemWidth),
            _StatMini(label: 'Open', value: '${_requests.where((r) => r['status'] == 'OPEN').length}', width: itemWidth),
            _StatMini(label: 'Negotiating', value: '$negotiating', width: itemWidth),
            _StatMini(label: 'Agreed', value: '${confirmed + converted}', width: itemWidth),
          ],
        );
      }
    );
  }

  Widget _buildRequestsTable(bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'All Enquiries & Requests',
            style: TextStyle(fontSize: isMobile ? 16 : 18, fontWeight: FontWeight.bold, color: AppTheme.title)
          ),
        ),
        SizedBox(height: isMobile ? 12 : 16),
        if (_isLoading)
          const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
        else if (_requests.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(40), child: Text('No requests found matching filters.', style: TextStyle(color: Color(0xFF6B7280)))))
        else ...[
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _requests.length,
            itemBuilder: (context, index) {
              final req = _requests[index];
              return _buildRequestCard(req, isMobile);
            },
          ),
          buildPaginationFooter(),
        ],
      ],
    );
  }

  Widget _buildRequestCard(Map<String, dynamic> req, bool isMobile) {
    final status = req['status']?.toString() ?? 'OPEN';
    final type = req['requestType']?.toString() ?? 'REQUEST_ORDER';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: InkWell(
        onTap: () => Navigator.pushNamed(context, '/negotiation', arguments: {'id': req['requestId']}),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          req['requestId'] ?? 'REQ-000',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E293B), letterSpacing: -0.5),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          req['clientName'] ?? 'Unknown Client',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  _buildStatusBadge(status, isMobile),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildTypeBadge(type, isMobile),
                  _buildPanelPreview(req, isMobile),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded, size: 14, color: Color(0xFF94A3B8)),
                      const SizedBox(width: 6),
                      Text(
                        _formatDate(req['createdAt']),
                        style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  _buildRequestActionBtn(req, isMobile),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRequestActionBtn(Map<String, dynamic> req, bool isMobile) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/negotiation', arguments: {'id': req['requestId']}),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF3B82F6).withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.12)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 16, color: Color(0xFF3B82F6)),
            SizedBox(width: 8),
            Text('CHAT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF3B82F6))),
          ],
        ),
      ),
    );
  }

  String _formatDate(dynamic dateStr) {
    if (dateStr == null) return '\u2014';
    try {
      final raw = dateStr.toString();
      // Handle dd/MM/yy order dates
      if (raw.contains('/')) return raw;
      // Handle ISO timestamps
      final date = DateTime.parse(raw);
      final d = date.day.toString().padLeft(2, '0');
      final m = date.month.toString().padLeft(2, '0');
      final y = date.year.toString().substring(2);
      return '$d/$m/$y';
    } catch (e) {
      return dateStr.toString().split('T')[0];
    }
  }

  Widget _buildTypeBadge(String type, bool isMobile) {
    final isEnquiry = type == 'ENQUIRE_PRICE';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 10, vertical: 4),
      decoration: BoxDecoration(
        color: isEnquiry ? Colors.purple.withOpacity(0.1) : Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        isEnquiry ? 'Enquiry' : 'Order',
        style: TextStyle(color: isEnquiry ? Colors.purple : Colors.blue, fontSize: isMobile ? 10 : 11, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildStatusBadge(String status, bool isMobile) {
    Color color;
    switch (status.toUpperCase()) {
      case 'OPEN': color = const Color(0xFF5D6E7E); break;
      case 'ADMIN_SENT': color = const Color(0xFFF97316); break;
      case 'CLIENT_DRAFT': color = const Color(0xFFEAB308); break;
      case 'CLIENT_SENT': color = const Color(0xFFA855F7); break;
      case 'CONFIRMED': color = const Color(0xFF10B981); break;
      case 'CANCELLED': color = const Color(0xFFEF4444); break;
      case 'REJECTED': color = const Color(0xFFEF4444); break;
      case 'CONVERTED_TO_ORDER': color = const Color(0xFF64748B); break;
      case 'ADMIN_DRAFT': color = const Color(0xFF5D6E7E); break;
      default: color = Colors.grey;
    }
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: TextStyle(color: color, fontSize: isMobile ? 10 : 11, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildPanelPreview(Map<String, dynamic> req, bool isMobile) {
    final panelVersion = req['panelVersion'] ?? 1;
    final currentItems = (req['currentItems'] as List?) ?? (req['requestedItems'] as List?) ?? [];
    final offered = currentItems.where((i) => (i['status'] ?? '').toUpperCase() != 'DECLINED').length;
    final total = currentItems.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFF5D6E7E).withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'v$panelVersion',
            style: TextStyle(fontSize: isMobile ? 9 : 10, fontWeight: FontWeight.bold, color: const Color(0xFF5D6E7E)),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$offered/$total items',
          style: TextStyle(fontSize: isMobile ? 10 : 11, color: const Color(0xFF64748B)),
        ),
      ],
    );
  }
}

class _StatMini extends StatelessWidget {
  final String label;
  final String value;
  final double? width;
  final bool isMobile;
  const _StatMini({required this.label, required this.value, this.width, this.isMobile = false});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(isMobile ? 12 : 16),
      child: Container(
        width: width,
        decoration: AppTheme.glassDecoration.copyWith(
          borderRadius: BorderRadius.circular(isMobile ? 12 : 16),
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Padding(
            padding: EdgeInsets.all(isMobile ? 10 : 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: isMobile ? 10 : 12, color: const Color(0xFF6B7280), fontWeight: FontWeight.bold)
                ),
                SizedBox(height: isMobile ? 2 : 4),
                Text(value, style: TextStyle(fontSize: isMobile ? 20 : 24, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
