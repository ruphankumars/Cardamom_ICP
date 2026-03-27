import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../models/expense_sheet.dart';
import '../services/expense_service.dart';
import '../services/expense_cart_service.dart';
import '../services/auth_provider.dart';
import '../services/api_service.dart';
import '../services/operation_queue.dart';
import '../mixins/optimistic_action_mixin.dart';

/// Daily Expense Sheet - Main screen for viewing and editing daily expenses
class DailyExpenseSheet extends StatefulWidget {
  final String? initialDate;
  
  const DailyExpenseSheet({super.key, this.initialDate});

  @override
  State<DailyExpenseSheet> createState() => _DailyExpenseSheetState();
}

class _DailyExpenseSheetState extends State<DailyExpenseSheet> with OptimisticActionMixin {
  late String _selectedDate;
  bool _isLoading = true;
  String _userRole = 'user';
  final ApiService _apiService = ApiService();
  Future<List<ExpenseSheet>>? _pendingSheetsFuture;

  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();
  
  bool get _isAdmin {
    final role = _userRole.toLowerCase().trim();
    final isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
    debugPrint('🔐 [Expense] Role: "$_userRole" -> isAdmin: $isAdmin');
    return isAdmin;
  }

  void _refreshPendingSheets() {
    _pendingSheetsFuture = Provider.of<ExpenseService>(context, listen: false).fetchPendingSheets();
  }

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
    _loadExpenseSheet();
  }

  Future<void> _loadExpenseSheet() async {
    setState(() => _isLoading = true);

    _userRole = await _apiService.getUserRole() ?? 'user';
    final service = Provider.of<ExpenseService>(context, listen: false);
    await service.loadExpenseSheet(_selectedDate);

    if (mounted) {
      _refreshPendingSheets();
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.titaniumLight,
      appBar: _buildAppBar(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
      floatingActionButton: _buildFAB(),
    );
  }

  AppBar _buildAppBar() {
    final date = DateTime.tryParse(_selectedDate) ?? DateTime.now();
    final dayName = DateFormat('EEEE').format(date);
    final formattedDate = DateFormat('MMM d, yyyy').format(date);

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios, color: AppTheme.primary),
        onPressed: () => Navigator.pop(context),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Daily Expenses', style: GoogleFonts.outfit(
            fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.primary)),
          Row(
            children: [
              const Icon(Icons.calendar_today, size: 14, color: AppTheme.muted),
              const SizedBox(width: 4),
              Text('$dayName, $formattedDate', style: TextStyle(
                fontSize: 12, color: AppTheme.muted)),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.calendar_month, color: AppTheme.primary),
          onPressed: _selectDate,
        ),
      ],
    );
  }

  Widget _buildContent() {
    return Consumer<ExpenseService>(
      builder: (context, service, _) {
        final sheet = service.currentSheet;
        
        return RefreshIndicator(
          onRefresh: _loadExpenseSheet,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status badge if not draft
                if (sheet != null && sheet.status != ExpenseStatus.draft)
                  _buildStatusBadge(sheet.status),
                // Admin: Pending Approvals Panel - only show if there are pending approvals
                if (['superadmin', 'admin', 'ops'].contains(Provider.of<AuthProvider>(context, listen: false).role?.toLowerCase()))
                  _buildPendingApprovalsPanel(),
                
                const SizedBox(height: 16),
                
                // Fixed costs section (Worker Wages)
                _buildSection(
                  title: 'FIXED COSTS',
                  icon: Icons.lock,
                  child: _buildFixedCostsCard(sheet?.workerWages ?? 0),
                ),
                
                const SizedBox(height: 24),
                
                // Variable costs section
                _buildSection(
                  title: 'VARIABLE COSTS',
                  icon: Icons.edit,
                  canAdd: sheet?.canEdit ?? true,
                  onAdd: () => _showAddExpenseModal(isVariable: true),
                  child: _buildVariableItemsList(sheet?.variableItems ?? []),
                ),
                
                const SizedBox(height: 24),
                
                // Misc section
                _buildSection(
                  title: 'MISCELLANEOUS',
                  icon: Icons.more_horiz,
                  subtitle: sheet != null ? '${sheet.miscPercentage.toStringAsFixed(1)}%' : null,
                  canAdd: sheet?.canEdit ?? true,
                  onAdd: () => _showAddExpenseModal(isVariable: false),
                  child: _buildMiscItemsList(sheet?.miscItems ?? []),
                ),
                
                const SizedBox(height: 24),
                
                // Grand total
                _buildGrandTotal(sheet?.grandTotal ?? sheet?.workerWages ?? 0),
                
                const SizedBox(height: 16),
                
                // Cart items (if any)
                _buildCartSection(sheet),
                
                const SizedBox(height: 16),
                
                // Action buttons
                if (sheet?.canSubmit ?? false)
                  _buildActionButtons(sheet!),
                
                if (sheet?.rejectionReason != null && sheet!.rejectionReason!.isNotEmpty)
                  _buildRejectionNote(sheet.rejectionReason!),
                
                const SizedBox(height: 100), // Bottom padding for FAB
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusBadge(ExpenseStatus status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Color(ExpenseService.getStatusColor(status)).withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            status == ExpenseStatus.approved ? Icons.check_circle :
            status == ExpenseStatus.pending ? Icons.hourglass_empty :
            status == ExpenseStatus.rejected ? Icons.cancel : Icons.edit,
            size: 16,
            color: Color(ExpenseService.getStatusColor(status)),
          ),
          const SizedBox(width: 6),
          Text(
            status.displayName,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(ExpenseService.getStatusColor(status)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingApprovalsPanel() {
    return FutureBuilder<List<ExpenseSheet>>(
      future: _pendingSheetsFuture,
      builder: (context, snapshot) {
        // If loading, show nothing (avoid flashing 0 count)
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        
        final pendingCount = snapshot.data?.length ?? 0;
        
        // Don't show panel if no pending approvals (Issue #2 fix)
        if (pendingCount == 0) {
          return const SizedBox.shrink();
        }
        
        return GestureDetector(
          onTap: () => _showPendingApprovalsPopup(),
          child: Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.orange.shade600,
                  Colors.orange.shade400,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.pending_actions, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pending Approvals', style: GoogleFonts.outfit(
                        fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
                      Text(
                        '$pendingCount expense sheet${pendingCount > 1 ? 's' : ''} waiting',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$pendingCount',
                    style: GoogleFonts.outfit(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.orange.shade700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right, color: Colors.white70),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPendingApprovalsPopup() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PendingApprovalsPopup(
        onApproved: () {
          _loadExpenseSheet();
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    String? subtitle,
    bool canAdd = false,
    VoidCallback? onAdd,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: AppTheme.muted),
            const SizedBox(width: 8),
            Text(title, style: GoogleFonts.manrope(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: AppTheme.muted, letterSpacing: 1)),
            if (subtitle != null) ...[
              const SizedBox(width: 8),
              Text('($subtitle)', style: TextStyle(
                fontSize: 12, color: AppTheme.muted)),
            ],
            const Spacer(),
            if (canAdd)
              IconButton(
                icon: Icon(Icons.add_circle, color: AppTheme.success, size: 28),
                onPressed: onAdd,
              ),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  Widget _buildFixedCostsCard(double workerWages) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.people, color: AppTheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Worker Wages', style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w600, fontSize: 15)),
                Text('Auto-pulled from attendance', style: TextStyle(
                  fontSize: 12, color: AppTheme.muted)),
              ],
            ),
          ),
          Row(
            children: [
              const Icon(Icons.lock, size: 14, color: AppTheme.muted),
              const SizedBox(width: 8),
              Text('₹${NumberFormat('#,##0').format(workerWages)}',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.primary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVariableItemsList(List<ExpenseItem> items) {
    if (items.isEmpty) {
      return _buildEmptyCard('No variable expenses yet', Icons.receipt_long);
    }

    return Column(
      children: items.map((item) => _buildExpenseItemCard(item)).toList(),
    );
  }

  Widget _buildMiscItemsList(List<ExpenseItem> items) {
    if (items.isEmpty) {
      return _buildEmptyCard('No misc expenses', Icons.category);
    }

    return Column(
      children: items.map((item) => _buildExpenseItemCard(item)).toList(),
    );
  }

  Widget _buildEmptyCard(String message, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.titaniumBorder, style: BorderStyle.solid),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppTheme.titaniumDark, size: 20),
          const SizedBox(width: 8),
          Text(message, style: TextStyle(color: AppTheme.muted)),
        ],
      ),
    );
  }

  Widget _buildExpenseItemCard(ExpenseItem item) {
    IconData icon;
    switch (item.category) {
      case ExpenseCategory.stitching:
        icon = Icons.content_cut;
        break;
      case ExpenseCategory.loading:
        icon = item.subCategory == LoadingType.in_ ? Icons.download : Icons.upload;
        break;
      case ExpenseCategory.transport:
        icon = Icons.local_shipping;
        break;
      case ExpenseCategory.fuel:
        icon = Icons.local_gas_station;
        break;
      case ExpenseCategory.maintenance:
        icon = Icons.build;
        break;
      default:
        icon = Icons.receipt;
    }

    String subtitle = '';
    if (item.quantity != null && item.rate != null) {
      subtitle = '${item.quantity} × ₹${item.rate!.toStringAsFixed(0)}';
    } else if (item.subCategory != null) {
      subtitle = item.subCategory!.displayName;
    }
    if (item.note != null && item.note!.isNotEmpty) {
      subtitle += subtitle.isEmpty ? item.note! : ' · ${item.note}';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.secondary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppTheme.secondary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.category.displayName, style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w600, fontSize: 14)),
                if (subtitle.isNotEmpty)
                  Text(subtitle, style: TextStyle(
                    fontSize: 12, color: AppTheme.muted),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (item.receiptUrl != null && item.receiptUrl!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.image, color: AppTheme.success, size: 18),
            ),
          Text('₹${NumberFormat('#,##0').format(item.amount)}',
            style: GoogleFonts.outfit(
              fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.secondary)),
        ],
      ),
    );
  }

  Widget _buildGrandTotal(double total) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.primary, AppTheme.primary.withOpacity(0.85)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('GRAND TOTAL', style: GoogleFonts.manrope(
            fontSize: 14, fontWeight: FontWeight.w700,
            color: Colors.white70, letterSpacing: 1)),
          Text('₹${NumberFormat('#,##0').format(total)}',
            style: GoogleFonts.outfit(
              fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
        ],
      ),
    );
  }

  Widget _buildCartSection(ExpenseSheet? sheet) {
    return Consumer<ExpenseCartService>(
      builder: (context, cart, _) {
        if (cart.isEmpty) return const SizedBox.shrink();
        
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.warning.withOpacity(0.3), width: 2),
            boxShadow: [BoxShadow(color: AppTheme.warning.withOpacity(0.1), blurRadius: 10)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.shopping_cart, color: AppTheme.warning),
                  const SizedBox(width: 8),
                  Text('Draft Cart', style: GoogleFonts.outfit(
                    fontWeight: FontWeight.bold, fontSize: 16)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('${cart.itemCount} items',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.warning)),
                  ),
                ],
              ),
              const Divider(height: 20),
              // Cart items list
              ...cart.items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.displayLabel, style: GoogleFonts.outfit(fontWeight: FontWeight.w500)),
                          if (item.note != null && item.note!.isNotEmpty)
                            Text(item.note!, style: TextStyle(fontSize: 12, color: AppTheme.muted),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Text('₹${item.amount.toStringAsFixed(0)}',
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => cart.removeItem(item.id),
                      child: Icon(Icons.close, size: 18, color: AppTheme.danger),
                    ),
                  ],
                ),
              )),
              const Divider(height: 16),
              // Total and Save button
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Cart Total', style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                      Text('₹${cart.totalAmount.toStringAsFixed(0)}',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 18)),
                    ],
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Clear'),
                    style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
                    onPressed: () => _confirmClearCart(cart),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.save, size: 18),
                    label: const Text('Save All'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.success,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onPressed: () => _saveCartToSheet(cart),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmClearCart(ExpenseCartService cart) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Cart?'),
        content: Text('Remove all ${cart.itemCount} items from the cart?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm == true) await cart.clearCart();
  }

  Future<void> _saveCartToSheet(ExpenseCartService cart) async {
    if (cart.isEmpty) return;
    
    // Non-admin users go through approval workflow
    if (!_isAdmin) {
      await _requestExpenseApproval(cart);
      return;
    }
    
    // Admin flow - save directly
    final service = Provider.of<ExpenseService>(context, listen: false);
    
    // Save each cart item using the selected date
    int savedCount = 0;
    for (final item in cart.items) {
      final success = await service.addExpenseItem(
        date: _selectedDate,
        category: item.category,
        subCategory: item.subCategory,
        quantity: item.quantity,
        rate: item.rate,
        amount: item.amount,
        note: item.note,
      );
      if (success) savedCount++;
    }
    
    if (savedCount > 0) {
      await cart.clearCart();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved $savedCount expenses to sheet'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    }
  }

  /// Request approval for expense items (for non-admin users)
  Future<void> _requestExpenseApproval(ExpenseCartService cart) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId') ?? '';
    final userName = prefs.getString('username') ?? 'Unknown User';

    // Capture cart data before clearing
    final expenseItems = cart.items.map((item) => {
      'category': item.category.name,
      'subCategory': item.subCategory,
      'quantity': item.quantity,
      'rate': item.rate,
      'amount': item.amount,
      'note': item.note,
    }).toList();
    final itemCount = cart.itemCount;
    final totalAmount = cart.totalAmount;
    final selectedDate = _selectedDate;

    // Clear cart immediately (optimistic)
    await cart.clearCart();

    fireAndForget(
      type: 'submit_expense_approval',
      apiCall: () => _apiService.createApprovalRequest({
        'requesterId': userId,
        'requesterName': userName,
        'actionType': 'add_expense',
        'resourceType': 'expense',
        'resourceId': 'expense_${selectedDate}_${DateTime.now().millisecondsSinceEpoch}',
        'resourceData': {'date': selectedDate, 'itemCount': itemCount, 'totalAmount': totalAmount},
        'proposedChanges': {'items': expenseItems},
        'reason': 'Expense request for $selectedDate',
      }),
      successMessage: 'Expense request submitted for approval',
      failureMessage: 'Failed to submit expense request',
    );
  }

  Widget _buildActionButtons(ExpenseSheet sheet) {
    // If pending, show withdraw button
    if (sheet.status == ExpenseStatus.pending) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.warning.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.schedule, color: AppTheme.warning),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Waiting for Admin Approval', style: GoogleFonts.outfit(
                        fontWeight: FontWeight.w600, color: AppTheme.warning)),
                      Text('Submitted by ${sheet.submittedBy ?? 'you'}',
                        style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.undo),
                label: const Text('Withdraw Submission'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.warning,
                  side: BorderSide(color: AppTheme.warning),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () => _withdrawSubmission(sheet),
              ),
            ),
          ],
        ),
      );
    }
    
    // If approved, show read-only message
    if (sheet.status == ExpenseStatus.approved) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.success.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.success.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle, color: AppTheme.success),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Approved', style: GoogleFonts.outfit(
                    fontWeight: FontWeight.w600, color: AppTheme.success)),
                  if (sheet.approvedBy != null)
                    Text('By ${sheet.approvedBy}',
                      style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    
    // Default: draft or rejected - show save/submit buttons
    final isAdmin = ['superadmin', 'admin', 'ops'].contains(Provider.of<AuthProvider>(context, listen: false).role?.toLowerCase());
    
    // For admin: just show Save button (no need to submit to themselves)
    // For non-admin: show Save Draft + Submit for Approval (Issue #3 fix)
    if (isAdmin) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.save),
          label: const Text('Save Expenses'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: () => _saveDraft(sheet),
        ),
      );
    }
    
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save Draft'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: const BorderSide(color: AppTheme.primary),
            ),
            onPressed: () => _saveDraft(sheet),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.send),
            label: const Text('Submit for Approval'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () => _submitForApproval(sheet),
          ),
        ),
      ],
    );
  }

  Widget _buildRejectionNote(String reason) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.danger.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.danger.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: AppTheme.danger),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Rejected', style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w600, color: AppTheme.danger)),
                Text(reason, style: TextStyle(
                  fontSize: 13, color: AppTheme.danger.withOpacity(0.8))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildFAB() {
    // Always show FAB - users can add multiple expenses per day
    // regardless of pending approval status
    return FloatingActionButton.extended(
      onPressed: () => _showAddExpenseModal(isVariable: true),
      icon: const Icon(Icons.add),
      label: const Text('Add Expense'),
      backgroundColor: AppTheme.success,
    );
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_selectedDate) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );

    if (picked != null) {
      setState(() {
        _selectedDate = DateFormat('yyyy-MM-dd').format(picked);
      });
      _loadExpenseSheet();
    }
  }

  void _showAddExpenseModal({bool isVariable = true}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.titaniumLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _AddExpenseModal(
        date: _selectedDate,
        isVariable: isVariable,
        onSaved: _loadExpenseSheet,
      ),
    );
  }

  Future<void> _saveDraft(ExpenseSheet sheet) async {
    // Already saved since we auto-save on add
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Draft saved'),
        backgroundColor: AppTheme.success,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _submitForApproval(ExpenseSheet sheet) async {
    if (sheet.id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please add at least one expense first'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final service = Provider.of<ExpenseService>(context, listen: false);
    final sheetId = sheet.id!;
    final username = auth.username ?? 'Unknown';

    fireAndForget(
      type: 'submit_expense',
      apiCall: () => service.submitForApproval(sheetId, username),
      onSuccess: () {
        if (mounted) _loadExpenseSheet();
      },
      successMessage: 'Expense submitted for approval',
      failureMessage: 'Failed to submit expense',
    );
  }

  Future<void> _withdrawSubmission(ExpenseSheet sheet) async {
    if (sheet.id == null) return;
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Withdraw Submission?', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        content: Text(
          'This will cancel your pending submission and allow you to make changes.',
          style: GoogleFonts.outfit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.warning),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final service = Provider.of<ExpenseService>(context, listen: false);
    final success = await service.withdrawExpenseSheet(sheet.id!);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Submission withdrawn' : 'Failed to withdraw'),
          backgroundColor: success ? AppTheme.success : AppTheme.danger,
        ),
      );
    }
  }
}

// ========== Add Expense Modal ==========
class _AddExpenseModal extends StatefulWidget {
  final String date;
  final bool isVariable;
  final VoidCallback onSaved;

  const _AddExpenseModal({
    required this.date,
    required this.isVariable,
    required this.onSaved,
  });

  @override
  State<_AddExpenseModal> createState() => _AddExpenseModalState();
}

class _AddExpenseModalState extends State<_AddExpenseModal> {
  ExpenseCategory _selectedCategory = ExpenseCategory.stitching;
  LoadingType _selectedLoadingType = LoadingType.out;
  final _quantityController = TextEditingController();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  
  // Dual bag type controllers for stitching
  final _looseBagsController = TextEditingController();
  final _parcelBagsController = TextEditingController();
  
  // Stitching rates
  static const double _looseBagRate = 35.0;
  static const double _parcelBagRate = 40.0;
  
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (!widget.isVariable) {
      _selectedCategory = ExpenseCategory.misc;
    }
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _amountController.dispose();
    _noteController.dispose();
    _looseBagsController.dispose();
    _parcelBagsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Add Expense', style: GoogleFonts.outfit(
                  fontSize: 20, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            
            const Divider(height: 24),
            
            // Category selector
            if (widget.isVariable) ...[
              Text('Category', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ExpenseCategory.stitching,
                  ExpenseCategory.loading,
                  ExpenseCategory.transport,
                  ExpenseCategory.fuel,
                  ExpenseCategory.maintenance,
                ].map((cat) => ChoiceChip(
                  label: Text(cat.displayName),
                  selected: _selectedCategory == cat,
                  selectedColor: AppTheme.primary.withOpacity(0.2),
                  onSelected: (sel) {
                    if (sel) setState(() => _selectedCategory = cat);
                  },
                )).toList(),
              ),
              const SizedBox(height: 20),
            ],
            
            // Stitching specific: dual bag quantity fields
            if (_selectedCategory == ExpenseCategory.stitching) ...[
              Text('Number of Bags', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  // Loose Bags field
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('Loose Bags', style: GoogleFonts.outfit(
                              fontWeight: FontWeight.w500, fontSize: 13)),
                            const Spacer(),
                            Text('₹${_looseBagRate.toInt()}/bag', style: TextStyle(
                              fontSize: 11, color: AppTheme.success, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _looseBagsController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600),
                          decoration: InputDecoration(
                            hintText: '0',
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Parcel Bags field
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('Parcel Bags', style: GoogleFonts.outfit(
                              fontWeight: FontWeight.w500, fontSize: 13)),
                            const Spacer(),
                            Text('₹${_parcelBagRate.toInt()}/bag', style: TextStyle(
                              fontSize: 11, color: AppTheme.success, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _parcelBagsController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600),
                          decoration: InputDecoration(
                            hintText: '0',
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Combined amount display
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.success.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.success.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Total Calculation', style: GoogleFonts.outfit(
                          fontWeight: FontWeight.w500, fontSize: 12, color: AppTheme.muted)),
                        Text(_getStitchingBreakdown(), style: TextStyle(
                          fontSize: 11, color: AppTheme.muted)),
                      ],
                    ),
                    Text('₹${_getStitchingTotal().toStringAsFixed(0)}',
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.bold, fontSize: 20, color: AppTheme.success)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
            
            // Loading specific: type selector
            if (_selectedCategory == ExpenseCategory.loading) ...[
              Text('Type', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: LoadingType.values.map((type) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            type == LoadingType.in_ ? Icons.download : Icons.upload,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(type.displayName.split('(').first.trim()),
                        ],
                      ),
                      selected: _selectedLoadingType == type,
                      selectedColor: AppTheme.primary.withOpacity(0.2),
                      onSelected: (sel) {
                        if (sel) setState(() => _selectedLoadingType = type);
                      },
                    ),
                  ),
                )).toList(),
              ),
              const SizedBox(height: 20),
            ],
            
            // Amount field (for non-stitching items)
            if (_selectedCategory != ExpenseCategory.stitching) ...[
              Text('Amount', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'Enter amount',
                  prefixText: '₹ ',
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
              const SizedBox(height: 20),
            ],
            
            // Note field
            Text('Note', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _noteController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: _selectedCategory == ExpenseCategory.misc
                    ? 'Required for misc expenses'
                    : 'Optional description',
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Cart indicator
            Consumer<ExpenseCartService>(
              builder: (context, cart, _) => cart.isNotEmpty
                ? Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.shopping_cart, color: AppTheme.primary, size: 20),
                        const SizedBox(width: 8),
                        Text('${cart.itemCount} items in cart', 
                          style: GoogleFonts.outfit(fontWeight: FontWeight.w500)),
                        const Spacer(),
                        Text('₹${cart.totalAmount.toStringAsFixed(0)}',
                          style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: AppTheme.primary)),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
            ),
            
            // Dual buttons for continuous entry
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add & Continue'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: AppTheme.primary),
                    ),
                    onPressed: () => _addExpense(addMore: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Add & Close'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () => _addExpense(addMore: false),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Stitching helper methods for dual bag types
  int get _looseBags => int.tryParse(_looseBagsController.text) ?? 0;
  int get _parcelBags => int.tryParse(_parcelBagsController.text) ?? 0;
  int get _totalBags => _looseBags + _parcelBags;

  double _getStitchingTotal() {
    return (_looseBags * _looseBagRate) + (_parcelBags * _parcelBagRate);
  }

  String _getStitchingBreakdown() {
    final parts = <String>[];
    if (_looseBags > 0) parts.add('$_looseBags × ₹${_looseBagRate.toInt()}');
    if (_parcelBags > 0) parts.add('$_parcelBags × ₹${_parcelBagRate.toInt()}');
    return parts.isEmpty ? 'Enter bag counts' : parts.join(' + ');
  }

  double _getCalculatedAmount() {
    // For backward compatibility - now uses stitching total
    return _getStitchingTotal();
  }

  void _calculateStitchingAmount() {
    setState(() {});
  }

  Future<void> _addExpense({bool addMore = false}) async {
    // Validate
    double amount;
    int? quantity;
    
    if (_selectedCategory == ExpenseCategory.stitching) {
      // Validate: at least one bag type must have count > 0
      if (_looseBags <= 0 && _parcelBags <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter at least one bag count')),
        );
        return;
      }
      quantity = _totalBags;
      amount = _getStitchingTotal();
    } else {
      amount = double.tryParse(_amountController.text) ?? 0;
      if (amount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter valid amount')),
        );
        return;
      }
    }

    // Validate note for misc
    if (_selectedCategory == ExpenseCategory.misc && _noteController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Note is required for miscellaneous expenses')),
      );
      return;
    }

    // Build note for stitching with bag breakdown
    String? note = _noteController.text.isNotEmpty ? _noteController.text : null;
    if (_selectedCategory == ExpenseCategory.stitching) {
      final bagParts = <String>[];
      if (_looseBags > 0) bagParts.add('$_looseBags Loose');
      if (_parcelBags > 0) bagParts.add('$_parcelBags Parcel');
      final bagDesc = bagParts.join(' + ');
      note = note != null ? '$bagDesc · $note' : bagDesc;
    }
    
    // Calculate average rate for display (weighted average)
    double? rate;
    if (_selectedCategory == ExpenseCategory.stitching && _totalBags > 0) {
      rate = amount / _totalBags;
    }
    
    // Add to cart
    final cart = Provider.of<ExpenseCartService>(context, listen: false);
    await cart.addItem(
      category: _selectedCategory,
      subCategory: _selectedCategory == ExpenseCategory.loading ? _selectedLoadingType : null,
      quantity: quantity,
      rate: rate,
      amount: amount,
      note: note,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.shopping_cart, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text('Added to cart (${cart.itemCount} items)'),
            ],
          ),
          backgroundColor: AppTheme.success,
          duration: const Duration(seconds: 1),
        ),
      );
      
      if (addMore) {
        // Reset form for next entry
        _resetForm();
      } else {
        Navigator.pop(context);
        widget.onSaved();
      }
    }
  }

  void _resetForm() {
    setState(() {
      _amountController.clear();
      _noteController.clear();
      _looseBagsController.clear();
      _parcelBagsController.clear();
      _selectedCategory = ExpenseCategory.stitching;
      _selectedLoadingType = LoadingType.out;
    });
  }
}

// ========== Pending Approvals Popup (Admin) ==========
class _PendingApprovalsPopup extends StatefulWidget {
  final VoidCallback onApproved;

  const _PendingApprovalsPopup({required this.onApproved});

  @override
  State<_PendingApprovalsPopup> createState() => _PendingApprovalsPopupState();
}

class _PendingApprovalsPopupState extends State<_PendingApprovalsPopup> {
  List<ExpenseSheet> _pendingSheets = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPendingSheets();
  }

  Future<void> _loadPendingSheets() async {
    setState(() => _isLoading = true);
    final service = Provider.of<ExpenseService>(context, listen: false);
    _pendingSheets = await service.loadPendingSheets();
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Pending Approvals', style: GoogleFonts.outfit(
                  fontSize: 20, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _pendingSheets.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_outline, 
                              size: 64, color: AppTheme.success),
                            const SizedBox(height: 16),
                            Text('All caught up!', style: GoogleFonts.outfit(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text('No pending approvals', 
                              style: TextStyle(color: AppTheme.muted)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _pendingSheets.length,
                        itemBuilder: (ctx, index) => _buildPendingCard(_pendingSheets[index]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingCard(ExpenseSheet sheet) {
    final date = DateTime.tryParse(sheet.date) ?? DateTime.now();
    final formattedDate = DateFormat('EEE, MMM d, yyyy').format(date);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.titaniumBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today, size: 18, color: Colors.orange.shade700),
                const SizedBox(width: 8),
                Text(formattedDate, style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w600, fontSize: 15)),
                const Spacer(),
                Text('₹${NumberFormat('#,##0').format(sheet.grandTotal)}',
                  style: GoogleFonts.outfit(
                    fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.primary)),
              ],
            ),
          ),
          // Items summary
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Submitted by: ${sheet.submittedBy ?? 'Unknown'}',
                  style: TextStyle(fontSize: 13, color: AppTheme.muted)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildMiniStat('Wages', '₹${NumberFormat('#,##0').format(sheet.workerWages)}'),
                    _buildMiniStat('Variable', '₹${NumberFormat('#,##0').format(sheet.totalVariable)}'),
                    _buildMiniStat('Misc', '₹${NumberFormat('#,##0').format(sheet.totalMisc)}'),
                  ],
                ),
                if (sheet.items.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Items:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.muted)),
                  const SizedBox(height: 4),
                  ...sheet.items.take(3).map((item) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Text('• ${item.category.displayName}', style: TextStyle(fontSize: 12)),
                        const Spacer(),
                        Text('₹${NumberFormat('#,##0').format(item.amount)}', 
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  )),
                  if (sheet.items.length > 3)
                    Text('  ... and ${sheet.items.length - 3} more', 
                      style: TextStyle(fontSize: 11, color: AppTheme.muted, fontStyle: FontStyle.italic)),
                ],
              ],
            ),
          ),
          // Action buttons
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.titaniumLight.withOpacity(0.5),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Reject'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      side: BorderSide(color: AppTheme.danger),
                    ),
                    onPressed: () => _showRejectDialog(sheet),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Approve'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.success,
                    ),
                    onPressed: () => _approveSheet(sheet),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: AppTheme.muted)),
          Text(value, style: GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _approveSheet(ExpenseSheet sheet) async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final service = Provider.of<ExpenseService>(context, listen: false);

    final success = await service.approveSheet(sheet.id!, auth.username ?? 'admin');

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approved expense for ${sheet.date}'), backgroundColor: AppTheme.success),
      );
      _loadPendingSheets();
      if (_pendingSheets.isEmpty) {
        widget.onApproved();
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Failed to approve'), backgroundColor: AppTheme.danger),
      );
    }
  }

  void _showRejectDialog(ExpenseSheet sheet) {
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Expense Sheet'),
        content: TextField(
          controller: reasonController,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Enter rejection reason...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () async {
              if (reasonController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a reason')),
                );
                return;
              }

              Navigator.pop(ctx);

              final auth = Provider.of<AuthProvider>(context, listen: false);
              final service = Provider.of<ExpenseService>(context, listen: false);

              final success = await service.rejectSheet(
                sheet.id!,
                auth.username ?? 'admin',
                reasonController.text,
              );

              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Rejected expense for ${sheet.date}'), backgroundColor: Colors.orange),
                );
                _loadPendingSheets();
              }
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }
}
