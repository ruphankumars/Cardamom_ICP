import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ai_provider.dart';
import '../services/navigation_service.dart';
import '../theme/app_theme.dart';

/// Floating action button for accessing the AI assistant.
///
/// Shows on every screen. Displays a subtle pulse animation while the backend
/// is loading, and a notification dot when a daily briefing is available.
class AiFab extends StatefulWidget {
  /// Called when the user taps the FAB. If null, defaults to pushing the
  /// `/ai_overlay` named route.
  final VoidCallback? onTap;

  /// Whether the AI overlay is currently open. The FAB hides itself when true.
  static final ValueNotifier<bool> isOverlayOpen = ValueNotifier(false);

  const AiFab({super.key, this.onTap});

  @override
  State<AiFab> createState() => _AiFabState();
}

class _AiFabState extends State<AiFab> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  AiProvider? _aiProvider;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ai = context.read<AiProvider>();
    if (_aiProvider != ai) {
      _aiProvider?.removeListener(_onAiChanged);
      _aiProvider = ai;
      _aiProvider!.addListener(_onAiChanged);
      _syncPulse(ai.isLoading);
    }
  }

  void _onAiChanged() {
    if (!mounted) return;
    _syncPulse(_aiProvider?.isLoading ?? false);
  }

  @override
  void dispose() {
    _aiProvider?.removeListener(_onAiChanged);
    _pulseController.dispose();
    super.dispose();
  }

  void _syncPulse(bool isLoading) {
    if (isLoading && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!isLoading && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  Future<void> _handleTap() async {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    navigatorKey.currentState?.pushNamed('/ai_overlay');
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AiFab.isOverlayOpen,
      builder: (context, overlayOpen, _) {
        if (overlayOpen) return const SizedBox.shrink();
        return Consumer<AiProvider>(
          builder: (context, ai, _) {
        final IconData fabIcon;
        if (ai.status == AiStatus.error) {
          fabIcon = Icons.warning_amber_rounded;
        } else {
          fabIcon = Icons.auto_awesome;
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ScaleTransition(
            scale: _pulseAnimation,
            child: SizedBox(
              width: 56,
              height: 56,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.titaniumLight, AppTheme.titaniumMid, AppTheme.titaniumDark],
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                  boxShadow: AppTheme.floatingShadow,
                ),
                child: Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _handleTap,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (ai.isLoading)
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppTheme.primary,
                            ),
                          )
                        else
                          Icon(
                            fabIcon,
                            color: AppTheme.primary,
                            size: 26,
                          ),

                        // Notification dot for new briefing
                        if (ai.hasBriefing)
                          Positioned(
                            top: 10,
                            right: 10,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: AppTheme.secondary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppTheme.titaniumLight,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
          },
        );
      },
    );
  }
}
