/// Draggable action arc widget for the admin dashboard.
///
/// A floating action button that expands into an arc of quick-action buttons
/// when tapped. Can be dragged to reposition on the screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_theme.dart';

/// A draggable floating action arc with expandable quick actions.
class DraggableActionArc extends StatefulWidget {
  final VoidCallback onNewOrder;
  final VoidCallback onViewOrders;
  final VoidCallback onDailyCart;
  final VoidCallback onRefresh;

  const DraggableActionArc({
    super.key,
    required this.onNewOrder,
    required this.onViewOrders,
    required this.onDailyCart,
    required this.onRefresh,
  });

  @override
  State<DraggableActionArc> createState() => _DraggableActionArcState();
}

class _DraggableActionArcState extends State<DraggableActionArc> {
  bool _isArcExpanded = false;
  Offset _arcFabPosition = const Offset(300, 600);

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 20,
      bottom: 100,
      child: Draggable(
        feedback: Material(color: Colors.transparent, child: _buildActionArc(isDragging: true)),
        childWhenDragging: const SizedBox.shrink(),
        onDragEnd: (details) {
          setState(() {
            _arcFabPosition = details.offset;
          });
        },
        child: _buildActionArc(),
      ),
    );
  }

  Widget _buildActionArc({bool isDragging = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isArcExpanded) ...[
          _buildArcItem(Icons.add_rounded, 'New', AppTheme.primary, widget.onNewOrder),
          const SizedBox(height: 8),
          _buildArcItem(Icons.list_alt_rounded, 'Orders', const Color(0xFF10B981), widget.onViewOrders),
          const SizedBox(height: 8),
          _buildArcItem(Icons.shopping_cart_rounded, 'Cart', const Color(0xFFF59E0B), widget.onDailyCart),
          const SizedBox(height: 8),
          _buildArcItem(Icons.refresh_rounded, 'Sync', const Color(0xFF5D6E7E), widget.onRefresh),
          const SizedBox(height: 12),
        ],
        GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            setState(() => _isArcExpanded = !_isArcExpanded);
          },
          child: Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF4A5568), Color(0xFF2D3748)],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(isDragging ? 0.4 : 0.3), blurRadius: isDragging ? 20 : 12, offset: const Offset(0, 4)),
              ],
            ),
            child: AnimatedRotation(
              turns: _isArcExpanded ? 0.125 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 28),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildArcItem(IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() => _isArcExpanded = false);
        onTap();
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF4A5568),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
          const SizedBox(width: 8),
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 2)),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ],
      ),
    );
  }
}
