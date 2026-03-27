import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connectivity_service.dart';
import '../theme/app_theme.dart';

/// A compact, non-intrusive offline status banner.
///
/// Shows "Offline - Last synced X min ago" when connectivity is lost.
/// Matches the app's titanium design language. Animates in/out smoothly.
class OfflineIndicator extends StatelessWidget {
  const OfflineIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectivityService>(
      builder: (context, connectivity, _) {
        return AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) => SizeTransition(
              sizeFactor: animation,
              axisAlignment: -1,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: connectivity.isOnline
                ? const SizedBox.shrink(key: ValueKey('online'))
                : _OfflineBanner(
                    key: const ValueKey('offline'),
                    lastSyncAgo: connectivity.lastSyncAgo,
                  ),
          ),
        );
      },
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  final String lastSyncAgo;

  const _OfflineBanner({super.key, required this.lastSyncAgo});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.titaniumDark.withOpacity(0.9),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withOpacity(0.2),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 16,
            color: AppTheme.danger.withOpacity(0.8),
          ),
          const SizedBox(width: 8),
          Text(
            'Offline',
            style: TextStyle(
              color: AppTheme.title,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '\u2022',
            style: TextStyle(
              color: AppTheme.muted,
              fontSize: 10,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Last synced $lastSyncAgo',
            style: TextStyle(
              color: AppTheme.muted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small chip shown on individual data sections when data is from cache.
class CachedDataChip extends StatelessWidget {
  final String ageString;

  const CachedDataChip({super.key, required this.ageString});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.warning.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.warning.withOpacity(0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.access_time_rounded,
            size: 12,
            color: AppTheme.warning,
          ),
          const SizedBox(width: 4),
          Text(
            'Cached $ageString',
            style: TextStyle(
              color: AppTheme.warning.withOpacity(0.9),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
