import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../services/ai_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/ai_briefing_card.dart';
import '../widgets/ai_fab.dart';
import '../widgets/ai_search_bar.dart';

/// Full-screen AI overlay with two tabs: Briefing and Insights.
///
/// Briefing tab shows the daily backend-generated business briefing.
/// Insights tab lets users search for grade/client analysis and view
/// proactive recommendations from the backend analytics engine.
class AiOverlayScreen extends StatefulWidget {
  const AiOverlayScreen({super.key});

  @override
  State<AiOverlayScreen> createState() => _AiOverlayScreenState();
}

class _AiOverlayScreenState extends State<AiOverlayScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // Insights tab state
  GradeAnalysis? _gradeAnalysis;
  ClientAnalysis? _clientAnalysis;
  InsightsResult? _insights;
  bool _insightsLoading = false;
  String? _insightsError;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    AiFab.isOverlayOpen.value = true;
    _tabController = TabController(length: 2, vsync: this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ai = context.read<AiProvider>();
      ai.ensureInitialized();
      // Pre-fetch insights for the Insights tab
      _fetchInsights();
    });
  }

  @override
  void dispose() {
    AiFab.isOverlayOpen.value = false;
    _tabController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data fetching
  // ---------------------------------------------------------------------------

  Future<void> _fetchInsights() async {
    if (!mounted) return;
    final ai = context.read<AiProvider>();
    setState(() {
      _insightsLoading = true;
      _insightsError = null;
    });
    try {
      _insights = await ai.fetchInsights();
    } catch (e) {
      if (!mounted) return;
      _insightsError = e.toString();
    }
    if (mounted) setState(() => _insightsLoading = false);
  }

  Future<void> _onInsightsSearch(String query) async {
    if (query.isEmpty || !mounted) return;
    final ai = context.read<AiProvider>();
    setState(() {
      _lastQuery = query;
      _gradeAnalysis = null;
      _clientAnalysis = null;
      _insightsError = null;
      _insightsLoading = true;
    });

    try {
      // Try grade analysis first (grades are usually short uppercase strings)
      final gradeResult = await ai.fetchGradeAnalysis(query);
      if (!mounted) return;
      if (gradeResult.success && gradeResult.grade != null) {
        setState(() {
          _gradeAnalysis = gradeResult;
          _insightsLoading = false;
        });
        return;
      }

      // Fall back to client analysis
      final clientResult = await ai.fetchClientAnalysis(query);
      if (!mounted) return;
      if (clientResult.success && clientResult.client != null) {
        setState(() {
          _clientAnalysis = clientResult;
          _insightsLoading = false;
        });
        return;
      }

      // Neither matched
      setState(() {
        _insightsError = 'No results found for "$query". Try a grade name (e.g. AGEB) or client name.';
        _insightsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _insightsError = 'Search failed. Please try again.';
        _insightsLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.titaniumLight,
      appBar: AppBar(
        backgroundColor: AppTheme.titaniumLight,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          color: AppTheme.title,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'AI Assistant',
          style: GoogleFonts.outfit(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: AppTheme.title,
          ),
        ),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.muted,
          indicatorColor: AppTheme.secondary,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 14),
          unselectedLabelStyle: GoogleFonts.outfit(fontWeight: FontWeight.w500, fontSize: 14),
          tabs: const [
            Tab(text: 'Briefing'),
            Tab(text: 'Insights'),
          ],
        ),
      ),
      body: Consumer<AiProvider>(
        builder: (context, ai, _) {
          // Loading state
          if (ai.status == AiStatus.loading && !ai.hasBriefing) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text('Loading AI...', style: GoogleFonts.inter(fontSize: 14, color: AppTheme.muted)),
                ],
              ),
            );
          }

          // Error state with retry
          if (ai.status == AiStatus.error && !ai.hasBriefing) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: AppTheme.danger),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      ai.errorMessage ?? 'AI initialization failed',
                      style: GoogleFonts.inter(fontSize: 14, color: AppTheme.muted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () => ai.ensureInitialized(),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                  ),
                ],
              ),
            );
          }

          return TabBarView(
            controller: _tabController,
            children: [
              _buildBriefingTab(ai),
              _buildInsightsTab(ai),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Briefing tab — full daily briefing
  // ---------------------------------------------------------------------------

  Widget _buildBriefingTab(AiProvider ai) {
    if (!ai.hasBriefing) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: const AiBriefingCard(),
      );
    }

    final briefing = ai.dailyBriefing!;
    return RefreshIndicator(
      onRefresh: () => ai.fetchDailyBriefing(forceRefresh: true),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Summary card at top
          const AiBriefingCard(),
          const SizedBox(height: 16),

          // Predictions
          if (briefing.predictions.isNotEmpty) ...[
            _sectionTitle('Predictions', Icons.trending_up_rounded),
            const SizedBox(height: 8),
            ...briefing.predictions.map((p) => _iconTextTile(p.icon, p.text)),
            const SizedBox(height: 16),
          ],

          // Opportunities
          if (briefing.opportunities.isNotEmpty) ...[
            _sectionTitle('Opportunities', Icons.lightbulb_outline_rounded),
            const SizedBox(height: 8),
            ...briefing.opportunities.map((o) => _iconTextTile(o.icon, o.text)),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Insights tab — search + recommendations + proactive insights
  // ---------------------------------------------------------------------------

  Widget _buildInsightsTab(AiProvider ai) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          const SizedBox(height: 12),
          AiSearchBar(
            onSubmitted: _onInsightsSearch,
            autoFocus: false,
            hintText: 'Search grade or client name...',
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _insightsLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildInsightsContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildInsightsContent() {
    // Show search results if a query was made
    if (_gradeAnalysis != null) return _buildGradeResult(_gradeAnalysis!);
    if (_clientAnalysis != null) return _buildClientResult(_clientAnalysis!);
    if (_insightsError != null && _lastQuery.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _insightsError!,
            style: GoogleFonts.inter(fontSize: 14, color: AppTheme.muted),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Default: show proactive insights list
    if (_insights == null || _insights!.insights.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_rounded, size: 48, color: AppTheme.muted.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(
              'Search for a grade or client name\nto get AI-powered analysis',
              style: GoogleFonts.inter(fontSize: 14, color: AppTheme.muted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        _sectionTitle('Proactive Insights', Icons.notifications_active_rounded),
        const SizedBox(height: 8),
        ..._insights!.insights.map((insight) => _insightCard(insight)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Grade analysis result
  // ---------------------------------------------------------------------------

  Widget _buildGradeResult(GradeAnalysis g) {
    final urgencyColor = _urgencyColor(g.urgency ?? 'healthy');
    return ListView(
      children: [
        // Grade header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: AppTheme.extrudedCardDecoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: urgencyColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      g.grade ?? _lastQuery,
                      style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: urgencyColor),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: urgencyColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      (g.urgency ?? 'unknown').toUpperCase(),
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: urgencyColor),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _metricTile('Stock', '${g.currentStock ?? 0} kg'),
                  _metricTile('Daily Rate', '${g.dailyRate?.toStringAsFixed(1) ?? 0} kg'),
                  _metricTile('Days Left', g.daysUntilDepletion != null ? '${g.daysUntilDepletion}' : 'N/A'),
                ],
              ),
            ],
          ),
        ),

        if (g.recommendations.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle('Recommendations', Icons.auto_awesome),
          const SizedBox(height: 8),
          ...g.recommendations.map((r) => _recommendationTile(r)),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Client analysis result
  // ---------------------------------------------------------------------------

  Widget _buildClientResult(ClientAnalysis c) {
    final client = c.client;
    final financial = c.financial;
    final riskColor = _churnRiskColor(client?.churnRisk ?? 'low');

    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: AppTheme.extrudedCardDecoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.person_rounded, color: AppTheme.primary, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      client?.name ?? _lastQuery,
                      style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.title),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: riskColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Risk: ${client?.churnRisk ?? 'low'}'.toUpperCase(),
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: riskColor),
                    ),
                  ),
                ],
              ),
              if (client != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Score: ${client.score}  •  Rank: ${client.rank}/${client.totalClients}',
                  style: GoogleFonts.inter(fontSize: 13, color: AppTheme.muted),
                ),
              ],
              if (financial != null) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    _metricTile('Orders', '${financial.orderCount}'),
                    _metricTile('Total', '₹${_formatLargeNumber(financial.totalValue)}'),
                    _metricTile('Pending', '₹${_formatLargeNumber(financial.pendingValue)}'),
                  ],
                ),
              ],
            ],
          ),
        ),

        if (c.recommendations.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle('Recommendations', Icons.auto_awesome),
          const SizedBox(height: 8),
          ...c.recommendations.map((r) => _recommendationTile(r)),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Shared widgets
  // ---------------------------------------------------------------------------

  Widget _sectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.secondary),
        const SizedBox(width: 8),
        Text(title, style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.title)),
      ],
    );
  }

  Widget _iconTextTile(String icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(icon, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: GoogleFonts.inter(fontSize: 13, color: AppTheme.title, height: 1.5))),
        ],
      ),
    );
  }

  Widget _metricTile(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.title)),
          const SizedBox(height: 2),
          Text(label, style: GoogleFonts.inter(fontSize: 11, color: AppTheme.muted)),
        ],
      ),
    );
  }

  Widget _recommendationTile(AiRecommendation r) {
    final priorityColor = r.priority == 'high'
        ? AppTheme.danger
        : r.priority == 'medium'
            ? AppTheme.secondary
            : AppTheme.muted;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.matteGlassDecoration.copyWith(borderRadius: BorderRadius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.text, style: GoogleFonts.inter(fontSize: 13, color: AppTheme.title, height: 1.4)),
                if (r.action != null) ...[
                  const SizedBox(height: 4),
                  Text(r.action!, style: GoogleFonts.inter(fontSize: 12, color: AppTheme.secondary, fontWeight: FontWeight.w500)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: priorityColor, shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }

  Widget _insightCard(Insight insight) {
    final priorityColor = insight.priority == 'critical'
        ? AppTheme.danger
        : insight.priority == 'high'
            ? AppTheme.secondary
            : AppTheme.muted;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.matteGlassDecoration.copyWith(borderRadius: BorderRadius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(insight.icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(insight.title, style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.title)),
                const SizedBox(height: 4),
                Text(insight.description, style: GoogleFonts.inter(fontSize: 13, color: AppTheme.muted, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: priorityColor, shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Color _urgencyColor(String urgency) {
    switch (urgency) {
      case 'critical': return AppTheme.danger;
      case 'warning': return AppTheme.secondary;
      case 'healthy': return AppTheme.primary;
      default: return AppTheme.muted;
    }
  }

  Color _churnRiskColor(String risk) {
    switch (risk) {
      case 'high': return AppTheme.danger;
      case 'medium': return AppTheme.secondary;
      default: return AppTheme.primary;
    }
  }

  String _formatLargeNumber(int value) {
    if (value >= 100000) return '${(value / 100000).toStringAsFixed(1)}L';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return '$value';
  }
}
