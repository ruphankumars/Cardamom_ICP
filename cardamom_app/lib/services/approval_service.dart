import 'package:flutter/material.dart';
import 'api_service.dart';

/// Service for handling approval workflow interceptors.
/// Determines if an action requires approval and routes accordingly.
class ApprovalService {
  static final ApprovalService _instance = ApprovalService._internal();
  factory ApprovalService() => _instance;
  ApprovalService._internal();

  final ApiService _apiService = ApiService();

  // Actions that require approval for non-admin users
  static const Set<String> _approvalRequiredActions = {
    'edit_suborder',
    'delete_suborder',
    'add_expense',
    'gate_pass_request',
    'add_purchase',
    'stock_adjustment',
    'new_order',
  };

  // Actions that are exempt from approval (always allowed)
  static const Set<String> _exemptActions = {
    'grade_allocator_to_cart', // Grade Allocator -> Cart is always allowed
  };

  /// Check if a user's role requires approval for actions
  bool requiresApproval(String? role) {
    final normalizedRole = role?.toLowerCase() ?? '';
    // Only superadmin bypasses approval — they are the highest authority
    return normalizedRole != 'superadmin';
  }

  /// Check if a specific action type needs approval
  bool actionNeedsApproval(String actionType) {
    if (_exemptActions.contains(actionType)) {
      return false;
    }
    return _approvalRequiredActions.contains(actionType);
  }

  /// Submit an action for approval (creates approval request)
  /// Returns: {success: true, requestId: 'xxx'} or {success: false, error: 'xxx'}
  Future<Map<String, dynamic>> submitForApproval({
    required String requesterId,
    required String requesterName,
    required String actionType,
    required String resourceType,
    required dynamic resourceId,
    Map<String, dynamic>? resourceData,
    Map<String, dynamic>? proposedChanges,
    String? reason,
  }) async {
    try {
      final response = await _apiService.createApprovalRequest({
        'requesterId': requesterId,
        'requesterName': requesterName,
        'actionType': actionType,
        'resourceType': resourceType,
        'resourceId': resourceId,
        'resourceData': resourceData,
        'proposedChanges': proposedChanges,
        'reason': reason,
      });

      final data = response.data is Map ? response.data as Map<String, dynamic> : <String, dynamic>{};
      return {
        'success': data['success'] == true,
        'requestId': data['requestId'],
        'message': data['message'] ?? 'Request submitted for approval',
      };
    } catch (e) {
      debugPrint('❌ [ApprovalService] Error submitting for approval: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// Execute an action or submit for approval based on user role
  /// 
  /// [role] - User's role (admin bypasses approval)
  /// [actionType] - Type of action being performed
  /// [resourceType] - Type of resource (order, expense, etc.)
  /// [resourceId] - ID of the resource being acted upon
  /// [executeAction] - Function to execute if approval not needed
  /// [requesterId] - User's ID
  /// [requesterName] - User's name
  /// [resourceData] - Current data of the resource
  /// [proposedChanges] - Changes being proposed
  /// [reason] - Reason for the action
  /// 
  /// Returns: {approved: true, result: ...} if executed, or {pending: true, requestId: ...} if submitted for approval
  Future<Map<String, dynamic>> executeOrRequestApproval({
    required String? role,
    required String actionType,
    required String resourceType,
    required dynamic resourceId,
    required Future<Map<String, dynamic>> Function() executeAction,
    required String requesterId,
    required String requesterName,
    Map<String, dynamic>? resourceData,
    Map<String, dynamic>? proposedChanges,
    String? reason,
  }) async {
    // Check if approval is needed
    final needsApproval = requiresApproval(role) && actionNeedsApproval(actionType);

    if (!needsApproval) {
      // Admin or exempt action - execute directly
      try {
        final result = await executeAction();
        return {
          'approved': true,
          'executed': true,
          'result': result,
        };
      } catch (e) {
        return {
          'approved': true,
          'executed': false,
          'error': e.toString(),
        };
      }
    } else {
      // Submit for approval
      final approvalResult = await submitForApproval(
        requesterId: requesterId,
        requesterName: requesterName,
        actionType: actionType,
        resourceType: resourceType,
        resourceId: resourceId,
        resourceData: resourceData,
        proposedChanges: proposedChanges,
        reason: reason,
      );

      if (approvalResult['success'] == true) {
        return {
          'pending': true,
          'requestId': approvalResult['requestId'],
          'message': 'Your request has been submitted for admin approval.',
        };
      } else {
        return {
          'pending': false,
          'error': approvalResult['error'] ?? 'Failed to submit approval request',
        };
      }
    }
  }

  /// Show a dialog to inform user their request was submitted for approval
  static void showApprovalPendingDialog(BuildContext context, {String? message}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.hourglass_top, color: Colors.orange, size: 48),
        title: const Text('Approval Required'),
        content: Text(
          message ?? 'Your request has been submitted for admin approval. You will be notified when it is processed.',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Show a dialog for rejection with reason
  static void showRejectionDialog(BuildContext context, {String? reason, String? adminName}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.cancel, color: Colors.red, size: 48),
        title: const Text('Request Rejected'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (adminName != null)
              Text('Rejected by $adminName', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            if (reason != null && reason.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Reason: $reason',
                  style: const TextStyle(fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Show approval success dialog
  static void showApprovalSuccessDialog(BuildContext context, {String? adminName}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: const Text('Request Approved'),
        content: Text(
          adminName != null 
              ? 'Your request was approved by $adminName and has been executed.'
              : 'Your request has been approved and executed.',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
