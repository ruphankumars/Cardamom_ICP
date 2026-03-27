import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/gate_pass.dart';
import '../../services/gate_pass_service.dart';
import '../../services/auth_provider.dart';

/// Web-optimized Gate Pass list with filters, create/edit.
class WebGatePasses extends StatefulWidget {
  const WebGatePasses({super.key});

  @override
  State<WebGatePasses> createState() => _WebGatePassesState();
}

class _WebGatePassesState extends State<WebGatePasses> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _headerBg = Color(0xFFF1F5F9);
  static const _cardRadius = 12.0;

  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _loadPasses();
  }

  Future<void> _loadPasses() async {
    try {
      final service = Provider.of<GatePassService>(context, listen: false);
      await service.loadPasses();
      await service.loadPendingPasses();
    } catch (e) {
      debugPrint('Error loading gate passes: $e');
    }
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

  void _showCreateDialog({GatePass? existing}) {
    final isEdit = existing != null;
    GatePassType selectedType = existing?.type ?? GatePassType.exit;
    GatePassPackaging selectedPackaging = existing?.packaging ?? GatePassPackaging.bag;
    GatePassPurpose selectedPurpose = existing?.purpose ?? GatePassPurpose.transport;
    final bagCountCtrl = TextEditingController(text: existing?.bagCount.toString() ?? '0');
    final boxCountCtrl = TextEditingController(text: existing?.boxCount.toString() ?? '0');
    final actualWeightCtrl = TextEditingController(text: existing?.actualWeight.toString() ?? '');
    final vehicleCtrl = TextEditingController(text: existing?.vehicleNumber ?? '');
    final driverNameCtrl = TextEditingController(text: existing?.driverName ?? '');
    final driverPhoneCtrl = TextEditingController(text: existing?.driverPhone ?? '');
    final notesCtrl = TextEditingController(text: existing?.notes ?? '');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Text(
              isEdit ? 'Edit Gate Pass' : 'New Gate Pass',
              style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: _primary),
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Type', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                              const SizedBox(height: 4),
                              DropdownButtonFormField<GatePassType>(
                                value: selectedType,
                                decoration: _fieldDecoration(),
                                items: GatePassType.values
                                    .map((t) => DropdownMenuItem(value: t, child: Text(t.name.toUpperCase(), style: GoogleFonts.inter(fontSize: 14))))
                                    .toList(),
                                onChanged: (v) => setDialogState(() => selectedType = v ?? selectedType),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Purpose', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                              const SizedBox(height: 4),
                              DropdownButtonFormField<GatePassPurpose>(
                                value: selectedPurpose,
                                decoration: _fieldDecoration(),
                                items: GatePassPurpose.values.map((p) {
                                  final label = p == GatePassPurpose.return_ ? 'RETURN' : p.name.toUpperCase();
                                  return DropdownMenuItem(value: p, child: Text(label, style: GoogleFonts.inter(fontSize: 14)));
                                }).toList(),
                                onChanged: (v) => setDialogState(() => selectedPurpose = v ?? selectedPurpose),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Packaging', style: GoogleFonts.inter(fontSize: 13, color: _primary)),
                    const SizedBox(height: 4),
                    DropdownButtonFormField<GatePassPackaging>(
                      value: selectedPackaging,
                      decoration: _fieldDecoration(),
                      items: GatePassPackaging.values
                          .map((p) => DropdownMenuItem(value: p, child: Text(p.name.toUpperCase(), style: GoogleFonts.inter(fontSize: 14))))
                          .toList(),
                      onChanged: (v) => setDialogState(() => selectedPackaging = v ?? selectedPackaging),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _dialogField('Bag Count', bagCountCtrl, isNumber: true)),
                        const SizedBox(width: 12),
                        Expanded(child: _dialogField('Box Count', boxCountCtrl, isNumber: true)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _dialogField('Actual Weight (kg)', actualWeightCtrl, isNumber: true),
                    const SizedBox(height: 12),
                    _dialogField('Vehicle Number', vehicleCtrl),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _dialogField('Driver Name', driverNameCtrl)),
                        const SizedBox(width: 12),
                        Expanded(child: _dialogField('Driver Phone', driverPhoneCtrl)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _dialogField('Notes', notesCtrl, maxLines: 2),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: GoogleFonts.inter(color: _primary)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _primary),
                onPressed: () async {
                  final auth = Provider.of<AuthProvider>(context, listen: false);
                  final bags = int.tryParse(bagCountCtrl.text) ?? 0;
                  final boxes = int.tryParse(boxCountCtrl.text) ?? 0;
                  final actualWeight = double.tryParse(actualWeightCtrl.text) ?? 0;

                  try {
                    final service = Provider.of<GatePassService>(context, listen: false);
                    if (isEdit) {
                      final data = {
                        'type': selectedType.name,
                        'packaging': selectedPackaging.name,
                        'purpose': selectedPurpose == GatePassPurpose.return_ ? 'return' : selectedPurpose.name,
                        'bagCount': bags,
                        'boxCount': boxes,
                        'actualWeight': actualWeight > 0 ? actualWeight : null,
                        'vehicleNumber': vehicleCtrl.text.trim(),
                        'driverName': driverNameCtrl.text.trim(),
                        'driverPhone': driverPhoneCtrl.text.trim(),
                        'notes': notesCtrl.text.trim(),
                      };
                      await service.updatePass(existing.id, data);
                    } else {
                      await service.createPass(
                        type: selectedType,
                        packaging: selectedPackaging,
                        purpose: selectedPurpose,
                        bagCount: bags,
                        boxCount: boxes,
                        actualWeight: actualWeight > 0 ? actualWeight : null,
                        vehicleNumber: vehicleCtrl.text.trim().isNotEmpty ? vehicleCtrl.text.trim() : null,
                        driverName: driverNameCtrl.text.trim().isNotEmpty ? driverNameCtrl.text.trim() : null,
                        driverPhone: driverPhoneCtrl.text.trim().isNotEmpty ? driverPhoneCtrl.text.trim() : null,
                        notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                        requestedBy: auth.username ?? 'web',
                      );
                    }
                    if (mounted) Navigator.pop(ctx);
                    _loadPasses();
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
                child: Text(isEdit ? 'Update' : 'Create', style: GoogleFonts.inter()),
              ),
            ],
          );
        },
      ),
    );
  }

  InputDecoration _fieldDecoration() {
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _primary.withOpacity(0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _primary.withOpacity(0.2)),
      ),
    );
  }

  Widget _dialogField(String label, TextEditingController ctrl, {bool isNumber = false, int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.inter(fontSize: 13, color: _primary)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          maxLines: maxLines,
          keyboardType: isNumber ? TextInputType.number : TextInputType.text,
          style: GoogleFonts.inter(fontSize: 14),
          decoration: _fieldDecoration(),
        ),
      ],
    );
  }

  Future<void> _approvePass(GatePass pass) async {
    try {
      final service = Provider.of<GatePassService>(context, listen: false);
      await service.approvePass(pass.id);
      _loadPasses();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gate pass approved'), backgroundColor: const Color(0xFF10B981)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _rejectPass(GatePass pass) async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reject Gate Pass', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Reject pass ${pass.passNumber}?', style: GoogleFonts.inter()),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              decoration: _fieldDecoration().copyWith(hintText: 'Reason for rejection'),
              maxLines: 2,
              style: GoogleFonts.inter(fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reject', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        final service = Provider.of<GatePassService>(context, listen: false);
        await service.rejectPass(pass.id, reasonCtrl.text.trim());
        _loadPasses();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final isAdmin = auth.role?.toLowerCase() == 'superadmin' ||
        auth.role?.toLowerCase() == 'admin' ||
        auth.role?.toLowerCase() == 'ops';

    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          _buildFilters(),
          Expanded(
            child: Consumer<GatePassService>(
              builder: (context, service, _) {
                if (service.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }
                final filtered = _getFilteredPasses(service.passes);
                if (filtered.isEmpty) return _buildEmptyState();
                return _buildPassTable(filtered, isAdmin);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Gate Passes',
                    style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
                const SizedBox(height: 4),
                Text('Track material entry and exit',
                    style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
              ],
            ),
          ),
          Consumer<GatePassService>(
            builder: (context, service, _) {
              if (service.pendingCount > 0) {
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Badge(
                    label: Text('${service.pendingCount}'),
                    child: const Icon(Icons.approval, color: Color(0xFFF59E0B), size: 28),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _primary,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => _showCreateDialog(),
            icon: const Icon(Icons.add, size: 18),
            label: Text('New Gate Pass', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    final filters = [
      ('all', 'All'),
      ('pending', 'Pending'),
      ('approved', 'Approved'),
      ('rejected', 'Rejected'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 12),
      child: Row(
        children: [
          ...filters.map((f) {
            final isActive = _filter == f.$1;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.$2, style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w500,
                  color: isActive ? Colors.white : _primary,
                )),
                selected: isActive,
                selectedColor: _primary,
                backgroundColor: Colors.white,
                side: BorderSide(color: _primary.withOpacity(0.2)),
                onSelected: (_) => setState(() => _filter = f.$1),
              ),
            );
          }),
          const Spacer(),
          IconButton(icon: const Icon(Icons.refresh, color: _primary), onPressed: _loadPasses),
        ],
      ),
    );
  }

  Widget _buildPassTable(List<GatePass> passes, bool isAdmin) {
    return Container(
      margin: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_cardRadius),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(_headerBg),
            headingTextStyle: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: _primary, letterSpacing: 0.5),
            dataTextStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
            columnSpacing: 20,
            horizontalMargin: 20,
            columns: const [
              DataColumn(label: Text('PASS #')),
              DataColumn(label: Text('TYPE')),
              DataColumn(label: Text('PURPOSE')),
              DataColumn(label: Text('PACKAGING')),
              DataColumn(label: Text('WEIGHT')),
              DataColumn(label: Text('VEHICLE')),
              DataColumn(label: Text('STATUS')),
              DataColumn(label: Text('DATE')),
              DataColumn(label: Text('ACTIONS')),
            ],
            rows: passes.map((pass) {
              return DataRow(cells: [
                DataCell(Text(pass.passNumber, style: GoogleFonts.manrope(fontWeight: FontWeight.w600))),
                DataCell(_typeChip(pass.type)),
                DataCell(Text(pass.purpose == GatePassPurpose.return_ ? 'Return' : pass.purpose.name)),
                DataCell(Text(pass.packaging.name)),
                DataCell(Text('${pass.finalWeight.toStringAsFixed(1)} kg')),
                DataCell(Text(pass.vehicleNumber ?? '-')),
                DataCell(_statusChip(pass.status)),
                DataCell(Text(DateFormat('MMM d').format(pass.requestedAt))),
                DataCell(Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pass.status == GatePassStatus.pending && isAdmin) ...[
                      IconButton(
                        icon: const Icon(Icons.check_circle_outline, size: 18, color: Color(0xFF10B981)),
                        tooltip: 'Approve',
                        onPressed: () => _approvePass(pass),
                      ),
                      IconButton(
                        icon: const Icon(Icons.cancel_outlined, size: 18, color: Color(0xFFEF4444)),
                        tooltip: 'Reject',
                        onPressed: () => _rejectPass(pass),
                      ),
                    ],
                    if (pass.status == GatePassStatus.pending)
                      IconButton(
                        icon: Icon(Icons.edit_outlined, size: 18, color: _primary.withOpacity(0.7)),
                        tooltip: 'Edit',
                        onPressed: () => _showCreateDialog(existing: pass),
                      ),
                  ],
                )),
              ]);
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _typeChip(GatePassType type) {
    final isEntry = type == GatePassType.entry;
    final color = isEntry ? const Color(0xFF3B82F6) : const Color(0xFFF59E0B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isEntry ? Icons.arrow_downward : Icons.arrow_upward, size: 12, color: color),
          const SizedBox(width: 4),
          Text(type.name.toUpperCase(), style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  Widget _statusChip(GatePassStatus status) {
    Color color;
    switch (status) {
      case GatePassStatus.pending:
        color = const Color(0xFFF59E0B);
        break;
      case GatePassStatus.approved:
        color = const Color(0xFF10B981);
        break;
      case GatePassStatus.rejected:
        color = const Color(0xFFEF4444);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
      child: Text(status.name.toUpperCase(), style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.receipt_long, size: 64, color: _primary.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('No gate passes found', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w700, color: _primary)),
          const SizedBox(height: 8),
          Text('Create a new gate pass to get started',
              style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
        ],
      ),
    );
  }
}
