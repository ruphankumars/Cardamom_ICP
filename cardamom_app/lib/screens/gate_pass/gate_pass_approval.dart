import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../models/gate_pass.dart';
import '../../services/gate_pass_service.dart';

/// Gate Pass Approval Screen - Admin reviews and signs
class GatePassApproval extends StatefulWidget {
  final GatePass pass;

  const GatePassApproval({super.key, required this.pass});

  @override
  State<GatePassApproval> createState() => _GatePassApprovalState();
}

class _GatePassApprovalState extends State<GatePassApproval> {
  final _rejectionController = TextEditingController();
  bool _approvalConfirmed = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _rejectionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.titaniumLight,
      appBar: AppBar(
        title: Text('Approve Gate Pass', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        backgroundColor: AppTheme.titaniumMid,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Pass number
            Center(
              child: Text(widget.pass.passNumber, style: GoogleFonts.outfit(
                  fontSize: 24, fontWeight: FontWeight.bold, color: AppTheme.primary)),
            ),
            const SizedBox(height: 24),

            // Details card
            _buildDetailsCard(),
            const SizedBox(height: 24),

            // Approval confirmation
            _buildConfirmationArea(),
            const SizedBox(height: 24),

            // Action buttons
            _buildActionButtons(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                widget.pass.type == GatePassType.entry ? Icons.arrow_downward : Icons.arrow_upward,
                color: widget.pass.type == GatePassType.entry ? AppTheme.success : AppTheme.warning,
                size: 28,
              ),
              const SizedBox(width: 12),
              Text('${widget.pass.typeDisplay.toUpperCase()} REQUEST',
                  style: GoogleFonts.outfit(
                      fontSize: 16, fontWeight: FontWeight.bold,
                      color: widget.pass.type == GatePassType.entry ? AppTheme.success : AppTheme.warning)),
            ],
          ),
          const Divider(height: 24),
          _buildDetailRow('Item', 'Cardamom'),
          if (widget.pass.bagCount > 0)
            _buildDetailRow('Bags', '${widget.pass.bagCount} × ${widget.pass.bagWeight.toInt()}kg = ${(widget.pass.bagCount * widget.pass.bagWeight).toInt()}kg'),
          if (widget.pass.boxCount > 0)
            _buildDetailRow('Boxes', '${widget.pass.boxCount} × ${widget.pass.boxWeight.toInt()}kg = ${(widget.pass.boxCount * widget.pass.boxWeight).toInt()}kg'),
          _buildDetailRow('Total Weight', '${widget.pass.finalWeight.toInt()} kg', isBold: true),
          const Divider(height: 24),
          _buildDetailRow('Purpose', widget.pass.purposeDisplay),
          if (widget.pass.notes?.isNotEmpty == true)
            _buildDetailRow('Notes', widget.pass.notes!),
          if (widget.pass.vehicleNumber?.isNotEmpty == true)
            _buildDetailRow('Vehicle', widget.pass.vehicleNumber!),
          if (widget.pass.driverName?.isNotEmpty == true)
            _buildDetailRow('Driver', widget.pass.driverName!),
          const Divider(height: 24),
          _buildDetailRow('Requested by', widget.pass.requestedBy),
          _buildDetailRow('Time', DateFormat('h:mm a, MMM d, yyyy').format(widget.pass.requestedAt)),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
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
                fontSize: 14,
                fontWeight: isBold ? FontWeight.bold : FontWeight.w500,
                color: AppTheme.title)),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmationArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF22C55E).withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Checkbox(
            value: _approvalConfirmed,
            onChanged: (v) => setState(() => _approvalConfirmed = v ?? false),
            activeColor: const Color(0xFF22C55E),
          ),
          const Expanded(
            child: Text(
              'I confirm this gate pass is approved for the stated purpose',
              style: TextStyle(fontSize: 13, color: Color(0xFF4A5568)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.close),
            label: const Text('Reject'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.danger,
              side: const BorderSide(color: AppTheme.danger),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _isLoading ? null : _showRejectDialog,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            icon: _isLoading
                ? const SizedBox(height: 16, width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check),
            label: const Text('Approve'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.success,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _isLoading ? null : _approve,
          ),
        ),
      ],
    );
  }

  Future<void> _approve() async {
    if (!_approvalConfirmed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please confirm approval by checking the box')),
      );
      return;
    }

    setState(() => _isLoading = true);

    final service = Provider.of<GatePassService>(context, listen: false);
    final success = await service.approvePass(widget.pass.id);

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${widget.pass.passNumber} approved'),
          backgroundColor: AppTheme.success,
        ),
      );
    } else {
      final errorMsg = service.error ?? 'Failed to approve gate pass';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMsg),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _showRejectDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Reject Gate Pass', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Please provide a reason for rejection:'),
            const SizedBox(height: 12),
            TextField(
              controller: _rejectionController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Enter reason...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () async {
              if (_rejectionController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a reason')),
                );
                return;
              }

              Navigator.pop(context);
              setState(() => _isLoading = true);

              final service = Provider.of<GatePassService>(context, listen: false);
              final success = await service.rejectPass(widget.pass.id, _rejectionController.text);

              if (!mounted) return;

              setState(() => _isLoading = false);

              if (success) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${widget.pass.passNumber} rejected'),
                    backgroundColor: AppTheme.danger,
                  ),
                );
              }
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }
}
