import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/ai_provider.dart';
import '../theme/app_theme.dart';

/// Card displaying the daily AI-generated business briefing from backend.
class AiBriefingCard extends StatefulWidget {
  final VoidCallback? onTapAction;
  const AiBriefingCard({super.key, this.onTapAction});

  @override
  State<AiBriefingCard> createState() => _AiBriefingCardState();
}

class _AiBriefingCardState extends State<AiBriefingCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AiProvider>().fetchDailyBriefing().catchError((_) {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AiProvider>(
      builder: (context, ai, _) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: AppTheme.extrudedCardDecoration,
          clipBehavior: Clip.antiAlias,
          child: _buildContent(context, ai),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context, AiProvider ai) {
    if (ai.isLoading && !ai.hasBriefing) return _buildLoadingState();
    if (ai.status == AiStatus.error && !ai.hasBriefing) return _buildErrorState(context, ai);
    if (!ai.hasBriefing) return _buildEmptyState(context, ai);
    return _buildBriefing(context, ai);
  }

  Widget _buildLoadingState() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(isLoading: true),
          const SizedBox(height: 16),
          for (var i = 0; i < 4; i++) ...[
            _ShimmerLine(width: i == 3 ? 180 : double.infinity),
            if (i < 3) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, AiProvider ai) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          Icon(Icons.cloud_off_rounded, size: 32, color: AppTheme.danger.withValues(alpha: 0.6)),
          const SizedBox(height: 10),
          Text(
            ai.errorMessage ?? 'Failed to load briefing',
            style: GoogleFonts.inter(fontSize: 13, color: AppTheme.muted, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: ai.isLoading ? null : () {
                HapticFeedback.lightImpact();
                ai.ensureInitialized();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text('Retry', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, AiProvider ai) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          Text(
            'No briefing available. Tap below to fetch your daily business summary.',
            style: GoogleFonts.inter(fontSize: 13, color: AppTheme.muted, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: ai.isLoading ? null : () {
                HapticFeedback.lightImpact();
                ai.fetchDailyBriefing(forceRefresh: true).catchError((_) {});
              },
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text('Fetch Briefing', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBriefing(BuildContext context, AiProvider ai) {
    final briefing = ai.dailyBriefing!;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(
            onRefresh: ai.isLoading ? null : () {
              HapticFeedback.lightImpact();
              ai.fetchDailyBriefing(forceRefresh: true).catchError((_) {});
            },
          ),
          const SizedBox(height: 14),

          // Summary metrics
          if (briefing.summary != null) ...[
            _buildMetricsRow(briefing.summary!),
            const SizedBox(height: 14),
          ],

          // Priority actions (top 3)
          if (briefing.priorityActions.isNotEmpty) ...[
            Text('Priority Actions', style: GoogleFonts.outfit(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.title)),
            const SizedBox(height: 6),
            ...briefing.priorityActions.take(3).map((a) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.icon, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(a.text, style: GoogleFonts.inter(fontSize: 13, color: AppTheme.title, height: 1.4))),
                ],
              ),
            )),
            const SizedBox(height: 10),
          ],

          // Today's patterns (top 2)
          if (briefing.todayPatterns.isNotEmpty) ...[
            ...briefing.todayPatterns.take(2).map((p) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.icon, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(p.text, style: GoogleFonts.inter(fontSize: 13, color: AppTheme.muted, height: 1.4))),
                ],
              ),
            )),
          ],

          const SizedBox(height: 14),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader({bool isLoading = false, VoidCallback? onRefresh}) {
    final dateStr = DateFormat('EEEE, d MMMM').format(DateTime.now());
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [AppTheme.primary, AppTheme.steelBlue]),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: AppTheme.primary.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: const Icon(Icons.psychology_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Daily Briefing', style: GoogleFonts.outfit(fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.title)),
              const SizedBox(height: 2),
              Text(dateStr, style: GoogleFonts.inter(fontSize: 12, color: AppTheme.muted)),
            ],
          ),
        ),
        if (isLoading)
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.secondary))
        else if (onRefresh != null)
          IconButton(icon: Icon(Icons.refresh_rounded, color: AppTheme.muted, size: 22), onPressed: onRefresh),
      ],
    );
  }

  Widget _buildMetricsRow(BriefingSummary summary) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.recessedDecoration.copyWith(borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          _metric(Icons.inventory_2_outlined, '${summary.totalStock}', 'Stock (kg)'),
          _metric(Icons.pending_actions, '${summary.totalPending}', 'Pending'),
          _metric(Icons.people_outline, '${summary.activeClients}', 'Clients'),
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String value, String label) {
    return Expanded(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppTheme.muted),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.title)),
              Text(label, style: GoogleFonts.inter(fontSize: 11, color: AppTheme.muted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Row(
      children: [
        Icon(Icons.cloud_done_outlined, size: 14, color: AppTheme.muted.withValues(alpha: 0.6)),
        const SizedBox(width: 4),
        Text('Powered by AI', style: GoogleFonts.inter(fontSize: 11, color: AppTheme.muted.withValues(alpha: 0.6), fontStyle: FontStyle.italic)),
        const Spacer(),
        Text(DateFormat('h:mm a').format(DateTime.now()), style: GoogleFonts.inter(fontSize: 11, color: AppTheme.muted.withValues(alpha: 0.6))),
      ],
    );
  }
}

class _ShimmerLine extends StatefulWidget {
  final double width;
  const _ShimmerLine({this.width = double.infinity});
  @override
  State<_ShimmerLine> createState() => _ShimmerLineState();
}

class _ShimmerLineState extends State<_ShimmerLine> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
  }

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: widget.width, height: 14,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            begin: Alignment(-1.0 + 2.0 * _controller.value, 0),
            end: Alignment(1.0 + 2.0 * _controller.value, 0),
            colors: [AppTheme.titaniumMid.withValues(alpha: 0.3), AppTheme.titaniumLight.withValues(alpha: 0.6), AppTheme.titaniumMid.withValues(alpha: 0.3)],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
      ),
    );
  }
}
