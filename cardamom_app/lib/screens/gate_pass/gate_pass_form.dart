import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../models/gate_pass.dart';
import '../../services/gate_pass_service.dart';
import '../../services/auth_provider.dart';
import '../../services/api_service.dart';

/// Gate Pass Request Form - Create new entry/exit request
class GatePassForm extends StatefulWidget {
  final GatePass? editPass; // If provided, editing existing pass

  const GatePassForm({super.key, this.editPass});

  @override
  State<GatePassForm> createState() => _GatePassFormState();
}

class _GatePassFormState extends State<GatePassForm> {
  GatePassType _type = GatePassType.exit;
  GatePassPackaging _packaging = GatePassPackaging.bag;
  GatePassPurpose _purpose = GatePassPurpose.transport;

  final _bagCountController = TextEditingController();
  final _boxCountController = TextEditingController();
  final _actualWeightController = TextEditingController();
  final _notesController = TextEditingController();
  final _vehicleController = TextEditingController();
  final _driverNameController = TextEditingController();
  final _driverPhoneController = TextEditingController();

  static const double _bagWeight = 50;
  static const double _boxWeight = 20;

  bool _isLoading = false;
  bool _editingWeight = false;
  DateTime? _expectedReturnDate;

  @override
  void initState() {
    super.initState();
    if (widget.editPass != null) {
      _type = widget.editPass!.type;
      _packaging = widget.editPass!.packaging;
      _purpose = widget.editPass!.purpose;
      _bagCountController.text = widget.editPass!.bagCount.toString();
      _boxCountController.text = widget.editPass!.boxCount.toString();
      _actualWeightController.text = widget.editPass!.actualWeight.toString();
      _notesController.text = widget.editPass!.notes ?? '';
      _vehicleController.text = widget.editPass!.vehicleNumber ?? '';
      _driverNameController.text = widget.editPass!.driverName ?? '';
      _driverPhoneController.text = widget.editPass!.driverPhone ?? '';
    }
  }

  @override
  void dispose() {
    _bagCountController.dispose();
    _boxCountController.dispose();
    _actualWeightController.dispose();
    _notesController.dispose();
    _vehicleController.dispose();
    _driverNameController.dispose();
    _driverPhoneController.dispose();
    super.dispose();
  }

  int get _bagCount => int.tryParse(_bagCountController.text) ?? 0;
  int get _boxCount => int.tryParse(_boxCountController.text) ?? 0;
  double get _calculatedWeight => (_bagCount * _bagWeight) + (_boxCount * _boxWeight);

  double get _displayWeight {
    if (_editingWeight) {
      return double.tryParse(_actualWeightController.text) ?? _calculatedWeight;
    }
    return _calculatedWeight;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editPass != null ? 'Edit Gate Pass' : 'New Gate Pass',
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        backgroundColor: AppTheme.titaniumMid,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Type selector
            _buildSectionLabel('TYPE'),
            _buildTypeSelector(),
            const SizedBox(height: 24),

            // Packaging selector
            _buildSectionLabel('PACKAGING'),
            _buildPackagingSelector(),
            const SizedBox(height: 24),

            // Quantities
            _buildQuantityInputs(),
            const SizedBox(height: 24),

            // Weight display
            _buildWeightDisplay(),
            const SizedBox(height: 24),

            // Purpose
            _buildSectionLabel('PURPOSE'),
            _buildPurposeSelector(),
            const SizedBox(height: 24),

            // Notes
            _buildSectionLabel('NOTES'),
            TextField(
              controller: _notesController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'Enter notes (optional)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),

            // Vehicle details
            _buildSectionLabel('VEHICLE DETAILS (Optional)'),
            TextField(
              controller: _vehicleController,
              decoration: InputDecoration(
                labelText: 'Vehicle Number',
                hintText: 'e.g. KL-07-AB-1234',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _driverNameController,
                    decoration: InputDecoration(
                      labelText: 'Driver Name',
                      hintText: 'Optional',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _driverPhoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: 'Driver Phone',
                      hintText: 'Optional',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
            // Expected return date (for exit passes)
            if (_type == GatePassType.exit) ...[
              const SizedBox(height: 24),
              _buildSectionLabel('EXPECTED RETURN DATE (Optional)'),
              _buildReturnDatePicker(),
            ],
            const SizedBox(height: 32),

            // Submit button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _submitRequest,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text('Submit Request', style: GoogleFonts.outfit(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(label, style: GoogleFonts.manrope(
          fontSize: 12, fontWeight: FontWeight.w700,
          color: AppTheme.muted, letterSpacing: 1)),
    );
  }

  Widget _buildTypeSelector() {
    return Row(
      children: [
        _buildTypeChip(GatePassType.entry, 'Entry Pass', 'Goods entering factory'),
        const SizedBox(width: 12),
        _buildTypeChip(GatePassType.exit, 'Exit Pass', 'Goods leaving factory'),
      ],
    );
  }

  Widget _buildTypeChip(GatePassType type, String label, String subtitle) {
    final isSelected = _type == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _type = type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primary : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? AppTheme.primary : AppTheme.titaniumBorder,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Text(label, style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w600,
                  color: isSelected ? Colors.white : AppTheme.title)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(
                  fontSize: 11,
                  color: isSelected ? Colors.white70 : AppTheme.muted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPackagingSelector() {
    return Row(
      children: [
        _buildPackagingChip(GatePassPackaging.bag, 'Bag (50kg)'),
        const SizedBox(width: 8),
        _buildPackagingChip(GatePassPackaging.box, 'Box (20kg)'),
        const SizedBox(width: 8),
        _buildPackagingChip(GatePassPackaging.mixed, 'Mixed'),
      ],
    );
  }

  Widget _buildPackagingChip(GatePassPackaging packaging, String label) {
    final isSelected = _packaging == packaging;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _packaging = packaging),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primary.withOpacity(0.1) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? AppTheme.primary : AppTheme.titaniumBorder,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Center(
            child: Text(label, style: GoogleFonts.outfit(
                fontSize: 13, fontWeight: FontWeight.w500,
                color: isSelected ? AppTheme.primary : AppTheme.title)),
          ),
        ),
      ),
    );
  }

  Widget _buildQuantityInputs() {
    final showBags = _packaging == GatePassPackaging.bag || _packaging == GatePassPackaging.mixed;
    final showBoxes = _packaging == GatePassPackaging.box || _packaging == GatePassPackaging.mixed;

    return Row(
      children: [
        if (showBags)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bags', style: GoogleFonts.outfit(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                TextField(
                  controller: _bagCountController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '0',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
        if (showBags && showBoxes) const SizedBox(width: 16),
        if (showBoxes)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Boxes', style: GoogleFonts.outfit(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                TextField(
                  controller: _boxCountController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '0',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildWeightDisplay() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('CALCULATED WEIGHT', style: GoogleFonts.manrope(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  color: AppTheme.muted, letterSpacing: 0.5)),
              GestureDetector(
                onTap: () => setState(() {
                  _editingWeight = !_editingWeight;
                  if (_editingWeight) {
                    _actualWeightController.text = _calculatedWeight.toString();
                  }
                }),
                child: Icon(_editingWeight ? Icons.check : Icons.edit,
                    size: 18, color: AppTheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _editingWeight
              ? TextField(
                  controller: _actualWeightController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    suffix: Text('kg'),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                )
              : Text('${_displayWeight.toInt()} kg', style: GoogleFonts.outfit(
                    fontSize: 28, fontWeight: FontWeight.bold, color: AppTheme.primary)),
          if (!_editingWeight)
            Text('(Tap ✏️ to edit if weighbridge differs)',
                style: TextStyle(fontSize: 12, color: AppTheme.muted)),
        ],
      ),
    );
  }

  Widget _buildPurposeSelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildPurposeChip(GatePassPurpose.auction, 'Auction'),
        _buildPurposeChip(GatePassPurpose.transport, 'Transport'),
        _buildPurposeChip(GatePassPurpose.local, 'Local'),
        _buildPurposeChip(GatePassPurpose.return_, 'Return'),
      ],
    );
  }

  Widget _buildPurposeChip(GatePassPurpose purpose, String label) {
    final isSelected = _purpose == purpose;
    return GestureDetector(
      onTap: () => setState(() => _purpose = purpose),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.titaniumBorder,
          ),
        ),
        child: Text(label, style: GoogleFonts.outfit(
            fontWeight: FontWeight.w500,
            color: isSelected ? Colors.white : AppTheme.title)),
      ),
    );
  }

  Widget _buildReturnDatePicker() {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _expectedReturnDate ?? DateTime.now().add(const Duration(days: 1)),
          firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (picked != null) {
          setState(() => _expectedReturnDate = picked);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.titaniumBorder),
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today, size: 18, color: AppTheme.muted),
            const SizedBox(width: 12),
            Text(
              _expectedReturnDate != null
                  ? DateFormat('MMM d, yyyy').format(_expectedReturnDate!)
                  : 'Select expected return date',
              style: TextStyle(
                fontSize: 14,
                color: _expectedReturnDate != null ? AppTheme.title : AppTheme.muted,
              ),
            ),
            const Spacer(),
            if (_expectedReturnDate != null)
              GestureDetector(
                onTap: () => setState(() => _expectedReturnDate = null),
                child: Icon(Icons.close, size: 18, color: AppTheme.muted),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitRequest() async {
    // Validate
    if (_bagCount <= 0 && _boxCount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter at least one bag or box count')),
      );
      return;
    }

    setState(() => _isLoading = true);

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final service = Provider.of<GatePassService>(context, listen: false);
    final role = (auth.role ?? '').toLowerCase().trim();
    final isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';

    final actualWeight = _editingWeight
        ? double.tryParse(_actualWeightController.text) ?? _calculatedWeight
        : _calculatedWeight;

    // Build gate pass data
    final calculatedWeight = (_bagCount * _bagWeight) + (_boxCount * _boxWeight);
    final gatePassData = {
      'type': _type.name,
      'packaging': _packaging.name,
      'bagCount': _bagCount,
      'boxCount': _boxCount,
      'bagWeight': _bagWeight,
      'boxWeight': _boxWeight,
      'calculatedWeight': calculatedWeight,
      'actualWeight': actualWeight,
      'finalWeight': actualWeight,
      'purpose': _purpose.name,
      'notes': _notesController.text.isEmpty ? null : _notesController.text,
      'vehicleNumber': _vehicleController.text.isEmpty ? null : _vehicleController.text,
      'driverName': _driverNameController.text.isEmpty ? null : _driverNameController.text,
      'driverPhone': _driverPhoneController.text.isEmpty ? null : _driverPhoneController.text,
      'expectedReturn': _expectedReturnDate?.toIso8601String(),
      'requestedBy': auth.username ?? 'unknown',
    };

    if (!isAdmin) {
      // Non-admin: Create approval request instead
      try {
        final apiService = ApiService();
        await apiService.createApprovalRequest({
          'requesterId': auth.userId ?? auth.username,
          'requesterName': auth.username ?? 'Unknown',
          'actionType': 'create',
          'resourceType': 'gatepass',
          'resourceId': 0,
          'resourceData': gatePassData,
          'reason': 'Gate pass request: ${_type.name} - ${_purpose.name}',
        });
        
        if (mounted) {
          setState(() => _isLoading = false);
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('📋 Gate pass request sent for approval'),
              backgroundColor: Color(0xFF3B82F6),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to submit request: $e')),
          );
        }
      }
      return;
    }

    // Admin: Create pass directly
    final pass = await service.createPass(
      type: _type,
      packaging: _packaging,
      bagCount: _bagCount,
      boxCount: _boxCount,
      actualWeight: actualWeight,
      purpose: _purpose,
      notes: _notesController.text.isEmpty ? null : _notesController.text,
      vehicleNumber: _vehicleController.text.isEmpty ? null : _vehicleController.text,
      driverName: _driverNameController.text.isEmpty ? null : _driverNameController.text,
      driverPhone: _driverPhoneController.text.isEmpty ? null : _driverPhoneController.text,
      requestedBy: auth.username ?? 'unknown',
    );

    if (mounted) {
      setState(() => _isLoading = false);

      if (pass != null) {
        Navigator.pop(context, pass);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gate pass ${pass.passNumber} created'),
            backgroundColor: AppTheme.success,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to create gate pass')),
        );
      }
    }
  }
}
