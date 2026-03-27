import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_service.dart';

class WebClientDashboard extends StatefulWidget {
  const WebClientDashboard({super.key});

  @override
  State<WebClientDashboard> createState() => _WebClientDashboardState();
}

class _WebClientDashboardState extends State<WebClientDashboard> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _cardRadius = 12.0;

  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;
  List<dynamic> _requests = [];
  String _clientName = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      _clientName = prefs.getString('clientName') ?? prefs.getString('username') ?? '';
      final response = await _apiService.getMyRequests();
      if (!mounted) return;
      setState(() {
        _requests = response.data['requests'] ?? [];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load requests: $e';
        _isLoading = false;
      });
    }
  }

  // --- Stats ---
  int get _totalRequests => _requests.length;
  int get _pendingRequests => _requests.where((r) =>
      r['status'] == 'OPEN' ||
      r['status'] == 'ADMIN_SENT' ||
      r['status'] == 'CLIENT_DRAFT' ||
      r['status'] == 'CLIENT_SENT').length;
  int get _approvedRequests => _requests.where((r) =>
      r['status'] == 'CONFIRMED' || r['status'] == 'CONVERTED_TO_ORDER').length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : _error != null
              ? _buildError()
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildGreeting(),
                        const SizedBox(height: 28),
                        _buildStatCards(),
                        const SizedBox(height: 28),
                        _buildActionButtons(),
                        const SizedBox(height: 28),
                        _buildRecentRequestsTable(),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
          const SizedBox(height: 16),
          Text(_error!, style: GoogleFonts.inter(fontSize: 14, color: Colors.red.shade700)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Retry', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_cardRadius)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGreeting() {
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$greeting${_clientName.isNotEmpty ? ', $_clientName' : ''}',
          style: GoogleFonts.manrope(fontSize: 26, fontWeight: FontWeight.w800, color: const Color(0xFF1A1A2E)),
        ),
        const SizedBox(height: 4),
        Text(
          'Manage your order requests and enquiries',
          style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280)),
        ),
      ],
    );
  }

  Widget _buildStatCards() {
    return Row(
      children: [
        Expanded(child: _StatCard(label: 'Total Requests', value: '$_totalRequests', icon: Icons.list_alt, color: _primary)),
        const SizedBox(width: 16),
        Expanded(child: _StatCard(label: 'Pending', value: '$_pendingRequests', icon: Icons.hourglass_top, color: const Color(0xFFF59E0B))),
        const SizedBox(width: 16),
        Expanded(child: _StatCard(label: 'Approved', value: '$_approvedRequests', icon: Icons.check_circle_outline, color: const Color(0xFF10B981))),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        _ActionButton(
          label: 'Create Order Request',
          icon: Icons.add_shopping_cart,
          onPressed: () => Navigator.pushNamed(context, '/create_request', arguments: {'type': 'REQUEST_ORDER'}).then((_) => _loadData()),
        ),
        const SizedBox(width: 12),
        _ActionButton(
          label: 'Create Price Enquiry',
          icon: Icons.currency_rupee,
          isPrimary: false,
          onPressed: () => Navigator.pushNamed(context, '/create_request', arguments: {'type': 'ENQUIRE_PRICE'}).then((_) => _loadData()),
        ),
        const Spacer(),
        IconButton(
          onPressed: _loadData,
          icon: const Icon(Icons.refresh, color: _primary),
          tooltip: 'Refresh',
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_cardRadius),
              side: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecentRequestsTable() {
    final recent = _requests.take(10).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                Text(
                  'Recent Requests',
                  style: GoogleFonts.manrope(fontSize: 17, fontWeight: FontWeight.w700, color: const Color(0xFF1A1A2E)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${_requests.length}', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _primary)),
                ),
                const Spacer(),
                if (_requests.length > 10)
                  TextButton(
                    onPressed: () => Navigator.pushNamed(context, '/my_requests'),
                    child: Text('View All', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _primary)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.all(48),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.inbox_rounded, size: 48, color: Colors.grey.shade300),
                    const SizedBox(height: 12),
                    Text('No requests yet', style: GoogleFonts.inter(fontSize: 15, color: const Color(0xFF6B7280))),
                    const SizedBox(height: 4),
                    Text('Create your first order request to get started', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8))),
                  ],
                ),
              ),
            )
          else
            _buildDataTable(recent),
        ],
      ),
    );
  }

  Widget _buildDataTable(List<dynamic> data) {
    const headerStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280));
    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: const [
              Expanded(flex: 2, child: Text('Request ID', style: headerStyle)),
              Expanded(flex: 2, child: Text('Type', style: headerStyle)),
              Expanded(flex: 2, child: Text('Status', style: headerStyle)),
              Expanded(flex: 1, child: Text('Items', style: headerStyle)),
              Expanded(flex: 2, child: Text('Created', style: headerStyle)),
              Expanded(flex: 1, child: Text('', style: headerStyle)),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF1F5F9)),
        // Rows
        ...data.map((req) => _buildRow(req)),
      ],
    );
  }

  Widget _buildRow(dynamic req) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/negotiation', arguments: {'id': req['requestId']}),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                'REQ-${(req['requestId'] ?? '').toString().split('-').last}',
                style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _primary, decoration: TextDecoration.underline),
              ),
            ),
            Expanded(
              flex: 2,
              child: Row(
                children: [
                  Icon(
                    req['requestType'] == 'ENQUIRE_PRICE' ? Icons.currency_rupee : Icons.inventory_2,
                    size: 14,
                    color: const Color(0xFF6B7280),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    req['requestType'] == 'ENQUIRE_PRICE' ? 'Price Enquiry' : 'Order Request',
                    style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF4A5568)),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(alignment: Alignment.centerLeft, child: _StatusBadge(status: req['status'] ?? 'OPEN')),
            ),
            Expanded(
              flex: 1,
              child: Text(
                '${((req['requestedItems'] as List?) ?? []).length}',
                style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B)),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                _formatDate(req['createdAt']),
                style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B)),
              ),
            ),
            Expanded(
              flex: 1,
              child: Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(dynamic dateStr) {
    if (dateStr == null) return '--';
    try {
      final raw = dateStr.toString();
      if (raw.contains('/')) return raw;
      final date = DateTime.parse(raw);
      return DateFormat('dd MMM yyyy').format(date);
    } catch (_) {
      return dateStr.toString().split('T').first;
    }
  }
}

// --- Reusable Private Widgets ---

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: GoogleFonts.manrope(fontSize: 28, fontWeight: FontWeight.w800, color: color)),
              const SizedBox(height: 2),
              Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, color: const Color(0xFF6B7280))),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool isPrimary;

  const _ActionButton({required this.label, required this.icon, required this.onPressed, this.isPrimary = true});

  static const _primary = Color(0xFF5D6E7E);

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600)),
      style: ElevatedButton.styleFrom(
        backgroundColor: isPrimary ? _primary : Colors.white,
        foregroundColor: isPrimary ? Colors.white : _primary,
        elevation: 0,
        side: isPrimary ? null : const BorderSide(color: Color(0xFFE5E7EB)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = switch (status.toUpperCase()) {
      'OPEN' => (const Color(0xFF3B82F6), 'Open'),
      'ADMIN_SENT' => (const Color(0xFFF97316), 'Admin Sent'),
      'CLIENT_DRAFT' => (const Color(0xFFEAB308), 'Draft'),
      'CLIENT_SENT' => (const Color(0xFFA855F7), 'Client Sent'),
      'CONFIRMED' => (const Color(0xFF10B981), 'Confirmed'),
      'CONVERTED_TO_ORDER' => (const Color(0xFF6B7280), 'Converted'),
      'CANCELLED' => (const Color(0xFFEF4444), 'Cancelled'),
      'REJECTED' => (const Color(0xFF7F1D1D), 'Rejected'),
      _ => (Colors.grey, status.replaceAll('_', ' ')),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
