import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../services/ai_provider.dart';
import '../theme/app_theme.dart';

/// Search input bar for the AI overlay.
///
/// Features a rounded text field with search icon, clear/send trailing actions,
/// and a subtle linear progress indicator that appears while the AI is
/// generating a response.
class AiSearchBar extends StatefulWidget {
  /// Called when the user submits a query (keyboard submit or send button).
  final ValueChanged<String> onSubmitted;

  /// Whether the field should auto-focus when first built.
  final bool autoFocus;

  /// Optional hint text override.
  final String? hintText;

  const AiSearchBar({
    super.key,
    required this.onSubmitted,
    this.autoFocus = true,
    this.hintText,
  });

  @override
  State<AiSearchBar> createState() => _AiSearchBarState();
}

class _AiSearchBarState extends State<AiSearchBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    // Prevent duplicate submissions while loading
    final ai = context.read<AiProvider>();
    if (ai.isLoading) return;
    widget.onSubmitted(query);
  }

  void _clear() {
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.titaniumBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: widget.autoFocus,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            style: GoogleFonts.inter(
              fontSize: 15,
              color: AppTheme.title,
            ),
            decoration: InputDecoration(
              hintText: widget.hintText ?? 'Ask anything about your business...',
              hintStyle: GoogleFonts.inter(
                fontSize: 14,
                color: AppTheme.muted.withValues(alpha: 0.6),
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: AppTheme.muted,
                size: 22,
              ),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_hasText)
                    IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        color: AppTheme.muted,
                        size: 20,
                      ),
                      onPressed: _clear,
                      tooltip: 'Clear',
                    ),
                  IconButton(
                    icon: Icon(
                      Icons.send_rounded,
                      color: _hasText && !ai.isLoading ? AppTheme.secondary : AppTheme.muted.withValues(alpha: 0.4),
                      size: 20,
                    ),
                    onPressed: _hasText && !ai.isLoading ? _submit : null,
                    tooltip: 'Send',
                  ),
                ],
              ),
              // Override default theme borders so the parent Container's
              // decoration controls the shape.
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 0,
                vertical: 14,
              ),
            ),
          ),
        ),

        // Subtle loading bar when AI is generating
        if (ai.isLoading)
          ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(20),
            ),
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: AppTheme.secondary.withValues(alpha: 0.6),
            ),
          ),
      ],
    );
  }
}
