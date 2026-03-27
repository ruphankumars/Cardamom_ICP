import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';

/// Panel to display approval requests for admin users
class ApprovalPanel extends StatefulWidget {
  const ApprovalPanel({super.key});

  @override
  State<ApprovalPanel> createState() => _ApprovalPanelState();
}

class _ApprovalPanelState extends State<ApprovalPanel> {
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _loadCurrentUserId();
    // Fetch approval requests when panel is shown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationService>().fetchApprovalRequests();
    });
  }

  Future<void> _loadCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _currentUserId = prefs.getString('userId');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationService>(
      builder: (context, service, _) {
        if (service.isLoadingApprovals) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Color(0xFF5D6E7E)),
                SizedBox(height: 16),
                Text('Loading requests...', style: TextStyle(color: Color(0xFF64748B))),
              ],
            ),
          );
        }

        final requests = service.pendingApprovals;

        if (requests.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline, size: 48, color: Color(0xFF10B981)),
                SizedBox(height: 16),
                Text('No pending approvals', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
                SizedBox(height: 4),
                Text('All caught up!', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () => service.fetchApprovalRequests(),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final request = requests[index];
              // Hide approve/reject buttons if this is the current user's own request
              final isOwnRequest = _currentUserId != null && request.requesterId == _currentUserId;
              return _ApprovalRequestCard(request: request, isOwnRequest: isOwnRequest);
            },
          ),
        );
      },
    );
  }
}

class _ApprovalRequestCard extends StatelessWidget {
  final ApprovalRequest request;
  final bool isOwnRequest;

  const _ApprovalRequestCard({required this.request, this.isOwnRequest = false});

  @override
  Widget build(BuildContext context) {
    final isDelete = request.actionType == 'delete';
    final actionColor = isDelete ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    final actionIcon = isDelete ? Icons.delete_rounded : Icons.edit_rounded;
    final actionLabel = isDelete ? 'Delete' : 'Edit';

    return GestureDetector(
      onTap: () => _showDetailDialog(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: actionColor.withOpacity(0.2)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Action type icon
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: actionColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(actionIcon, color: actionColor, size: 18),
            ),
            const SizedBox(width: 12),
            // Request info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: actionColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          actionLabel,
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: actionColor),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          request.requesterName,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _buildResourceDescription(),
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatTimestamp(request.createdAt),
                    style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
            // Quick action buttons (hidden for own requests)
            if (!isOwnRequest)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Approve (tick)
                  _QuickActionButton(
                    icon: Icons.check_rounded,
                    color: const Color(0xFF10B981),
                    onTap: () => _quickApprove(context),
                  ),
                  const SizedBox(width: 8),
                  // Reject (X)
                  _QuickActionButton(
                    icon: Icons.close_rounded,
                    color: const Color(0xFFEF4444),
                    onTap: () => _quickReject(context),
                  ),
                ],
              )
            else
              // Show "Your Request" badge for own requests
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF64748B).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Your Request',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _buildResourceDescription() {
    final data = request.resourceData;
    if (data == null) return '${request.resourceType} #${request.resourceId}';
    
    final client = data['client'] ?? '';
    final lot = data['lot'] ?? '';
    final grade = data['grade'] ?? '';
    
    if (client.isNotEmpty && lot.isNotEmpty) {
      return '$client - $lot${grade.isNotEmpty ? ' ($grade)' : ''}';
    }
    
    return '${request.resourceType} #${request.resourceId}';
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('dd MMM, HH:mm').format(dt);
  }

  Future<void> _quickApprove(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final adminId = prefs.getString('userId') ?? '';
    final adminName = prefs.getString('username') ?? 'Admin';

    final service = context.read<NotificationService>();
    
    // Show loading
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    bool success = false;
    try {
      success = await service.approveRequest(request.id, adminId, adminName);
    } catch (e) {
      debugPrint('Error approving request: $e');
    } finally {
      navigator.pop(); // Always close loading dialog
    }

    if (success) {
      service.removeApprovalRequest(request.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Request approved'),
          backgroundColor: Color(0xFF10B981),
        ),
      );
    } else {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to approve request'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
    }
  }

  Future<void> _quickReject(BuildContext context) async {
    final reasonController = TextEditingController();
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Reject Request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Reject ${request.actionType} request from ${request.requesterName}?',
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              decoration: InputDecoration(
                labelText: 'Reason (optional)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final prefs = await SharedPreferences.getInstance();
    final adminId = prefs.getString('userId') ?? '';
    final adminName = prefs.getString('username') ?? 'Admin';
    final reason = reasonController.text.isNotEmpty ? reasonController.text : 'No reason provided';

    final service = context.read<NotificationService>();
    
    // Show loading
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    bool success = false;
    try {
      success = await service.rejectRequest(request.id, adminId, adminName, reason);
    } catch (e) {
      debugPrint('Error rejecting request: $e');
    } finally {
      navigator.pop(); // Always close loading dialog
    }

    if (success) {
      service.removeApprovalRequest(request.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Request rejected'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
    } else {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to reject request'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
    }
  }

  void _showDetailDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => _ApprovalDetailDialog(request: request, isOwnRequest: isOwnRequest),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}

/// Detailed approval request dialog
class _ApprovalDetailDialog extends StatelessWidget {
  final ApprovalRequest request;
  final bool isOwnRequest;

  const _ApprovalDetailDialog({required this.request, this.isOwnRequest = false});

  @override
  Widget build(BuildContext context) {
    final isDelete = request.actionType == 'delete';
    final actionColor = isDelete ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    final actionLabel = isDelete ? 'Delete Request' : 'Edit Request';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: actionColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  Icon(isDelete ? Icons.delete_rounded : Icons.edit_rounded, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      actionLabel,
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
            ),
            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoRow('Requested by', request.requesterName),
                    _buildInfoRow('Requested at', DateFormat('dd MMM yyyy, HH:mm').format(request.createdAt)),
                    if (request.reason != null && request.reason!.isNotEmpty)
                      _buildInfoRow('Reason', request.reason!),
                    const Divider(height: 24),
                    const Text(
                      'Resource Details',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                    ),
                    const SizedBox(height: 8),
                    _buildResourceDetails(),
                    if (request.proposedChanges != null && request.proposedChanges!.isNotEmpty) ...[
                      const Divider(height: 24),
                      const Text(
                        'Proposed Changes',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                      const SizedBox(height: 8),
                      _buildChanges(),
                    ],
                  ],
                ),
              ),
            ),
            // Actions (hidden for own requests)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
              ),
              child: isOwnRequest
                  ? SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF64748B),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              Navigator.pop(context);
                              await _handleReject(context);
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFEF4444),
                              side: const BorderSide(color: Color(0xFFEF4444)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Reject', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              Navigator.pop(context);
                              await _handleApprove(context);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF0F172A))),
          ),
        ],
      ),
    );
  }

  Widget _buildResourceDetails() {
    // Show only the resource type (ORDER, PURCHASE, EXPENSE, GATEPASS)
    final resourceTypeDisplay = request.resourceType.toUpperCase();
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Icon(
            _getResourceIcon(request.resourceType),
            color: const Color(0xFF64748B),
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            resourceTypeDisplay,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF0F172A),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getResourceIcon(String resourceType) {
    switch (resourceType.toLowerCase()) {
      case 'order':
        return Icons.shopping_cart_outlined;
      case 'purchase':
        return Icons.add_shopping_cart;
      case 'expense':
        return Icons.receipt_long_outlined;
      case 'gatepass':
        return Icons.badge_outlined;
      default:
        return Icons.article_outlined;
    }
  }

  Widget _buildChanges() {
    final changes = request.proposedChanges!;
    final resourceType = request.resourceType.toLowerCase();
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFCD34D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _buildFormattedChanges(changes, resourceType),
      ),
    );
  }

  List<Widget> _buildFormattedChanges(Map<String, dynamic> changes, String resourceType) {
    if (resourceType == 'order') {
      return _buildOrderChanges(changes);
    } else if (resourceType == 'purchase') {
      return _buildPurchaseChanges(changes);
    } else if (resourceType == 'expense') {
      return _buildExpenseChanges(changes);
    } else if (resourceType == 'gatepass') {
      return _buildGatepassChanges(changes);
    } else {
      // Default: show all fields
      return changes.entries.map((e) => _buildChangeRow(e.key, '${e.value}')).toList();
    }
  }

  List<Widget> _buildOrderChanges(Map<String, dynamic> changes) {
    final widgets = <Widget>[];
    
    // Format: Lot: Grade - No BagBox - Kgs kgs × ₹Price - Brand
    final lot = changes['lot'] ?? changes['lotNumber'] ?? '';
    final grade = changes['grade'] ?? '';
    final no = changes['no'] ?? changes['bags'] ?? '';
    final bagbox = changes['bagbox'] ?? '';
    final kgs = changes['kgs'] ?? '';
    final price = changes['price'] ?? '';
    final brand = changes['brand'] ?? '';
    final notes = changes['notes'] ?? '';
    
    // Main order line
    String orderLine = '';
    if (lot.toString().isNotEmpty) orderLine += '$lot: ';
    if (grade.toString().isNotEmpty) orderLine += '$grade';
    if (no.toString().isNotEmpty && bagbox.toString().isNotEmpty) {
      orderLine += ' - $no $bagbox';
    }
    if (kgs.toString().isNotEmpty) orderLine += ' - $kgs kgs';
    if (price.toString().isNotEmpty) orderLine += ' × ₹$price';
    if (brand.toString().isNotEmpty) orderLine += ' - $brand';
    
    if (orderLine.isNotEmpty) {
      widgets.add(
        Text(
          orderLine.trim(),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFFD97706),
          ),
        ),
      );
    }
    
    // Notes if present
    if (notes.toString().isNotEmpty) {
      widgets.add(const SizedBox(height: 6));
      widgets.add(
        Row(
          children: [
            const Text('≡ ', style: TextStyle(color: Color(0xFF92400E), fontSize: 12)),
            Expanded(
              child: Text(
                notes.toString(),
                style: const TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF92400E),
                ),
              ),
            ),
          ],
        ),
      );
    }
    
    // Show any additional fields not covered above
    final handledKeys = {'lot', 'lotNumber', 'grade', 'no', 'bags', 'bagbox', 'kgs', 'price', 'brand', 'notes'};
    for (final entry in changes.entries) {
      if (!handledKeys.contains(entry.key) && entry.value != null && entry.value.toString().isNotEmpty) {
        widgets.add(const SizedBox(height: 4));
        widgets.add(_buildChangeRow(entry.key, '${entry.value}'));
      }
    }
    
    return widgets.isEmpty ? [const Text('No changes', style: TextStyle(color: Color(0xFF92400E)))] : widgets;
  }

  List<Widget> _buildPurchaseChanges(Map<String, dynamic> changes) {
    // Format: Amount, Grade, Qty
    final widgets = <Widget>[];
    if (changes['amount'] != null) widgets.add(_buildChangeRow('Amount', '₹${changes['amount']}'));
    if (changes['grade'] != null) widgets.add(_buildChangeRow('Grade', '${changes['grade']}'));
    if (changes['qty'] != null || changes['quantity'] != null) {
      widgets.add(_buildChangeRow('Qty', '${changes['qty'] ?? changes['quantity']}'));
    }
    // Any other fields
    final handledKeys = {'amount', 'grade', 'qty', 'quantity'};
    for (final entry in changes.entries) {
      if (!handledKeys.contains(entry.key) && entry.value != null && entry.value.toString().isNotEmpty) {
        widgets.add(_buildChangeRow(entry.key, '${entry.value}'));
      }
    }
    return widgets.isEmpty ? [const Text('No changes', style: TextStyle(color: Color(0xFF92400E)))] : widgets;
  }

  List<Widget> _buildExpenseChanges(Map<String, dynamic> changes) {
    // Format: Date, Total, Items
    final widgets = <Widget>[];
    if (changes['date'] != null) widgets.add(_buildChangeRow('Date', '${changes['date']}'));
    if (changes['total'] != null) widgets.add(_buildChangeRow('Total', '₹${changes['total']}'));
    if (changes['items'] != null) {
      final items = changes['items'];
      if (items is List && items.isNotEmpty) {
        widgets.add(_buildChangeRow('Items', '${items.length} item(s)'));
      }
    }
    // Any other fields
    final handledKeys = {'date', 'total', 'items'};
    for (final entry in changes.entries) {
      if (!handledKeys.contains(entry.key) && entry.value != null && entry.value.toString().isNotEmpty && entry.value is! List) {
        widgets.add(_buildChangeRow(entry.key, '${entry.value}'));
      }
    }
    return widgets.isEmpty ? [const Text('No changes', style: TextStyle(color: Color(0xFF92400E)))] : widgets;
  }

  List<Widget> _buildGatepassChanges(Map<String, dynamic> changes) {
    // Format: Type, Vehicle, Weight
    final widgets = <Widget>[];
    if (changes['type'] != null) widgets.add(_buildChangeRow('Type', '${changes['type']}'));
    if (changes['vehicle'] != null || changes['vehicleNumber'] != null) {
      widgets.add(_buildChangeRow('Vehicle', '${changes['vehicle'] ?? changes['vehicleNumber']}'));
    }
    if (changes['weight'] != null) widgets.add(_buildChangeRow('Weight', '${changes['weight']} kg'));
    // Any other fields
    final handledKeys = {'type', 'vehicle', 'vehicleNumber', 'weight'};
    for (final entry in changes.entries) {
      if (!handledKeys.contains(entry.key) && entry.value != null && entry.value.toString().isNotEmpty) {
        widgets.add(_buildChangeRow(entry.key, '${entry.value}'));
      }
    }
    return widgets.isEmpty ? [const Text('No changes', style: TextStyle(color: Color(0xFF92400E)))] : widgets;
  }

  Widget _buildChangeRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFD97706)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleApprove(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final adminId = prefs.getString('userId') ?? '';
    final adminName = prefs.getString('username') ?? 'Admin';

    final service = context.read<NotificationService>();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    final success = await service.approveRequest(request.id, adminId, adminName);

    if (!context.mounted) return;
    Navigator.pop(context);

    if (success) {
      service.removeApprovalRequest(request.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Request approved'), backgroundColor: Color(0xFF10B981)),
      );
    }
  }

  Future<void> _handleReject(BuildContext context) async {
    final reasonController = TextEditingController();
    
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Rejection Reason'),
        content: TextField(
          controller: reasonController,
          decoration: InputDecoration(
            labelText: 'Reason (optional)',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          maxLines: 2,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, reasonController.text),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (reason == null) return;

    final prefs = await SharedPreferences.getInstance();
    final adminId = prefs.getString('userId') ?? '';
    final adminName = prefs.getString('username') ?? 'Admin';

    final service = context.read<NotificationService>();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    final success = await service.rejectRequest(
      request.id,
      adminId,
      adminName,
      reason.isNotEmpty ? reason : 'No reason provided',
    );

    if (!context.mounted) return;
    Navigator.pop(context);

    if (success) {
      service.removeApprovalRequest(request.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('❌ Request rejected'), backgroundColor: Color(0xFFEF4444)),
      );
    }
  }
}
