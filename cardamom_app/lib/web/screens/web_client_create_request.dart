import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_service.dart';

class WebClientCreateRequest extends StatefulWidget {
  final String? initialType;
  const WebClientCreateRequest({super.key, this.initialType});

  @override
  State<WebClientCreateRequest> createState() => _WebClientCreateRequestState();
}

class _WebClientCreateRequestState extends State<WebClientCreateRequest> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _cardRadius = 12.0;

  final ApiService _apiService = ApiService();
  final TextEditingController _notesController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  bool _isSubmitting = false;
  List<String> _grades = [];
  List<String> _brands = [];
  String _selectedType = '';
  final List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _selectedType = widget.initialType ?? '';
    _loadGrades();
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadGrades() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getDropdownOptions();
      if (!mounted) return;
      setState(() {
        _grades = List<String>.from(response.data['grade'] ?? []);
        _brands = List<String>.from(response.data['brand'] ?? [
          'Emperor Magenta Pink', 'Emperor Green', 'Emperor Gold',
          'ESPL Premium', 'SYGT Standard', 'Custom Brand',
        ]);
        if (_items.isEmpty) _addItem();
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (_items.isEmpty) _addItem();
        _isLoading = false;
      });
    }
  }

  void _addItem() {
    setState(() {
      _items.add({
        'grade': _grades.isNotEmpty ? _grades.first : '8 mm',
        'bagbox': 'Bag',
        'no': 0,
        'kgs': 0,
        'brand': '',
        'notes': '',
      });
    });
  }

  void _removeItem(int index) {
    if (_items.length > 1) {
      setState(() => _items.removeAt(index));
    }
  }

  void _updateQuantity(int index, num no) {
    setState(() {
      final item = _items[index];
      item['no'] = no;
      final multiplier = item['bagbox'] == 'Bag' ? 50 : 20;
      item['kgs'] = no * multiplier;
    });
  }

  Future<void> _submitRequest() async {
    if (!_formKey.currentState!.validate()) return;

    for (int i = 0; i < _items.length; i++) {
      final item = _items[i];
      final no = item['no'] is num ? (item['no'] as num) : 0;
      if (no <= 0) {
        _showSnack('Item ${i + 1} (${item['grade']}): Quantity must be greater than 0');
        return;
      }
    }

    setState(() => _isSubmitting = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username') ?? '';
      final clientName = prefs.getString('clientName') ?? '';

      final payload = {
        'requestType': _selectedType,
        'items': _items,
        'initialText': _notesController.text,
        'username': username,
        if (clientName.isNotEmpty) 'clientName': clientName,
      };

      await _apiService.createClientRequest(payload);
      if (!mounted) return;
      _showSuccessDialog();
    } catch (e) {
      _showSnack('Error: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 44),
            ),
            const SizedBox(height: 16),
            Text('Request Submitted!', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Your ${_selectedType == 'REQUEST_ORDER' ? 'order request' : 'price enquiry'} has been sent to the admin.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF64748B), height: 1.5),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context, true);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_cardRadius)),
                ),
                child: Text('View My Requests', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 24),
                    _buildTypeSelector(),
                    const SizedBox(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Left column: items form
                        Expanded(flex: 3, child: _buildItemsColumn()),
                        const SizedBox(width: 24),
                        // Right column: notes + preview
                        Expanded(flex: 2, child: _buildRightColumn()),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back, color: _primary),
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_cardRadius),
              side: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _selectedType == 'REQUEST_ORDER' ? 'New Order Request' : 'New Price Enquiry',
              style: GoogleFonts.manrope(fontSize: 22, fontWeight: FontWeight.w800, color: const Color(0xFF1A1A2E)),
            ),
            Text(
              'Fill in item details to submit your request',
              style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTypeSelector() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TypeTab(
            label: 'Order Request',
            icon: Icons.inventory_2,
            selected: _selectedType == 'REQUEST_ORDER',
            onTap: () => setState(() => _selectedType = 'REQUEST_ORDER'),
          ),
          _TypeTab(
            label: 'Price Enquiry',
            icon: Icons.currency_rupee,
            selected: _selectedType == 'ENQUIRE_PRICE',
            onTap: () => setState(() => _selectedType = 'ENQUIRE_PRICE'),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Items', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700, color: const Color(0xFF1A1A2E))),
        const SizedBox(height: 12),
        ...List.generate(_items.length, (idx) => _buildItemCard(idx)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _addItem,
          icon: const Icon(Icons.add, size: 18),
          label: Text('Add Item', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            foregroundColor: _primary,
            side: const BorderSide(color: Color(0xFFD1D5DB)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_cardRadius)),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _isSubmitting ? null : _submitRequest,
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _primary.withOpacity(0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_cardRadius)),
            ),
            child: _isSubmitting
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text('Submit Request', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }

  Widget _buildItemCard(int index) {
    final item = _items[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Item ${index + 1}', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: _primary)),
              const Spacer(),
              if (_items.length > 1)
                IconButton(
                  onPressed: () => _removeItem(index),
                  icon: const Icon(Icons.close, size: 18, color: Color(0xFFEF4444)),
                  tooltip: 'Remove item',
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Grade
              Expanded(
                flex: 2,
                child: _buildDropdown(
                  label: 'Grade',
                  value: item['grade'],
                  items: _grades.isNotEmpty ? _grades : ['8 mm', '10 mm', '12 mm'],
                  onChanged: (v) => setState(() => item['grade'] = v),
                ),
              ),
              const SizedBox(width: 12),
              // Bag/Box
              Expanded(
                child: _buildDropdown(
                  label: 'Type',
                  value: item['bagbox'],
                  items: const ['Bag', 'Box'],
                  onChanged: (v) {
                    setState(() {
                      item['bagbox'] = v;
                      final multiplier = v == 'Bag' ? 50 : 20;
                      item['kgs'] = (item['no'] as num) * multiplier;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              // Quantity
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Quantity', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280))),
                    const SizedBox(height: 6),
                    TextFormField(
                      initialValue: item['no'] > 0 ? '${item['no']}' : '',
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (v) => _updateQuantity(index, int.tryParse(v) ?? 0),
                      style: GoogleFonts.inter(fontSize: 14),
                      decoration: _inputDecoration('0'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Kgs (readonly)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total Kgs', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280))),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(_cardRadius),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Text('${item['kgs']} kg', style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF4A5568))),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_brands.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildDropdown(
              label: 'Brand (optional)',
              value: item['brand'].toString().isEmpty ? null : item['brand'],
              items: _brands,
              onChanged: (v) => setState(() => item['brand'] = v),
              allowNull: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required dynamic value,
    required List<String> items,
    required ValueChanged<String> onChanged,
    bool allowNull = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280))),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: allowNull && (value == null || value.toString().isEmpty) ? null : value?.toString(),
          isExpanded: true,
          decoration: _inputDecoration(allowNull ? 'Select...' : ''),
          style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF1A1A2E)),
          items: [
            if (allowNull)
              const DropdownMenuItem<String>(value: null, child: Text('None', style: TextStyle(color: Color(0xFF94A3B8)))),
            ...items.map((i) => DropdownMenuItem(value: i, child: Text(i))),
          ],
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ],
    );
  }

  Widget _buildRightColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Notes
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_cardRadius),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Notes', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: const Color(0xFF1A1A2E))),
              const SizedBox(height: 8),
              TextFormField(
                controller: _notesController,
                maxLines: 5,
                style: GoogleFonts.inter(fontSize: 14),
                decoration: _inputDecoration('Add any special instructions or notes...'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Preview Card
        _buildPreviewCard(),
      ],
    );
  }

  Widget _buildPreviewCard() {
    final totalKgs = _items.fold<num>(0, (sum, item) => sum + (item['kgs'] as num));
    final totalItems = _items.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: _primary.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.preview, size: 18, color: _primary),
              const SizedBox(width: 8),
              Text('Request Preview', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: _primary)),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 12),
          _previewRow('Type', _selectedType == 'REQUEST_ORDER' ? 'Order Request' : 'Price Enquiry'),
          _previewRow('Items', '$totalItems item(s)'),
          _previewRow('Total Weight', '$totalKgs kg'),
          const SizedBox(height: 8),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 8),
          ..._items.asMap().entries.map((e) {
            final i = e.key;
            final item = e.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: _primary.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                    child: Center(child: Text('${i + 1}', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: _primary))),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${item['grade']} - ${item['no']} ${item['bagbox']}(s) - ${item['kgs']} kg',
                      style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF4A5568)),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _previewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF6B7280))),
          Text(value, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF1A1A2E))),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8)),
      filled: true,
      fillColor: const Color(0xFFFAFAFA),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(_cardRadius), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(_cardRadius), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(_cardRadius), borderSide: const BorderSide(color: _primary, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(_cardRadius), borderSide: const BorderSide(color: Color(0xFFEF4444))),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(_cardRadius), borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5)),
    );
  }
}

class _TypeTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _TypeTab({required this.label, required this.icon, required this.selected, required this.onTap});

  static const _primary = Color(0xFF5D6E7E);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? Colors.white : const Color(0xFF6B7280)),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.white : const Color(0xFF6B7280)),
            ),
          ],
        ),
      ),
    );
  }
}
