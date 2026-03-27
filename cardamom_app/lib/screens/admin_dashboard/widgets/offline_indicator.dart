/// Offline indicator widget for the admin dashboard.
///
/// A small badge that appears when the app detects it is offline,
/// showing a cloud-off icon with "OFFLINE" text.
import 'package:flutter/material.dart';

/// Compact offline status indicator badge.
class DashboardOfflineIndicator extends StatelessWidget {
  const DashboardOfflineIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.5)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 10, color: Colors.white),
          SizedBox(width: 4),
          Text(
            'OFFLINE',
            style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
