import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../models/gate_pass.dart';
import '../../services/gate_pass_service.dart';
import '../../services/gate_pass_cache.dart';
import '../../services/auth_provider.dart';
import 'gate_pass_form.dart';
import 'gate_pass_approval.dart';
import 'gate_pass_tracking.dart';

/// Gate Pass List - Shows all gate passes with filters
class GatePassList extends StatefulWidget {
  const GatePassList({super.key});

  @override
  State<GatePassList> createState() => _GatePassListState();
}

class _GatePassListState extends State<GatePassList> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _filter = 'all'; // all, pending, approved, rejected

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadPasses();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadPasses() async {
    final service = Provider.of<GatePassService>(context, listen: false);
    await service.loadPasses();
    await service.loadPendingPasses();
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final isAdmin = auth.role?.toLowerCase() == 'superadmin' || auth.role?.toLowerCase() == 'admin' || auth.role?.toLowerCase() == 'ops'; // Case-insensitive check

    return Scaffold(
      backgroundColor: AppTheme.titaniumLight,
      appBar: AppBar(
        title: Text('Gate Passes', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        backgroundColor: AppTheme.titaniumMid,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          onTap: (index) {
            setState(() {
              _filter = ['all', 'pending', 'approved', 'rejected'][index];
            });
          },
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.muted,
          indicatorColor: AppTheme.primary,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Pending'),
            Tab(text: 'Approved'),
            Tab(text: 'Rejected'),
          ],
        ),
        actions: [
          if (isAdmin)
            Consumer<GatePassService>(
              builder: (context, service, _) => service.pendingCount > 0
                  ? Badge(
                      label: Text('${service.pendingCount}'),
                      child: IconButton(
                        icon: const Icon(Icons.approval),
                        onPressed: () => _showPendingApprovals(service),
                        tooltip: 'Pending Approvals',
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
      body: Column(
        children: [
          // Offline indicator
          Consumer<GatePassCache>(
            builder: (context, cache, _) => cache.isOffline
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    color: AppTheme.warning.withOpacity(0.2),
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_off, size: 18, color: AppTheme.warning),
                        const SizedBox(width: 8),
                        Text('Offline mode - changes will sync when connected',
                            style: TextStyle(fontSize: 13, color: AppTheme.warning, fontWeight: FontWeight.w500)),
                        if (cache.pendingCount > 0) ...[
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.warning,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('${cache.pendingCount} pending',
                                style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          // Main list
          Expanded(
            child: Consumer<GatePassService>(
              builder: (context, service, _) {
                if (service.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                final filteredPasses = _getFilteredPasses(service.passes);

                if (filteredPasses.isEmpty) {
                  return _buildEmptyState();
                }

                return RefreshIndicator(
                  onRefresh: _loadPasses,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filteredPasses.length,
                    itemBuilder: (context, index) => _buildPassCard(filteredPasses[index]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createPass,
        icon: const Icon(Icons.add),
        label: const Text('New Pass'),
      ),
    );
  }

  List<GatePass> _getFilteredPasses(List<GatePass> passes) {
    switch (_filter) {
      case 'pending':
        return passes.where((p) => p.status == GatePassStatus.pending).toList();
      case 'approved':
        return passes.where((p) => p.status == GatePassStatus.approved).toList();
      case 'rejected':
        return passes.where((p) => p.status == GatePassStatus.rejected).toList();
      default:
        return passes;
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined, size: 64, color: AppTheme.muted.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text('No gate passes found', style: GoogleFonts.outfit(
              fontSize: 18, fontWeight: FontWeight.w500, color: AppTheme.muted)),
          const SizedBox(height: 8),
          Text('Create a new pass to get started', style: TextStyle(color: AppTheme.muted)),
        ],
      ),
    );
  }

  Widget _buildPassCard(GatePass pass) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () => _viewPass(pass),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: pass.type == GatePassType.entry
                          ? AppTheme.success.withOpacity(0.1)
                          : AppTheme.warning.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          pass.type == GatePassType.entry ? Icons.arrow_downward : Icons.arrow_upward,
                          size: 14,
                          color: pass.type == GatePassType.entry ? AppTheme.success : AppTheme.warning,
                        ),
                        const SizedBox(width: 4),
                        Text(pass.typeDisplay, style: GoogleFonts.outfit(
                            fontSize: 12, fontWeight: FontWeight.w600,
                            color: pass.type == GatePassType.entry ? AppTheme.success : AppTheme.warning)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(pass.passNumber, style: GoogleFonts.outfit(
                      fontWeight: FontWeight.bold, fontSize: 16)),
                  const Spacer(),
                  _buildStatusBadge(pass.status),
                ],
              ),
              const SizedBox(height: 12),
              Text(pass.weightSummary, style: GoogleFonts.outfit(fontSize: 14)),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.calendar_today, size: 14, color: AppTheme.muted),
                  const SizedBox(width: 4),
                  Text(DateFormat('MMM d, y · h:mm a').format(pass.requestedAt),
                      style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                  const Spacer(),
                  Text(pass.purposeDisplay, style: TextStyle(
                      fontSize: 12, color: AppTheme.muted, fontWeight: FontWeight.w500)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(GatePassStatus status) {
    Color color;
    String label;
    
    switch (status) {
      case GatePassStatus.pending:
        color = AppTheme.warning;
        label = 'Pending';
        break;
      case GatePassStatus.approved:
        color = AppTheme.success;
        label = 'Approved';
        break;
      case GatePassStatus.rejected:
        color = AppTheme.danger;
        label = 'Rejected';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(label, style: TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Future<void> _createPass() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GatePassForm()),
    );

    if (result != null) {
      _loadPasses();
    }
  }

  void _viewPass(GatePass pass) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final isAdmin = auth.role?.toLowerCase() == 'superadmin' || auth.role?.toLowerCase() == 'admin' || auth.role?.toLowerCase() == 'ops'; // Case-insensitive check

    if (isAdmin && pass.isPending) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => GatePassApproval(pass: pass)),
      ).then((_) => _loadPasses());
    } else if (pass.isApproved && !pass.isCompleted) {
      // Show tracking screen for approved passes
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => GatePassTracking(pass: pass)),
      ).then((_) => _loadPasses());
    } else {
      _showPassDetails(pass);
    }
  }

  void _showPassDetails(GatePass pass) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.muted.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Text(pass.passNumber, style: GoogleFonts.outfit(
                      fontSize: 24, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  _buildStatusBadge(pass.status),
                ],
              ),
              const SizedBox(height: 16),
              _buildDetailRow('Type', pass.typeDisplay),
              _buildDetailRow('Weight', pass.weightSummary),
              _buildDetailRow('Purpose', pass.purposeDisplay),
              if (pass.vehicleNumber?.isNotEmpty == true)
                _buildDetailRow('Vehicle', pass.vehicleNumber!),
              if (pass.driverName?.isNotEmpty == true)
                _buildDetailRow('Driver', '${pass.driverName}${pass.driverPhone?.isNotEmpty == true ? ' (${pass.driverPhone})' : ''}'),
              if (pass.notes?.isNotEmpty == true)
                _buildDetailRow('Notes', pass.notes!),
              _buildDetailRow('Requested by', pass.requestedBy),
              _buildDetailRow('Requested at', DateFormat('MMM d, y · h:mm a').format(pass.requestedAt)),
              if (pass.approvedBy?.isNotEmpty == true)
                _buildDetailRow('Approved by', pass.approvedBy!),
              if (pass.rejectionReason?.isNotEmpty == true)
                _buildDetailRow('Rejection reason', pass.rejectionReason!, isError: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: TextStyle(
                fontSize: 13, color: AppTheme.muted, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(value, style: GoogleFonts.outfit(
                fontSize: 14, fontWeight: FontWeight.w500,
                color: isError ? AppTheme.danger : AppTheme.title)),
          ),
        ],
      ),
    );
  }

  void _showPendingApprovals(GatePassService service) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Text('Pending Approvals', style: GoogleFonts.outfit(
                      fontSize: 20, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('${service.pendingPasses.length}',
                        style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.warning)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: service.pendingPasses.length,
                itemBuilder: (context, index) {
                  final pass = service.pendingPasses[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: pass.type == GatePassType.entry
                            ? AppTheme.success.withOpacity(0.1)
                            : AppTheme.warning.withOpacity(0.1),
                        child: Icon(
                          pass.type == GatePassType.entry ? Icons.arrow_downward : Icons.arrow_upward,
                          color: pass.type == GatePassType.entry ? AppTheme.success : AppTheme.warning,
                        ),
                      ),
                      title: Text(pass.passNumber, style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
                      subtitle: Text('${pass.finalWeight.toInt()}kg · ${pass.purposeDisplay}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => GatePassApproval(pass: pass)),
                        ).then((_) => _loadPasses());
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
