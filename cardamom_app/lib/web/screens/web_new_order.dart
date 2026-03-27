import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

class WebNewOrder extends StatefulWidget {
  final Map<String, dynamic>? prefillData;

  const WebNewOrder({super.key, this.prefillData});

  @override
  State<WebNewOrder> createState() => _WebNewOrderState();
}

class _WebNewOrderState extends State<WebNewOrder> {
  final ApiService _apiService = ApiService();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = true;
  bool _isSubmitting = false;

  Map<String, dynamic> _dropdowns = {};
  String _userRole = 'user';

  // Form controllers
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final _lotController = TextEditingController();
  final _notesController = TextEditingController();
  final _qtyController = TextEditingController();
  final _priceController = TextEditingController();

  // Dropdown selections
  String? _selectedClient;
  String? _selectedGrade;
  String? _selectedBrand;
  String? _selectedBagBox;
  String _billingFrom = 'SYGT';
  String _status = 'Pending';

  // Client search
  final _clientSearchController = TextEditingController();
  bool _showClientDropdown = false;
  List<String> _filteredClients = [];

  double get _totalAmount {
    final qty = double.tryParse(_qtyController.text) ?? 0;
    final price = double.tryParse(_priceController.text) ?? 0;
    return qty * price;
  }

  @override
  void initState() {
    super.initState();
    _loadDropdowns();
    if (widget.prefillData != null) {
      _applyPrefill(widget.prefillData!);
    }
  }

  @override
  void dispose() {
    _dateController.dispose();
    _lotController.dispose();
    _notesController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    _clientSearchController.dispose();
    super.dispose();
  }

  void _applyPrefill(Map<String, dynamic> data) {
    if (data['client'] != null) {
      _selectedClient = data['client'].toString();
      _clientSearchController.text = _selectedClient!;
    }
    if (data['grade'] != null) _selectedGrade = data['grade'].toString();
    if (data['brand'] != null) _selectedBrand = data['brand'].toString();
    if (data['lot'] != null) _lotController.text = data['lot'].toString();
    if (data['kgs'] != null) _qtyController.text = data['kgs'].toString();
    if (data['price'] != null) _priceController.text = data['price'].toString();
    if (data['notes'] != null) _notesController.text = data['notes'].toString();
  }

  Future<void> _loadDropdowns() async {
    try {
      _userRole = await _apiService.getUserRole() ?? 'user';
    } catch (_) {}

    try {
      final response = await _apiService.getDropdownOptions();
      final data = response.data as Map<String, dynamic>;
      if (mounted) setState(() => _dropdowns = data);
    } catch (e) {
      debugPrint('Error loading dropdowns: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  List<String> _getDropdownList(String key) {
    final list = _dropdowns[key];
    if (list is! List) return [];
    return list.map((item) {
      if (item is Map) {
        return (item['value'] ?? item['name'] ?? item.toString()).toString();
      }
      return item.toString();
    }).where((s) => s.isNotEmpty).toList();
  }

  void _filterClients(String query) {
    final clients = _getDropdownList('client');
    if (query.isEmpty) {
      _filteredClients = clients;
    } else {
      _filteredClients = clients
          .where((c) => c.toLowerCase().contains(query.toLowerCase()))
          .toList();
    }
    setState(() => _showClientDropdown = _filteredClients.isNotEmpty);
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_dateController.text) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (date != null) {
      setState(() {
        _dateController.text = DateFormat('yyyy-MM-dd').format(date);
      });
    }
  }

  Future<void> _submitOrder() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedClient == null || _selectedClient!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a client'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final kgs = double.tryParse(_qtyController.text) ?? 0;
      final price = double.tryParse(_priceController.text) ?? 0;
      final bagbox = _selectedBagBox ?? 'Bag';
      final multiplier = bagbox == 'Bag' ? 50 : (bagbox == 'Box' ? 20 : 1);
      final no = multiplier > 0 ? (kgs / multiplier) : 0;

      final orderData = {
        'orderDate': _dateController.text,
        'billingFrom': _billingFrom,
        'client': _selectedClient,
        'lot': _lotController.text,
        'grade': _selectedGrade ?? '',
        'bagbox': bagbox,
        'no': no,
        'kgs': kgs,
        'price': price,
        'brand': _selectedBrand ?? '',
        'status': _status,
        'notes': _notesController.text,
      };

      await _apiService.addOrder(orderData);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order created successfully'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
        _resetForm();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating order: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }

    if (mounted) setState(() => _isSubmitting = false);
  }

  void _resetForm() {
    setState(() {
      _selectedClient = null;
      _selectedGrade = null;
      _selectedBrand = null;
      _selectedBagBox = null;
      _billingFrom = 'SYGT';
      _status = 'Pending';
      _clientSearchController.clear();
      _lotController.clear();
      _notesController.clear();
      _qtyController.clear();
      _priceController.clear();
      _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF5D6E7E)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 24),
                  _buildFormCard(),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Text(
          'New Order',
          style: GoogleFonts.manrope(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF1E293B),
          ),
        ),
        const Spacer(),
        if (_totalAmount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFF10B981).withOpacity(0.3)),
            ),
            child: Text(
              'Total: ${_formatCurrency(_totalAmount)}',
              style: GoogleFonts.manrope(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF10B981),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFormCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('Order Details'),
                      const SizedBox(height: 16),
                      _buildClientField(),
                      const SizedBox(height: 16),
                      _buildDateField(),
                      const SizedBox(height: 16),
                      _buildTextField(
                        label: 'Lot Number',
                        controller: _lotController,
                        hint: 'e.g. L1',
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        label: 'Notes',
                        controller: _notesController,
                        hint: 'Optional notes',
                        maxLines: 3,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                // Right column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('Product & Pricing'),
                      const SizedBox(height: 16),
                      _buildFormDropdown(
                        label: 'Grade',
                        value: _selectedGrade,
                        items: _getDropdownList('grade'),
                        onChanged: (v) =>
                            setState(() => _selectedGrade = v),
                      ),
                      const SizedBox(height: 16),
                      _buildFormDropdown(
                        label: 'Brand',
                        value: _selectedBrand,
                        items: _getDropdownList('brand'),
                        onChanged: (v) =>
                            setState(() => _selectedBrand = v),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _buildFormDropdown(
                              label: 'Bag/Box',
                              value: _selectedBagBox,
                              items: _getDropdownList('bagbox').isNotEmpty
                                  ? _getDropdownList('bagbox')
                                  : const ['Bag', 'Box'],
                              onChanged: (v) =>
                                  setState(() => _selectedBagBox = v),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildTextField(
                              label: 'Qty (kgs)',
                              controller: _qtyController,
                              hint: '0',
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                    RegExp(r'[\d.]')),
                              ],
                              onChanged: (_) => setState(() {}),
                              validator: (v) {
                                if (v == null || v.isEmpty) {
                                  return 'Required';
                                }
                                if (double.tryParse(v) == null) {
                                  return 'Invalid number';
                                }
                                return null;
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        label: 'Price per kg',
                        controller: _priceController,
                        hint: '0',
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[\d.]')),
                        ],
                        onChanged: (_) => setState(() {}),
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Required';
                          if (double.tryParse(v) == null) {
                            return 'Invalid number';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _buildFormDropdown(
                              label: 'Billing',
                              value: _billingFrom,
                              items: const ['SYGT', 'ESPL'],
                              onChanged: (v) {
                                if (v != null) {
                                  setState(() => _billingFrom = v);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildFormDropdown(
                              label: 'Status',
                              value: _status,
                              items: const [
                                'Pending',
                                'On Progress',
                                'Billed',
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  setState(() => _status = v);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Total display
            if (_totalAmount > 0)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: const Color(0xFF10B981).withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total Amount',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF475569),
                      ),
                    ),
                    Text(
                      _formatCurrency(_totalAmount),
                      style: GoogleFonts.manrope(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF10B981),
                      ),
                    ),
                  ],
                ),
              ),

            // Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: _isSubmitting ? null : _resetForm,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _isSubmitting ? null : _submitOrder,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5D6E7E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    disabledBackgroundColor:
                        const Color(0xFF5D6E7E).withOpacity(0.5),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'Create Order',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.manrope(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: const Color(0xFF1E293B),
      ),
    );
  }

  Widget _buildClientField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Client',
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _clientSearchController,
          onChanged: (v) {
            _filterClients(v);
            _selectedClient = v;
          },
          onTap: () => _filterClients(_clientSearchController.text),
          style: GoogleFonts.inter(fontSize: 13),
          decoration: _inputDecoration(
            hint: 'Search or type client name',
            suffixIcon: _selectedClient != null && _selectedClient!.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      setState(() {
                        _selectedClient = null;
                        _clientSearchController.clear();
                        _showClientDropdown = false;
                      });
                    },
                  )
                : const Icon(Icons.person_outline, size: 18),
          ),
        ),
        if (_showClientDropdown && _filteredClients.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _filteredClients.length,
              itemBuilder: (ctx, i) {
                return InkWell(
                  onTap: () {
                    setState(() {
                      _selectedClient = _filteredClients[i];
                      _clientSearchController.text = _filteredClients[i];
                      _showClientDropdown = false;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Text(
                      _filteredClients[i],
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: const Color(0xFF1E293B),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildDateField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Order Date',
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _dateController,
          readOnly: true,
          onTap: _pickDate,
          style: GoogleFonts.inter(fontSize: 13),
          decoration: _inputDecoration(
            hint: 'Select date',
            suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    String? hint,
    int maxLines = 1,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    ValueChanged<String>? onChanged,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          onChanged: onChanged,
          validator: validator,
          style: GoogleFonts.inter(fontSize: 13),
          decoration: _inputDecoration(hint: hint),
        ),
      ],
    );
  }

  Widget _buildFormDropdown({
    required String label,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    // Ensure the current value exists in items
    final effectiveValue = (value != null && items.contains(value)) ? value : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F9FA),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: effectiveValue,
              isExpanded: true,
              hint: Text(
                'Select $label',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: const Color(0xFF94A3B8),
                ),
              ),
              icon: const Icon(Icons.keyboard_arrow_down, size: 18),
              style: GoogleFonts.inter(
                fontSize: 13,
                color: const Color(0xFF1E293B),
              ),
              items: items
                  .map((item) => DropdownMenuItem(
                        value: item,
                        child: Text(item),
                      ))
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration({String? hint, Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(
        fontSize: 13,
        color: const Color(0xFF94A3B8),
      ),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: const Color(0xFFF8F9FA),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF5D6E7E), width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFEF4444)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
      ),
    );
  }

  String _formatCurrency(double val) {
    final f = NumberFormat('#,##0.##', 'en_IN');
    return f.format(val);
  }
}
