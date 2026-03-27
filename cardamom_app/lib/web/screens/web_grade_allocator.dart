import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

/// Web-optimized Grade Allocation tool.
/// Form to enter grade/brand/qty requests, allocate against pending orders.
class WebGradeAllocator extends StatefulWidget {
  const WebGradeAllocator({super.key});

  @override
  State<WebGradeAllocator> createState() => _WebGradeAllocatorState();
}

class _WebGradeAllocatorState extends State<WebGradeAllocator> {
  static const _bg = Color(0xFFF8F9FA);
  static const _primary = Color(0xFF5D6E7E);
  static const _headerBg = Color(0xFFF1F5F9);
  static const _cardRadius = 12.0;

  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  bool _isAllocating = false;
  List<String> _grades = [];
  List<String> _brands = [];
  List<Map<String, dynamic>> _gradeRequests = [];
  List<Map<String, dynamic>> _allocations = [];
  Map<String, double> _unallocated = {};
  bool _showResults = false;
  int _pendingOrdersCount = 0;
  List<dynamic> _cachedPendingOrders = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadOptions();
    _loadPendingCount();
  }

  Future<void> _loadPendingCount() async {
    try {
      final pendingOrders = await _apiService.getPendingOrders();
      final pendingList = (pendingOrders.data is List) ? (pendingOrders.data as List) : [];
      if (mounted) {
        setState(() {
          _pendingOrdersCount = pendingList.length;
          _cachedPendingOrders = pendingList;
        });
      }
    } catch (e) {
      debugPrint('Error loading pending count: $e');
    }
  }

  Future<void> _loadOptions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await _apiService.getDropdownOptions();
      if (mounted) {
        setState(() {
          _grades = (response.data['grade'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
          _brands = (response.data['brand'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
          _isLoading = false;
          if (_gradeRequests.isEmpty) _addRow();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _addRow() {
    setState(() => _gradeRequests.add({'grade': '', 'brand': '', 'qty': ''}));
  }

  void _removeRow(int index) {
    if (_gradeRequests.length > 1) {
      setState(() => _gradeRequests.removeAt(index));
    }
  }

  void _resetAllocator() {
    setState(() {
      _gradeRequests.clear();
      _allocations.clear();
      _unallocated.clear();
      _showResults = false;
      _addRow();
    });
  }

  DateTime _parseDate(String dateStr) {
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      try {
        return DateFormat('dd/MM/yyyy').parse(dateStr);
      } catch (_) {
        return DateTime(2099);
      }
    }
  }

  Future<void> _submitAllocation() async {
    // Validate
    for (int i = 0; i < _gradeRequests.length; i++) {
      final request = _gradeRequests[i];
      final grade = request['grade']?.toString() ?? '';
      final brand = request['brand']?.toString() ?? '';
      final qty = double.tryParse(request['qty']?.toString() ?? '') ?? 0;

      if (grade.isEmpty && brand.isEmpty && qty <= 0) continue;
      if (brand.isNotEmpty && grade.isEmpty) {
        _showError('Row ${i + 1}: Please select a Grade before Brand');
        return;
      }
      if (qty > 0 && grade.isEmpty) {
        _showError('Row ${i + 1}: Please select a Grade');
        return;
      }
    }

    setState(() => _isAllocating = true);
    try {
      List pendingList = _cachedPendingOrders.isNotEmpty ? _cachedPendingOrders : [];
      if (pendingList.isEmpty) {
        final pendingOrders = await _apiService.getPendingOrders();
        pendingList = (pendingOrders.data is List) ? (pendingOrders.data as List) : [];
        _cachedPendingOrders = pendingList;
        _pendingOrdersCount = pendingList.length;
      }

      final newAllocations = <Map<String, dynamic>>[];
      final newUnallocated = <String, double>{};
      const epsilon = 0.0001;

      pendingList.sort((a, b) {
        final dateA = _parseDate(a['orderDate']?.toString() ?? '');
        final dateB = _parseDate(b['orderDate']?.toString() ?? '');
        return dateA.compareTo(dateB);
      });

      for (var request in _gradeRequests) {
        final reqGrade = request['grade']?.toString() ?? '';
        final reqBrand = request['brand']?.toString() ?? '';
        final reqQty = double.tryParse(request['qty']?.toString() ?? '') ?? 0;
        double remaining = reqQty;

        if (reqGrade.isEmpty || reqQty <= 0) continue;

        final matches = pendingList.where((o) {
          final orderGrade = o['grade']?.toString() ?? '';
          final orderBrand = o['brand']?.toString() ?? '';
          if (orderGrade != reqGrade) return false;
          if (reqBrand.isNotEmpty && orderBrand != reqBrand) return false;
          return true;
        }).toList();

        for (var order in matches) {
          if (remaining < epsilon) break;
          final orderQty = (double.tryParse(order['remainingQty']?.toString() ?? order['quantity']?.toString() ?? '0') ?? 0);
          if (orderQty < epsilon) continue;
          final allocated = remaining < orderQty ? remaining : orderQty;
          newAllocations.add({
            'orderId': order['_id'] ?? order['id'] ?? '',
            'client': order['client']?.toString() ?? '',
            'grade': reqGrade,
            'brand': order['brand']?.toString() ?? '',
            'orderQty': orderQty,
            'allocated': allocated,
            'orderDate': order['orderDate']?.toString() ?? '',
          });
          remaining -= allocated;
        }

        if (remaining > epsilon) {
          final key = reqBrand.isNotEmpty ? '$reqGrade - $reqBrand' : reqGrade;
          newUnallocated[key] = (newUnallocated[key] ?? 0) + remaining;
        }
      }

      if (mounted) {
        setState(() {
          _allocations = newAllocations;
          _unallocated = newUnallocated;
          _showResults = true;
          _isAllocating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAllocating = false);
        _showError('Allocation failed: $e');
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildErrorState()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildInfoCards(),
                            const SizedBox(height: 24),
                            _buildRequestForm(),
                            const SizedBox(height: 24),
                            if (_showResults) ...[
                              _buildAllocationResults(),
                              const SizedBox(height: 24),
                              if (_unallocated.isNotEmpty) _buildUnallocated(),
                            ],
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Grade Allocator',
                    style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: _primary)),
                const SizedBox(height: 4),
                Text('Allocate grades against pending orders',
                    style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
              ],
            ),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _primary,
              side: BorderSide(color: _primary.withOpacity(0.3)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _resetAllocator,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Reset', style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCards() {
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [
        _statCard('Pending Orders', '$_pendingOrdersCount', Icons.pending_actions, const Color(0xFFF59E0B)),
        _statCard('Available Grades', '${_grades.length}', Icons.category, const Color(0xFF3B82F6)),
        _statCard('Available Brands', '${_brands.length}', Icons.branding_watermark, const Color(0xFF8B5CF6)),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: GoogleFonts.manrope(fontSize: 22, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
              Text(label, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF6B7280))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRequestForm() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _headerBg,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(_cardRadius),
                topRight: Radius.circular(_cardRadius),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.list_alt, size: 18, color: _primary),
                const SizedBox(width: 8),
                Text('Grade Requests', style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: _primary)),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _addRow,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.add, size: 14, color: _primary),
                        const SizedBox(width: 4),
                        Text('Add Row', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _primary)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Table header
                Row(
                  children: [
                    Expanded(flex: 3, child: Text('Grade', style: _tableHeaderStyle())),
                    const SizedBox(width: 12),
                    Expanded(flex: 3, child: Text('Brand (optional)', style: _tableHeaderStyle())),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: Text('Quantity (kg)', style: _tableHeaderStyle())),
                    const SizedBox(width: 8),
                    const SizedBox(width: 36),
                  ],
                ),
                const SizedBox(height: 8),
                ..._gradeRequests.asMap().entries.map((entry) {
                  final index = entry.key;
                  final request = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            value: request['grade']?.toString().isNotEmpty == true ? request['grade'] : null,
                            decoration: _inputDecoration(),
                            items: _grades.map((g) => DropdownMenuItem(value: g, child: Text(g, style: GoogleFonts.inter(fontSize: 13)))).toList(),
                            onChanged: (v) => setState(() => _gradeRequests[index]['grade'] = v ?? ''),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            value: request['brand']?.toString().isNotEmpty == true ? request['brand'] : null,
                            decoration: _inputDecoration(),
                            items: [
                              DropdownMenuItem(value: '', child: Text('Any', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)))),
                              ..._brands.map((b) => DropdownMenuItem(value: b, child: Text(b, style: GoogleFonts.inter(fontSize: 13)))),
                            ],
                            onChanged: (v) => setState(() => _gradeRequests[index]['brand'] = v ?? ''),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            keyboardType: TextInputType.number,
                            style: GoogleFonts.inter(fontSize: 13),
                            decoration: _inputDecoration(),
                            onChanged: (v) => _gradeRequests[index]['qty'] = v,
                            controller: TextEditingController(text: request['qty']?.toString() ?? '')
                              ..selection = TextSelection.collapsed(offset: (request['qty']?.toString() ?? '').length),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          child: IconButton(
                            icon: Icon(Icons.remove_circle_outline, size: 18, color: Colors.red.withOpacity(0.6)),
                            onPressed: () => _removeRow(index),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _primary,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _isAllocating ? null : _submitAllocation,
                    icon: _isAllocating
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.auto_fix_high, size: 18),
                    label: Text(_isAllocating ? 'Allocating...' : 'Allocate', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _tableHeaderStyle() => GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: _primary, letterSpacing: 0.5);

  InputDecoration _inputDecoration() {
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

  Widget _buildAllocationResults() {
    if (_allocations.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_cardRadius),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Column(
          children: [
            Icon(Icons.inventory_2_outlined, size: 48, color: _primary.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text('No matching orders found', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withOpacity(0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(_cardRadius),
                topRight: Radius.circular(_cardRadius),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, size: 18, color: Color(0xFF10B981)),
                const SizedBox(width: 8),
                Text('Allocation Results (${_allocations.length} matches)',
                    style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: const Color(0xFF10B981))),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(_cardRadius),
              bottomRight: Radius.circular(_cardRadius),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(_headerBg),
                headingTextStyle: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: _primary, letterSpacing: 0.5),
                dataTextStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF374151)),
                columnSpacing: 20,
                horizontalMargin: 16,
                columns: const [
                  DataColumn(label: Text('CLIENT')),
                  DataColumn(label: Text('GRADE')),
                  DataColumn(label: Text('BRAND')),
                  DataColumn(label: Text('ORDER QTY'), numeric: true),
                  DataColumn(label: Text('ALLOCATED'), numeric: true),
                  DataColumn(label: Text('ORDER DATE')),
                ],
                rows: _allocations.map((a) {
                  return DataRow(cells: [
                    DataCell(Text(a['client'] ?? '')),
                    DataCell(Text(a['grade'] ?? '')),
                    DataCell(Text(a['brand'] ?? '-')),
                    DataCell(Text('${(a['orderQty'] as num).toStringAsFixed(1)} kg')),
                    DataCell(Text('${(a['allocated'] as num).toStringAsFixed(1)} kg',
                        style: GoogleFonts.manrope(fontWeight: FontWeight.w600, color: const Color(0xFF10B981)))),
                    DataCell(Text(_formatDate(a['orderDate']?.toString()))),
                  ]);
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '-';
    try {
      return DateFormat('MMM d').format(DateTime.parse(dateStr));
    } catch (_) {
      return dateStr;
    }
  }

  Widget _buildUnallocated() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.3)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withOpacity(0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(_cardRadius),
                topRight: Radius.circular(_cardRadius),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, size: 18, color: Color(0xFFF59E0B)),
                const SizedBox(width: 8),
                Text('Unallocated Quantities',
                    style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: const Color(0xFFF59E0B))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: _unallocated.entries.map((e) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(e.key, style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF374151)))),
                      Text('${e.value.toStringAsFixed(1)} kg',
                          style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: const Color(0xFFF59E0B))),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 56, color: Colors.red.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text('Failed to load', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: _primary)),
          const SizedBox(height: 8),
          Text(_error ?? '', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280))),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _primary),
            onPressed: _loadOptions,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Retry', style: GoogleFonts.inter()),
          ),
        ],
      ),
    );
  }
}
