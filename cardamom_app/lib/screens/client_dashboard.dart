import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/navigation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

class ClientDashboard extends StatefulWidget {
  const ClientDashboard({super.key});

  @override
  State<ClientDashboard> createState() => _ClientDashboardState();
}

class _ClientDashboardState extends State<ClientDashboard> with RouteAware {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<dynamic> _requests = [];

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() => _loadRequests();

  Future<void> _loadRequests() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getMyRequests();
      if (!mounted) return;
      setState(() {
        _requests = response.data['requests'] ?? [];
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading client requests: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      disableInternalScrolling: true,
      title: 'Client Dashboard',
      subtitle: 'View and manage your order requests',
      topActions: [
        ElevatedButton(
          onPressed: _loadRequests,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Refresh'),
        ),
      ],
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            _buildStatsRow(),
            const SizedBox(height: 16),
            Expanded(child: _buildRequestsSection()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        return ClipRRect(
          borderRadius: BorderRadius.circular(isMobile ? 16 : 24),
          child: Container(
            decoration: AppTheme.glassDecoration,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Padding(
                padding: EdgeInsets.all(isMobile ? 12 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Client Dashboard', style: TextStyle(fontSize: isMobile ? 20 : 28, fontWeight: FontWeight.bold, color: const Color(0xFF4A5568))),
                    Text('Manage your order requests', style: TextStyle(fontSize: isMobile ? 12 : 14, color: const Color(0xFF6B7280))),
                    SizedBox(height: isMobile ? 12 : 20),
                    Wrap(
                      spacing: isMobile ? 8 : 12,
                      runSpacing: isMobile ? 8 : 12,
                      children: [
                        _buildActionButton(
                          label: isMobile ? '➕ Order' : '➕ Create Order Request',
                          onPressed: () => Navigator.pushNamed(context, '/create_request', arguments: {'type': 'REQUEST_ORDER'}).then((_) => _loadRequests()),
                          color: const Color(0xFF5D6E7E),
                          isMobile: isMobile,
                        ),
                        _buildActionButton(
                          label: isMobile ? '💰 Enquiry' : '💰 Create Price Enquiry',
                          onPressed: () => Navigator.pushNamed(context, '/create_request', arguments: {'type': 'ENQUIRE_PRICE'}).then((_) => _loadRequests()),
                          color: const Color(0xFF4A5568),
                          isMobile: isMobile,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionButton({required String label, required VoidCallback onPressed, required Color color, bool isMobile = false}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(isMobile ? 10 : 12)),
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 10 : 12),
        elevation: 4,
        shadowColor: color.withOpacity(0.5),
      ),
      child: Text(label, style: TextStyle(fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildStatsRow() {
    final total = _requests.length;
    final confirmed = _requests.where((r) => r['status'] == 'CONFIRMED' || r['status'] == 'CONVERTED_TO_ORDER').length;
    final open = _requests.where((r) => r['status'] == 'OPEN').length;
    final negotiating = _requests.where((r) => 
      r['status'] == 'ADMIN_SENT' || 
      r['status'] == 'CLIENT_DRAFT' || 
      r['status'] == 'CLIENT_SENT'
    ).length;

    return Row(
      children: [
        Expanded(child: _StatMini(label: 'Total Requests', value: '$total', color: AppTheme.primary)),
        const SizedBox(width: 12),
        Expanded(child: _StatMini(label: 'Open', value: '$open', color: Colors.blue)),
        const SizedBox(width: 12),
        Expanded(child: _StatMini(label: 'Negotiating', value: '$negotiating', color: Colors.purple)),
        const SizedBox(width: 12),
        Expanded(child: _StatMini(label: 'Confirmed', value: '$confirmed', color: Colors.green)),
      ],
    );
  }

  Widget _buildRequestsSection() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: double.infinity,
        decoration: AppTheme.glassDecoration,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('My Order Requests', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                const SizedBox(height: 16),
                if (_isLoading)
                  const Center(child: CircularProgressIndicator())
                else if (_requests.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(48),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('No requests found.', style: TextStyle(color: Color(0xFF6B7280), fontSize: 16, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 8),
                          const Text('Create your first order request to get started!', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                        ],
                      ),
                    )
                  )
                else
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        if (constraints.maxWidth < 900) {
                          return ListView.builder(
                            physics: const BouncingScrollPhysics(),
                            itemCount: _requests.length,
                            itemBuilder: (context, idx) {
                              final req = _requests[idx];
                              return _buildRequestCard(req);
                            },
                          );
                        } else {
                          return _buildDesktopTable();
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopTable() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTableHeader(),
        const Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _requests.length,
          separatorBuilder: (context, index) => const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
          itemBuilder: (context, idx) {
            final req = _requests[idx];
            return _buildTableRow(req);
          },
        ),
      ],
    );
  }

  Widget _buildTableHeader() {
    const headerStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        children: const [
          Expanded(flex: 2, child: Text('Request ID', style: headerStyle)),
          Expanded(flex: 1, child: Text('Type', style: headerStyle)),
          Expanded(flex: 1, child: Text('Status', style: headerStyle)),
          Expanded(flex: 1, child: Text('Items', style: headerStyle)),
          Expanded(flex: 1, child: Text('Created', style: headerStyle)),
          Expanded(flex: 1, child: Text('Updated', style: headerStyle)),
          Expanded(flex: 1, child: Text('Actions', style: headerStyle)),
        ],
      ),
    );
  }

  Widget _buildTableRow(dynamic req) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/negotiation', arguments: {'id': req['requestId']}),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                'REQ-${req['requestId'].toString().split('-').last}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF5D6E7E), decoration: TextDecoration.underline),
              ),
            ),
            Expanded(
              flex: 1,
              child: Row(
                children: [
                   Icon(req['requestType'] == 'ENQUIRE_PRICE' ? Icons.currency_rupee : Icons.inventory_2, size: 14, color: AppTheme.muted),
                   const SizedBox(width: 4),
                   Text(req['requestType'] == 'ENQUIRE_PRICE' ? 'Enquiry' : 'Order', style: const TextStyle(fontSize: 13, color: Color(0xFF4A5568))),
                ],
              ),
            ),
            Expanded(
              flex: 1,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _StatusBadge(status: req['status']),
              ),
            ),
            Expanded(
              flex: 1,
              child: Text('${((req['requestedItems'] as List?) ?? []).length} item(s)', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            ),
            Expanded(
              flex: 1,
              child: Text(_formatDate(req['createdAt']), style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            ),
            Expanded(
              flex: 1,
              child: Text(_formatDate(req['updatedAt']), style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            ),
            Expanded(
              flex: 1,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.chat_bubble_outline, size: 12, color: Color(0xFF64748B)),
                        SizedBox(width: 6),
                        Text('View', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(dynamic dateStr) {
    if (dateStr == null) return '—';
    try {
      final raw = dateStr.toString();
      // Handle dd/MM/yy order dates
      if (raw.contains('/')) return raw;
      // Handle ISO timestamps
      final date = DateTime.parse(raw);
      return DateFormat('dd/MM/yy').format(date);
    } catch (e) {
      return dateStr.toString().split('T')[0];
    }
  }

  Widget _buildRequestCard(dynamic req) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.pushNamed(context, '/negotiation', arguments: {'id': req['requestId']}),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '#${req['requestId'].toString().split('-').last}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    _StatusBadge(status: req['status']),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(req['requestType'] == 'ENQUIRE_PRICE' ? '💰 Enquiry' : '📦 Order', 
                         style: TextStyle(color: AppTheme.muted, fontSize: 13)),
                    const SizedBox(width: 8),
                    Container(width: 4, height: 4, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.grey)),
                    const SizedBox(width: 8),
                    Text('${((req['requestedItems'] as List?) ?? []).length} item(s)', 
                         style: TextStyle(color: AppTheme.muted, fontSize: 13)),
                  ],
                ),
                const Divider(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Updated', style: TextStyle(color: Colors.grey, fontSize: 10)),
                        Text(_formatDate(req['updatedAt']), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                      ],
                    ),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatMini extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatMini({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status.toUpperCase()) {
      case 'OPEN': color = const Color(0xFF5D6E7E); break; // Blue
      case 'ADMIN_SENT': color = const Color(0xFF4A5568); break; // Purple
      case 'CLIENT_DRAFT': color = const Color(0xFF64748B); break; // Slate
      case 'CLIENT_SENT': color = const Color(0xFFF59E0B); break; // Amber
      case 'CONFIRMED': color = const Color(0xFF10B981); break; // Green
      case 'CANCELLED': color = const Color(0xFFEF4444); break; // Red
      case 'REJECTED': color = const Color(0xFF7F1D1D); break; // Maroon
      default: color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}
