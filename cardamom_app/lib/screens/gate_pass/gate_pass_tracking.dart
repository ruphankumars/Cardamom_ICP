import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../models/gate_pass.dart';
import '../../services/gate_pass_service.dart';
import '../../services/auth_provider.dart';

/// Gate Pass Tracking Screen - For security to record entry/exit
class GatePassTracking extends StatefulWidget {
  final GatePass pass;

  const GatePassTracking({super.key, required this.pass});

  @override
  State<GatePassTracking> createState() => _GatePassTrackingState();
}

class _GatePassTrackingState extends State<GatePassTracking> {
  bool _isLoading = false;
  late GatePass _currentPass;

  @override
  void initState() {
    super.initState();
    _currentPass = widget.pass;
  }

  Future<void> _handleAction(Future<bool> Function() action, String successMsg) async {
    setState(() => _isLoading = true);
    try {
      final success = await action();
      if (!mounted) return;
      if (success) {
        final service = Provider.of<GatePassService>(context, listen: false);
        final updated = service.passes.where((p) => p.id == _currentPass.id).firstOrNull;
        if (updated != null) setState(() => _currentPass = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successMsg), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.danger),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<GatePassService>(context, listen: false);

    return Scaffold(
      backgroundColor: AppTheme.titaniumLight,
      appBar: AppBar(
        title: Text('Track Pass', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        backgroundColor: AppTheme.titaniumMid,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              // Refresh this specific pass if needed
              await service.loadPasses();
              if (!mounted) return;
              final fresh = service.passes.where((p) => p.id == _currentPass.id).firstOrNull;
              if (fresh != null) setState(() => _currentPass = fresh);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Pass Card (The "Physical" Pass look)
            _buildPassCard(),
            const SizedBox(height: 32),

            // Tracking Controls
            _buildTrackingSection(service),
            
            const SizedBox(height: 40),
            
            // Helpful Info
            _buildInfoBox(),
          ],
        ),
      ),
    );
  }

  Widget _buildPassCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _currentPass.status == GatePassStatus.approved 
                  ? AppTheme.success.withOpacity(0.1) 
                  : AppTheme.muted.withOpacity(0.1),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Row(
              children: [
                Icon(
                  _currentPass.type == GatePassType.entry ? Icons.download : Icons.upload,
                  color: _currentPass.type == GatePassType.entry ? AppTheme.success : AppTheme.warning,
                ),
                const SizedBox(width: 8),
                Text(
                  'DIGITAL GATE PASS · ${_currentPass.typeDisplay.toUpperCase()}',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: AppTheme.muted,
                  ),
                ),
                const Spacer(),
                _buildSmallStatusBadge(),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // Digital ID / Pass Number
                Text(
                  _currentPass.passNumber,
                  style: GoogleFonts.outfit(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Valid ID: ${_currentPass.id.substring(0, 8).toUpperCase()}',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
                
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Divider(),
                ),

                _buildDetailRow('Vehicle', _currentPass.vehicleNumber ?? 'Not specified'),
                _buildDetailRow('Driver', _currentPass.driverName ?? 'Not specified'),
                _buildDetailRow('Weight', _currentPass.weightSummary),
                _buildDetailRow('Purpose', _currentPass.purposeDisplay),
                _buildDetailRow('Requested By', _currentPass.requestedBy),
                
                if (_currentPass.approvedBy != null)
                  _buildDetailRow('Approved By', _currentPass.approvedBy!),

                const SizedBox(height: 16),
                
                // Timeline Style Tracking Info
                _buildTimeline(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmallStatusBadge() {
    final color = _currentPass.isCompleted ? AppTheme.primary : AppTheme.success;
    final label = _currentPass.isCompleted ? 'Completed' : 'Valid';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: AppTheme.muted, fontSize: 13)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    return Column(
      children: [
        _buildTimelineItem(
          'Approved',
          _currentPass.approvedAt != null 
              ? DateFormat('HH:mm').format(_currentPass.approvedAt!)
              : '--:--',
          _currentPass.approvedAt != null,
          true,
        ),
        _buildTimelineItem(
          'Entry Recorded',
          _currentPass.actualEntryTime != null 
              ? DateFormat('HH:mm').format(_currentPass.actualEntryTime!)
              : '--:--',
          _currentPass.actualEntryTime != null,
          true,
        ),
        _buildTimelineItem(
          'Exit Recorded',
          _currentPass.actualExitTime != null 
              ? DateFormat('HH:mm').format(_currentPass.actualExitTime!)
              : '--:--',
          _currentPass.actualExitTime != null,
          false,
        ),
      ],
    );
  }

  Widget _buildTimelineItem(String label, String time, bool isDone, bool hasNext) {
    return IntrinsicHeight(
      child: Row(
        children: [
          Column(
            children: [
              Container(
                width: 12, height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone ? AppTheme.success : AppTheme.muted.withOpacity(0.3),
                ),
              ),
              if (hasNext)
                Expanded(
                  child: Container(
                    width: 2,
                    color: isDone ? AppTheme.success : AppTheme.muted.withOpacity(0.3),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label, style: TextStyle(
                    fontWeight: isDone ? FontWeight.bold : FontWeight.normal,
                    color: isDone ? AppTheme.title : AppTheme.muted,
                  )),
                  Text(time, style: TextStyle(
                    fontFamily: 'Courier',
                    color: isDone ? AppTheme.primary : AppTheme.muted,
                  )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackingSection(GatePassService service) {
    if (_currentPass.isCompleted) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            const Icon(Icons.verified, color: AppTheme.primary, size: 48),
            const SizedBox(height: 12),
            Text(
              'PASS COMPLETED',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'This pass is no longer active.',
              style: TextStyle(color: AppTheme.muted),
            ),
          ],
        ),
      );
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final role = (auth.role ?? '').toLowerCase().trim();
    final isGuard = role == 'guard' || role == 'security';

    return Column(
      children: [
        // Guards can only record entry/exit times
        if (_currentPass.canRecordEntry)
          _buildActionButton(
            label: 'Record Factory Entry',
            icon: Icons.login,
            color: AppTheme.success,
            onPressed: () => _handleAction(
              () => service.recordEntry(_currentPass.id),
              'Entry recorded at ${DateFormat('HH:mm').format(DateTime.now())}',
            ),
          ),

        if (_currentPass.canRecordExit)
          _buildActionButton(
            label: 'Record Factory Exit',
            icon: Icons.logout,
            color: AppTheme.warning,
            onPressed: () => _showExitFlow(service),
          ),

        // Only admin/ops can finalize - guards cannot
        if (_currentPass.canComplete && !isGuard)
          _buildActionButton(
            label: 'Finalize & Complete',
            icon: Icons.check_circle,
            color: AppTheme.primary,
            onPressed: () => _handleAction(
              () => service.completePass(_currentPass.id),
              'Pass completed and closed.',
            ),
          ),

        if (_currentPass.canComplete && isGuard)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.amber, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'An admin must finalize this pass.',
                    style: TextStyle(fontSize: 13, color: AppTheme.muted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Simplified exit flow: confirm dialog -> record exit
  Future<void> _showExitFlow(GatePassService service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Confirm Exit', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        content: const Text('Confirm exit recording for this gate pass?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.warning),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Exit'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _handleAction(
      () => service.recordExit(_currentPass.id),
      'Exit recorded at ${DateFormat('HH:mm').format(DateTime.now())}',
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        width: double.infinity,
        height: 60,
        child: ElevatedButton.icon(
          onPressed: _isLoading ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 0,
          ),
          icon: Icon(icon),
          label: Text(
            label,
            style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoBox() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 20, color: AppTheme.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Security Checklist:\n1. Verify vehicle number matches\n2. Check driver identity\n3. Confirm material quantity matches pass',
              style: TextStyle(fontSize: 12, color: AppTheme.muted, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
