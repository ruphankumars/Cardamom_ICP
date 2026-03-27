import 'package:flutter/material.dart';
import '../services/api_service.dart';

class RejectedOffersAnalyticsScreen extends StatefulWidget {
  const RejectedOffersAnalyticsScreen({Key? key}) : super(key: key);

  @override
  State<RejectedOffersAnalyticsScreen> createState() => _RejectedOffersAnalyticsScreenState();
}

class _RejectedOffersAnalyticsScreenState extends State<RejectedOffersAnalyticsScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String _selectedPeriod = '30d';
  Map<String, dynamic> _analytics = {};
  List<Map<String, dynamic>> _rejectedOffers = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final dateFrom = _getDateFrom(_selectedPeriod);
      final results = await Future.wait([
        _apiService.getRejectedOffersAnalytics({'dateFrom': dateFrom}),
        _apiService.getRejectedOffersList({'dateFrom': dateFrom, 'limit': 50}),
      ]);
      if (mounted) {
        setState(() {
          _analytics = results[0] as Map<String, dynamic>? ?? {};
          _rejectedOffers = List<Map<String, dynamic>>.from(results[1] as List? ?? []);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      debugPrint('Analytics load error: $e');
    }
  }

  String _getDateFrom(String period) {
    final now = DateTime.now();
    switch (period) {
      case '7d': return now.subtract(const Duration(days: 7)).toIso8601String();
      case '30d': return now.subtract(const Duration(days: 30)).toIso8601String();
      case '90d': return now.subtract(const Duration(days: 90)).toIso8601String();
      default: return now.subtract(const Duration(days: 30)).toIso8601String();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Text('Rejected Offers Analytics',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE2E8F0)),
        ),
      ),
      body: _isLoading
        ? const Center(child: CircularProgressIndicator(color: Color(0xFF185A9D)))
        : RefreshIndicator(
            onRefresh: _loadData,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Period selector
                  _buildPeriodSelector(),
                  const SizedBox(height: 16),

                  // Summary stats
                  _buildSummaryCards(),
                  const SizedBox(height: 20),

                  // Gap analysis by client
                  _buildClientGapAnalysis(),
                  const SizedBox(height: 20),

                  // Gap analysis by grade
                  _buildGradeGapAnalysis(),
                  const SizedBox(height: 20),

                  // Recent rejected offers list
                  _buildRecentRejections(),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildPeriodSelector() {
    return Row(
      children: ['7d', '30d', '90d'].map((period) {
        final isSelected = _selectedPeriod == period;
        final label = period == '7d' ? '7 Days' : period == '30d' ? '30 Days' : '90 Days';
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label, style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600,
              color: isSelected ? Colors.white : const Color(0xFF64748B),
            )),
            selected: isSelected,
            selectedColor: const Color(0xFF185A9D),
            backgroundColor: Colors.white,
            side: BorderSide(color: isSelected ? Colors.transparent : const Color(0xFFE2E8F0)),
            onSelected: (selected) {
              if (selected) {
                setState(() => _selectedPeriod = period);
                _loadData();
              }
            },
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSummaryCards() {
    final totalRejections = _analytics['rejectionCount'] ?? 0;
    final avgGap = _analytics['overallAvgGap'] ?? 0;
    final uniqueClients = (_analytics['avgGapByClient'] as Map?)?.length ?? 0;

    return Row(
      children: [
        _buildStatCard('Total Rejections', '$totalRejections', const Color(0xFFEF4444), Icons.close_rounded),
        const SizedBox(width: 12),
        _buildStatCard('Avg Price Gap', '\u20B9${(avgGap as num).toStringAsFixed(0)}', const Color(0xFFF59E0B), Icons.trending_down),
        const SizedBox(width: 12),
        _buildStatCard('Unique Clients', '$uniqueClients', const Color(0xFF185A9D), Icons.people_outline),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(height: 10),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          ],
        ),
      ),
    );
  }

  Widget _buildClientGapAnalysis() {
    final clientGaps = (_analytics['avgGapByClient'] as Map?) ?? {};
    if (clientGaps.isEmpty) return const SizedBox.shrink();

    final sortedClients = clientGaps.entries.toList()
      ..sort((a, b) => ((b.value as num?) ?? 0).compareTo((a.value as num?) ?? 0));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Price Gap by Client', style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
          const SizedBox(height: 4),
          const Text('Average gap between admin offer and client counter',
            style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          const SizedBox(height: 16),
          ...sortedClients.take(8).map((entry) {
            final maxGap = sortedClients.first.value as num;
            final gap = entry.value as num;
            final barWidth = maxGap > 0 ? (gap / maxGap) : 0.0;

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(child: Text(entry.key, style: const TextStyle(fontSize: 12, color: Color(0xFF4A5568)), overflow: TextOverflow.ellipsis)),
                      Text('\u20B9${gap.toStringAsFixed(0)}/kg', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFEF4444))),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: barWidth.toDouble(),
                      minHeight: 6,
                      backgroundColor: const Color(0xFFF1F5F9),
                      valueColor: AlwaysStoppedAnimation(
                        barWidth > 0.7 ? const Color(0xFFEF4444)
                          : barWidth > 0.4 ? const Color(0xFFF59E0B)
                          : const Color(0xFF22C55E)
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildGradeGapAnalysis() {
    final gradeGaps = (_analytics['avgGapByGrade'] as Map?) ?? {};
    if (gradeGaps.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Price Gap by Grade', style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: gradeGaps.entries.map((entry) {
              final gap = entry.value as num;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: gap > 200 ? const Color(0xFFFEE2E2)
                    : gap > 100 ? const Color(0xFFFFFBEB)
                    : const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: gap > 200 ? const Color(0xFFEF4444).withOpacity(0.3)
                    : gap > 100 ? const Color(0xFFF59E0B).withOpacity(0.3)
                    : const Color(0xFF22C55E).withOpacity(0.3)),
                ),
                child: Column(
                  children: [
                    Text(entry.key, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF4A5568))),
                    const SizedBox(height: 2),
                    Text('\u20B9${gap.toStringAsFixed(0)}', style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700,
                      color: gap > 200 ? const Color(0xFFEF4444) : gap > 100 ? const Color(0xFFF59E0B) : const Color(0xFF22C55E),
                    )),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentRejections() {
    if (_rejectedOffers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: const Center(
          child: Column(
            children: [
              Icon(Icons.inbox_outlined, size: 40, color: Color(0xFFCBD5E1)),
              SizedBox(height: 8),
              Text('No rejected offers in this period', style: TextStyle(color: Color(0xFF94A3B8))),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Recent Rejections', style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
              Text('${_rejectedOffers.length} total', style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            ],
          ),
          const SizedBox(height: 12),
          ...(_rejectedOffers.take(10).map((offer) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(offer['clientName'] ?? 'Unknown', style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B))),
                    Text(_formatDate(offer['createdAt']),
                      style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                  ],
                ),
                const SizedBox(height: 6),
                if (offer['gapAnalysis'] != null && offer['gapAnalysis']['items'] != null)
                  ...(offer['gapAnalysis']['items'] as List).map((item) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Expanded(child: Text('${item['grade'] ?? ''}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)))),
                        Text('Admin: \u20B9${item['adminRate'] ?? 0}', style: const TextStyle(fontSize: 11, color: Color(0xFF22C55E))),
                        const SizedBox(width: 8),
                        Text('Client: \u20B9${item['clientRate'] ?? 0}', style: const TextStyle(fontSize: 11, color: Color(0xFFEF4444))),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEE2E2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('Gap: \u20B9${item['gap'] ?? 0}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFFEF4444))),
                        ),
                      ],
                    ),
                  )),
                if (offer['rejectionReason'] != null && offer['rejectionReason'].toString().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Reason: ${offer['rejectionReason']}',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontStyle: FontStyle.italic)),
                  ),
              ],
            ),
          ))),
        ],
      ),
    );
  }

  String _formatDate(dynamic dateValue) {
    if (dateValue == null) return '';
    final str = dateValue.toString();
    if (str.length >= 10) return str.substring(0, 10);
    return str;
  }
}
