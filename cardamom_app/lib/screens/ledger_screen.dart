import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import 'client_ledger_detail_screen.dart';

class LedgerScreen extends StatefulWidget {
  const LedgerScreen({super.key});

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  List<Map<String, dynamic>> _clients = [];
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getLedgerClients();
      final data = response.data;
      if (data is List) {
        _clients = List<Map<String, dynamic>>.from(data);
      } else {
        _clients = [];
      }
    } catch (e) {
      debugPrint('Error loading ledger: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  List<Map<String, dynamic>> get _filteredClients {
    if (_searchQuery.isEmpty) return _clients;
    final q = _searchQuery.toLowerCase();
    return _clients.where((c) => (c['client'] ?? '').toString().toLowerCase().contains(q)).toList();
  }

  int get _totalOrders => _clients.fold(0, (sum, c) => sum + ((c['totalOrders'] as num?) ?? 0).toInt());
  int get _totalPending => _clients.fold(0, (sum, c) => sum + ((c['pendingOrders'] as num?) ?? 0).toInt());
  double get _totalKgs => _clients.fold(0.0, (sum, c) => sum + ((c['pendingKgs'] as num?) ?? 0).toDouble());

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredClients;

    return AppShell(
      title: 'Ledger',
      disableInternalScrolling: true,
      content: RefreshIndicator(
        onRefresh: _loadData,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                slivers: [
                  // Search bar
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: TextField(
                        decoration: InputDecoration(
                          hintText: 'Search clients...',
                          prefixIcon: const Icon(Icons.search_rounded, size: 20),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear_rounded, size: 18),
                                  onPressed: () => setState(() => _searchQuery = ''),
                                )
                              : null,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onChanged: (val) => setState(() => _searchQuery = val),
                      ),
                    ),
                  ),
                  // Summary chips
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          _buildSummaryChip('${_clients.length}', 'Clients', const Color(0xFF5D6E7E)),
                          const SizedBox(width: 8),
                          _buildSummaryChip('$_totalOrders', 'Orders', const Color(0xFF3B82F6)),
                          const SizedBox(width: 8),
                          _buildSummaryChip('$_totalPending', 'Pending', const Color(0xFFF59E0B)),
                          const SizedBox(width: 8),
                          _buildSummaryChip(_totalKgs.toStringAsFixed(0), 'Kgs', const Color(0xFF10B981)),
                        ],
                      ),
                    ),
                  ),
                  // Client cards
                  filtered.isEmpty
                      ? const SliverFillRemaining(
                          child: Center(child: Text('No clients found.')),
                        )
                      : SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => _buildClientCard(filtered[index]),
                              childCount: filtered.length,
                            ),
                          ),
                        ),
                ],
              ),
      ),
    );
  }

  Widget _buildSummaryChip(String value, String label, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.15)),
        ),
        child: Column(
          children: [
            Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: color.withOpacity(0.7))),
          ],
        ),
      ),
    );
  }

  Widget _buildClientCard(Map<String, dynamic> client) {
    final name = (client['client'] ?? '').toString();
    final totalOrders = ((client['totalOrders'] as num?) ?? 0).toInt();
    final pendingOrders = ((client['pendingOrders'] as num?) ?? 0).toInt();
    final pendingKgs = ((client['pendingKgs'] as num?) ?? 0).toDouble();
    final lastDate = (client['lastOrderDate'] ?? '').toString();

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ClientLedgerDetailScreen(clientName: name)),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 3)),
            BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 2, offset: const Offset(0, 1)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w900, color: AppTheme.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name.toUpperCase(),
                    style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w800, color: const Color(0xFF1E293B), letterSpacing: 0.3),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Color(0xFF94A3B8), size: 20),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildStatBadge('$totalOrders', 'Orders', const Color(0xFF64748B)),
                const SizedBox(width: 8),
                _buildStatBadge('$pendingOrders', 'Pending', pendingOrders > 0 ? const Color(0xFFF59E0B) : const Color(0xFF94A3B8)),
                const SizedBox(width: 8),
                _buildStatBadge('${pendingKgs.toStringAsFixed(0)} kg', 'Qty', const Color(0xFF3B82F6)),
                const Spacer(),
                if (lastDate.isNotEmpty)
                  Text(lastDate, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatBadge(String value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w500, color: color.withOpacity(0.7))),
        ],
      ),
    );
  }
}
