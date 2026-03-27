/// Draggable cart button widget for the admin dashboard.
///
/// A floating action button that appears when urgency orders are selected,
/// allowing the user to send selected orders to the daily cart.
import 'package:flutter/material.dart';

/// A draggable cart FAB that shows selected item count and triggers cart send.
class DraggableCartButton extends StatelessWidget {
  final Offset position;
  final int selectedCount;
  final VoidCallback onTap;
  final ValueChanged<Offset> onDragEnd;

  const DraggableCartButton({
    super.key,
    required this.position,
    required this.selectedCount,
    required this.onTap,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx,
      top: position.dy,
      child: Draggable(
        feedback: _buildCartFab(isDragging: true),
        childWhenDragging: const SizedBox.shrink(),
        onDragEnd: (details) {
          double x = details.offset.dx;
          double y = details.offset.dy;
          final size = MediaQuery.of(context).size;
          x = x.clamp(10, size.width - 70);
          y = y.clamp(10, size.height - 150);
          onDragEnd(Offset(x, y));
        },
        child: _buildCartFab(),
      ),
    );
  }

  Widget _buildCartFab({bool isDragging = false}) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 60, height: 60,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF4A5568)]),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF5D6E7E).withOpacity(0.4),
                blurRadius: isDragging ? 20 : 12,
                offset: const Offset(0, 4),
              ),
            ],
            border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.shopping_cart_checkout_rounded, color: Colors.white, size: 28),
              Positioned(
                right: 12, top: 12,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                  child: Text(
                    '$selectedCount',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
