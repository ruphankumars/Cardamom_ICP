import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../services/persistent_operation_queue.dart';
import '../services/sync_manager.dart';
import '../theme/app_theme.dart';

/// Compact floating badge showing sync status and pending operations.
///
/// States:
/// - Syncing: pulsing cloud icon + "Syncing orders..."
/// - Pending writes: amber badge "3 pending" — tappable to expand
/// - Idle + empty: [SizedBox.shrink()] (invisible)
class SyncStatusWidget extends StatefulWidget {
  const SyncStatusWidget({super.key});

  @override
  State<SyncStatusWidget> createState() => _SyncStatusWidgetState();
}

class _SyncStatusWidgetState extends State<SyncStatusWidget>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _pulseController;
  StreamSubscription<PendingOperation>? _completedSub;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    // Listen for completed operations to show success feedback
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final queue = context.read<PersistentOperationQueue>();
      _completedSub = queue.completedOps.listen((op) {
        if (mounted) {
          setState(() => _successMessage = '✅ ${op.label} synced');
          // Auto-hide after 3 seconds
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) setState(() => _successMessage = null);
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<PersistentOperationQueue, SyncManager>(
      builder: (context, queue, syncManager, _) {
        final hasPending = queue.pendingCount > 0;
        final hasFailed = queue.failedCount > 0;
        final isSyncing = syncManager.isSyncing;

        // Nothing to show — unless we have a success message
        if (!hasPending && !hasFailed && !isSyncing) {
          if (_successMessage != null) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.shade700.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      _successMessage!,
                      style: GoogleFonts.manrope(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
                // ── Compact badge ──
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSyncing
                          ? AppTheme.primary.withOpacity(0.9)
                          : hasFailed
                              ? Colors.red.shade700.withOpacity(0.9)
                              : Colors.orange.shade700.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isSyncing)
                          FadeTransition(
                            opacity: _pulseController,
                            child: const Icon(Icons.cloud_sync_rounded,
                                color: Colors.white, size: 16),
                          )
                        else
                          Icon(
                            hasFailed
                                ? Icons.cloud_off_rounded
                                : Icons.cloud_upload_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                        const SizedBox(width: 6),
                        Text(
                          isSyncing
                              ? 'Syncing ${syncManager.currentCollection ?? ''}...'
                              : hasFailed
                                  ? '${queue.failedCount} failed'
                                  : '${queue.pendingCount} pending',
                          style: GoogleFonts.manrope(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        if (hasPending && !isSyncing) ...[
                          const SizedBox(width: 4),
                          Icon(
                            _expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            color: Colors.white70,
                            size: 16,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // ── Expanded list of pending operations ──
                if (_expanded && !isSyncing)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: [
                        if (queue.pending.isNotEmpty)
                          _sectionHeader('Pending', Colors.orange),
                        ...queue.pending.map((op) => _operationTile(op, false)),
                        if (queue.failedOps.isNotEmpty) ...[
                          _sectionHeader('Failed', Colors.red),
                          ...queue.failedOps
                              .map((op) => _operationTile(op, true)),
                        ],
                        if (queue.failedOps.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  onPressed: () =>
                                      queue.retryAllFailed(),
                                  icon: const Icon(Icons.refresh,
                                      size: 14),
                                  label: Text('Retry All',
                                      style: GoogleFonts.manrope(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600)),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppTheme.primary,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
      },
    );
  }

  Widget _sectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2, top: 4),
      child: Text(
        title.toUpperCase(),
        style: GoogleFonts.manrope(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: color,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _operationTile(PendingOperation op, bool isFailed) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            isFailed ? Icons.error_outline : Icons.schedule,
            size: 14,
            color: isFailed ? Colors.red : Colors.orange,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  op.label,
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary,
                  ),
                ),
                if (isFailed && op.errorMessage != null)
                  Text(
                    op.errorMessage!,
                    style: GoogleFonts.manrope(
                      fontSize: 9,
                      color: Colors.red.shade400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          Text(
            _timeAgo(op.createdAt),
            style: GoogleFonts.manrope(
              fontSize: 9,
              color: Colors.grey,
            ),
          ),
          if (isFailed)
            IconButton(
              icon: const Icon(Icons.refresh, size: 14),
              onPressed: () => context
                  .read<PersistentOperationQueue>()
                  .retryFailed(op.id),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              color: AppTheme.primary,
            ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
