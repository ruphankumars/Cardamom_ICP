import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/grade_grouped_dropdown.dart';

class ClientCreateRequestScreen extends StatefulWidget {
  final String initialType;
  const ClientCreateRequestScreen({super.key, required this.initialType});

  @override
  State<ClientCreateRequestScreen> createState() => _ClientCreateRequestScreenState();
}

class _ClientCreateRequestScreenState extends State<ClientCreateRequestScreen> {
  final ApiService _apiService = ApiService();
  final List<Map<String, dynamic>> _items = [];
  final TextEditingController _initialTextController = TextEditingController();
  bool _isLoading = false;
  List<String> _grades = [];
  List<String> _brands = [];
  String _selectedType = '';

  @override
  void initState() {
    super.initState();
    _selectedType = widget.initialType;
    _loadGrades();
  }

  Future<void> _loadGrades() async {
    try {
      final response = await _apiService.getDropdownOptions();
      setState(() {
        _grades = List<String>.from(response.data['grade'] ?? []);
        _brands = List<String>.from(response.data['brand'] ?? [
          'Emperor Magenta Pink', 'Emperor Green', 'Emperor Gold',
          'ESPL Premium', 'SYGT Standard', 'Custom Brand'
        ]);
        if (_items.isEmpty) _addItem();
      });
    } catch (e) {
      if (_items.isEmpty) _addItem();
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
      setState(() {
        _items.removeAt(index);
      });
    }
  }

  void _updateKgs(int index, num no) {
    setState(() {
      final item = _items[index];
      item['no'] = no;
      final multiplier = item['bagbox'] == 'Bag' ? 50 : 20;
      item['kgs'] = no * multiplier;
    });
  }

  Future<void> _submitRequest() async {
    // ISSUE 21 fix: Validate items before submit
    for (int i = 0; i < _items.length; i++) {
      final item = _items[i];
      final no = item['no'] is num ? (item['no'] as num) : 0;
      if (no <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Item ${i + 1} (${item['grade']}): Quantity must be greater than 0')),
        );
        return;
      }
    }
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username') ?? '';
      final clientName = prefs.getString('clientName') ?? '';

      final payload = {
        'requestType': _selectedType,
        'items': _items,
        'initialText': _initialTextController.text,
        'username': username,
        if (clientName.isNotEmpty) 'clientName': clientName,
      };

      await _apiService.createClientRequest(payload);
      if (!mounted) return;
      if (mounted) {
        _showSuccessModal();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showSuccessModal() {
    HapticFeedback.heavyImpact();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.9),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle, color: Colors.green, size: 48),
              ),
              const SizedBox(height: 20),
              const Text('Request Submitted!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
              const SizedBox(height: 12),
              Text(
                'Your ${_selectedType == 'REQUEST_ORDER' ? 'order request' : 'price enquiry'} has been sent to the admin. You will be notified when they respond.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF64748B), height: 1.5),
              ),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF2563EB)]),
                ),
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context); // Close modal
                    Navigator.pop(context, true); // Go back
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shadowColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('VIEW MY REQUESTS', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      disableInternalScrolling: true,
      title: _selectedType == 'REQUEST_ORDER' ? 'Order Request' : 'Price Enquiry',
      content: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;
          return SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: 20),
              child: Column(
                children: [
                  _buildTypeSelector(isMobile),
                  const SizedBox(height: 20),
                  ...List.generate(_items.length, (idx) => _buildItemCard(idx, isMobile)),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Item'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _initialTextController,
                    decoration: InputDecoration(
                      labelText: 'Notes', 
                      hintText: 'Any special requests?',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 32),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF2563EB)]),
                      boxShadow: [
                        BoxShadow(color: const Color(0xFF5D6E7E).withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6)),
                      ],
                    ),
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submitRequest,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 54),
                        backgroundColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        shadowColor: Colors.transparent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: _isLoading 
                        ? const CircularProgressIndicator(color: Colors.white) 
                        : const Text('Submit Request', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTypeSelector(bool isMobile) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.grey.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          _buildTypeButton('REQUEST_ORDER', isMobile ? 'Order' : 'Order Request'),
          _buildTypeButton('ENQUIRE_PRICE', isMobile ? 'Enquiry' : 'Price Enquiry'),
        ],
      ),
    );
  }

  Widget _buildTypeButton(String type, String label) {
    final isSelected = _selectedType == type;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedType = type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: isSelected ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2)] : null,
          ),
          child: Center(
            child: Text(label, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, color: isSelected ? AppTheme.primary : AppTheme.muted)),
          ),
        ),
      ),
    );
  }

  Widget _buildItemCard(int idx, bool isMobile) {
    final item = _items[idx];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      decoration: AppTheme.glassDecoration.copyWith(
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('ITEM #${idx + 1}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF64748B), letterSpacing: 0.5)),
              if (_items.length > 1) 
                GestureDetector(
                  onTap: () => _removeItem(idx),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), shape: BoxShape.circle),
                    child: const Icon(Icons.close, color: Colors.red, size: 16),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          GradeGroupedDropdown(
            value: item['grade'],
            grades: _grades,
            onChanged: (val) => setState(() => item['grade'] = val),
            decoration: InputDecoration(
              labelText: 'Grade',
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  value: item['bagbox'],
                  items: const [DropdownMenuItem(value: 'Bag', child: Text('Bag (50kg)')), DropdownMenuItem(value: 'Box', child: Text('Box (20kg)'))],
                  onChanged: (val) {
                    setState(() {
                      item['bagbox'] = val;
                      _updateKgs(idx, item['no']);
                    });
                  },
                  decoration: InputDecoration(
                    labelText: 'Unit', 
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextFormField(
                  initialValue: item['no'].toString(),
                  keyboardType: TextInputType.number,
                  onChanged: (val) => _updateKgs(idx, num.tryParse(val) ?? 0),
                  decoration: InputDecoration(
                    labelText: 'Qty', 
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total Weight', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                Text('${item['kgs']} kg', style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.accent)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: (item['brand'] as String?)?.isNotEmpty == true ? item['brand'] : null,
            items: [
              const DropdownMenuItem(value: '', child: Text('Select Brand (Optional)', style: TextStyle(color: Color(0xFF94A3B8)))),
              ..._brands.map((b) => DropdownMenuItem(value: b, child: Text(b))),
            ],
            onChanged: (val) => setState(() => item['brand'] = val ?? ''),
            decoration: InputDecoration(
              labelText: 'Brand',
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: item['notes'] ?? '',
            onChanged: (val) => item['notes'] = val,
            decoration: InputDecoration(
              labelText: 'Notes',
              hintText: 'Local Pouch Name / Extra pouch / White Bag Info',
              hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFCBD5E1)),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            maxLines: 2,
          ),
        ],
      ),
    );
  }
}
