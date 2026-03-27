/// Request details popup widget for the admin dashboard.
///
/// Shows full details of an order request for admin verification
/// before approving, with labeled detail rows and action buttons.
import 'package:flutter/material.dart';

/// A popup/bottom-sheet content widget showing order request details.
class RequestDetailsContent extends StatelessWidget {
  final Map<String, dynamic> request;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  const RequestDetailsContent({
    super.key,
    required this.request,
    this.onApprove,
    this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Request Details', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Divider(),
          const SizedBox(height: 12),
          _buildDetailRow('Client', request['client']?.toString() ?? 'N/A'),
          _buildDetailRow('Grade', request['grade']?.toString() ?? 'N/A'),
          _buildDetailRow('Quantity', '${request['kgs'] ?? 0} kg'),
          _buildDetailRow('Price', '\u20B9${request['price'] ?? 0}'),
          _buildDetailRow('Lot', request['lot']?.toString() ?? 'N/A'),
          if (request['notes'] != null && request['notes'].toString().isNotEmpty)
            _buildDetailRow('Notes', request['notes'].toString()),
          const SizedBox(height: 20),
          if (onApprove != null || onReject != null)
            Row(
              children: [
                if (onReject != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Reject'),
                    ),
                  ),
                if (onApprove != null && onReject != null)
                  const SizedBox(width: 12),
                if (onApprove != null)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: onApprove,
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                      child: const Text('Approve', style: TextStyle(color: Colors.white)),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13, color: Color(0xFF1F2937))),
          ),
        ],
      ),
    );
  }
}
