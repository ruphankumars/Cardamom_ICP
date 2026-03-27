import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/analytics_service.dart';
import 'dismissible_bottom_sheet.dart';

/// Client Leaderboard Widget - Phase 3.2
/// Displays top clients with velocity scores, churn risk, and grade affinity
class ClientLeaderboard extends StatelessWidget {
  final List<ClientScore> clients;
  final VoidCallback? onSeeAll;
  final Function(ClientScore)? onClientTap;

  const ClientLeaderboard({
    super.key,
    required this.clients,
    this.onSeeAll,
    this.onClientTap,
  });

  @override
  Widget build(BuildContext context) {
    if (clients.isEmpty) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        _showClientAnalyticsComparison(context);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.all(20),
        constraints: const BoxConstraints(maxHeight: 400),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4A5568), Color(0xFF2D3748)], // Titanium dark
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF5D6E7E).withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF5D6E7E).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.leaderboard_rounded,
                        color: Color(0xFF5D6E7E),
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Top Clients',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF5D6E7E).withOpacity(0.3),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${clients.length}',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Icon(Icons.analytics_rounded, size: 14, color: Colors.white.withOpacity(0.5)),
                    const SizedBox(width: 4),
                    Text(
                      'Compare →',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Scrollable Client list
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: clients.map((client) => _buildClientRow(context, client)).toList(),
                ),
              ),
            ),
            // Summary stats
            const SizedBox(height: 12),
            _buildSummaryRow(clients),
          ],
        ),
      ),
    );
  }

  void _showClientAnalyticsComparison(BuildContext context) {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4A5568), Color(0xFF2D3748)],
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  // Handle
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.grey[700], borderRadius: BorderRadius.circular(2)),
                  ),
                  // Header
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF5D6E7E).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.analytics_rounded, color: Color(0xFF5D6E7E), size: 22),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Client Analytics', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                              Text('Revenue & Volume Comparison', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF334155)),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  // Revenue Comparison Chart (Bar visualization)
                  _buildAnalyticsSection('💰 Revenue by Client', _buildRevenueChart()),
                  const SizedBox(height: 20),
                  // Volume Comparison
                  _buildAnalyticsSection('📦 Order Volume', _buildVolumeChart()),
                  const SizedBox(height: 20),
                  // Full Client List with Details
                  _buildAnalyticsSection('👥 All Clients', _buildFullClientList(context)),
                  const SizedBox(height: 40),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalyticsSection(String title, Widget content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 12),
        content,
      ],
    );
  }

  Widget _buildRevenueChart() {
    final maxValue = clients.map((c) => c.totalValue).reduce((a, b) => a > b ? a : b).toDouble();
    
    return Column(
      children: clients.take(10).map((client) {
        final percentage = maxValue > 0 ? (client.totalValue / maxValue) : 0.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  client.name.length > 10 ? '${client.name.substring(0, 10)}...' : client.name,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xFF334155),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: percentage,
                      child: Container(
                        height: 20,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF4A5568)]),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '₹${_formatValue(client.totalValue)}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildVolumeChart() {
    final maxOrders = clients.map((c) => c.orderCount).reduce((a, b) => a > b ? a : b).toDouble();
    
    return Column(
      children: clients.take(10).map((client) {
        final percentage = maxOrders > 0 ? (client.orderCount / maxOrders) : 0.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  client.name.length > 10 ? '${client.name.substring(0, 10)}...' : client.name,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xFF334155),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: percentage,
                      child: Container(
                        height: 20,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF4A5568)]), // Steel blue to titanium
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${client.orderCount} orders',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFullClientList(BuildContext context) {
    return Column(
      children: clients.map((client) => GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _showClientDetails(context, client);
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF4A5568), Color(0xFF2D3748)], // Titanium dark
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF5D6E7E).withOpacity(0.3)),
          ),
          child: Row(
            children: [
              // Score badge
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: _getScoreGradient(client.velocityScore)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text('${client.velocityScore}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
              const SizedBox(width: 12),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(client.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                    Text('${client.orderCount} orders • ₹${_formatValue(client.totalValue)}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                  ],
                ),
              ),
              // Arrow
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF64748B), size: 20),
            ],
          ),
        ),
      )).toList(),
    );
  }

  void _showClientDetails(BuildContext context, ClientScore client) {
    showDismissibleBottomSheet(
      context: context,
      initialChildSize: 0.5,
      minChildSize: 0.4,
      maxChildSize: 0.85,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4A5568), Color(0xFF2D3748)], // Titanium dark
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  // Handle
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(color: Colors.grey[600], borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Header
                  Row(
                    children: [
                      Container(
                        width: 50, height: 50,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: _getScoreGradient(client.velocityScore)),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: Text('${client.velocityScore}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(client.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                            Text('Velocity Score: ${client.velocityScore}', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Stats Grid
                  Row(
                    children: [
                      _buildDetailStat('Orders', '${client.orderCount}', const Color(0xFF5D6E7E)),
                      const SizedBox(width: 12),
                      _buildDetailStat('Revenue', '₹${_formatValue(client.totalValue)}', const Color(0xFF5D6E7E)),
                      const SizedBox(width: 12),
                      _buildDetailStat('Last Order', '${client.daysSinceLastOrder}d ago', const Color(0xFFF59E0B)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Favorite Grades
                  if (client.topGrades.isNotEmpty) ...[
                    const Text('Top Grades', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: client.topGrades.map((gradeAffinity) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF5D6E7E).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF5D6E7E).withOpacity(0.4)),
                        ),
                        child: Text(gradeAffinity.grade, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E))),
                      )).toList(),
                    ),
                  ],
                  const SizedBox(height: 16),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailStat(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
          ],
        ),
      ),
    );
  }

  Widget _buildClientRow(BuildContext context, ClientScore client) {
    final churnColor = _getChurnColor(client.churnRisk);
    
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onClientTap?.call(client);
        // Always show client details when tapped
        _showClientDetails(context, client);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Colors.white.withOpacity(0.1),
              width: 1,
            ),
          ),
        ),
        child: Row(
          children: [
            // Velocity Score Badge
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _getScoreGradient(client.velocityScore),
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  '${client.velocityScore}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Client Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    client.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '${client.orderCount} orders',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withOpacity(0.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '₹${_formatValue(client.totalValue)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Churn Risk / Days Indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: churnColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                client.churnRisk == 'high'
                    ? '⚠️ At risk'
                    : client.daysSinceLastOrder < 999
                        ? '${client.daysSinceLastOrder}d'
                        : 'New',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: churnColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(List<ClientScore> clients) {
    final highRisk = clients.where((c) => c.churnRisk == 'high').length;
    final mediumRisk = clients.where((c) => c.churnRisk == 'medium').length;
    final totalValue = clients.fold<int>(0, (sum, c) => sum + c.totalValue);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildStat('Total Value', '₹${_formatValue(totalValue)}'),
        _buildStat('At Risk', '$highRisk', color: const Color(0xFFEF4444)),
        _buildStat('Watch', '$mediumRisk', color: const Color(0xFFF59E0B)),
      ],
    );
  }

  Widget _buildStat(String label, String value, {Color? color}) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color ?? Colors.white,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: Colors.white.withOpacity(0.5),
          ),
        ),
      ],
    );
  }

  Color _getChurnColor(String risk) {
    switch (risk) {
      case 'high':
        return const Color(0xFFEF4444);
      case 'medium':
        return const Color(0xFFF59E0B);
      default:
        return const Color(0xFF5D6E7E); // Steel blue instead of green
    }
  }

  List<Color> _getScoreGradient(int score) {
    if (score >= 70) {
      return [const Color(0xFF5D6E7E), const Color(0xFF4A5568)]; // Steel blue to titanium
    } else if (score >= 40) {
      return [const Color(0xFF5D6E7E), const Color(0xFF4A5568)];
    } else {
      return [const Color(0xFF64748B), const Color(0xFF475569)];
    }
  }

  String _formatValue(int value) {
    if (value >= 10000000) {
      return '${(value / 10000000).toStringAsFixed(1)}Cr';
    } else if (value >= 100000) {
      return '${(value / 100000).toStringAsFixed(1)}L';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return value.toString();
  }
}

/// Compact client score chip for inline display
class ClientScoreChip extends StatelessWidget {
  final ClientScore client;
  final VoidCallback? onTap;

  const ClientScoreChip({
    super.key,
    required this.client,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isAtRisk = client.churnRisk == 'high' || client.churnRisk == 'medium';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isAtRisk
              ? const Color(0xFFF59E0B).withOpacity(0.1)
              : const Color(0xFF5D6E7E).withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isAtRisk
                ? const Color(0xFFF59E0B).withOpacity(0.3)
                : const Color(0xFF5D6E7E).withOpacity(0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: isAtRisk
                    ? const Color(0xFFF59E0B)
                    : const Color(0xFF5D6E7E),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '${client.velocityScore}',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              client.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isAtRisk
                    ? const Color(0xFFF59E0B)
                    : const Color(0xFF5D6E7E),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
