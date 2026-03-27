import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/navigation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/grade_grouped_dropdown.dart';

class GradeAllocatorScreen extends StatefulWidget {
  const GradeAllocatorScreen({super.key});

  @override
  State<GradeAllocatorScreen> createState() => _GradeAllocatorScreenState();
}

class _GradeAllocatorScreenState extends State<GradeAllocatorScreen> with RouteAware {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  bool _isPushing = false;
  List<String> _grades = [];
  List<String> _brands = [];
  List<Map<String, dynamic>> _gradeRequests = [];
  List<Map<String, dynamic>> _allocations = [];
  Map<String, double> _unallocated = {};
  bool _showResults = false;
  final Set<int> _selectedAllocations = {};

  // FIX 1: Track pending orders count on load
  int _pendingOrdersCount = 0;
  List<dynamic> _cachedPendingOrders = [];

  @override
  void initState() {
    super.initState();
    _loadOptions();
    _loadPendingCount(); // FIX 1: Load pending count on init
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    _loadOptions();
    _loadPendingCount();
  }

  // FIX 1: Load pending orders count on page load
  Future<void> _loadPendingCount() async {
    try {
      final pendingOrders = await _apiService.getPendingOrders();
      final List pendingList = (pendingOrders.data is List) ? (pendingOrders.data as List) : [];
      setState(() {
        _pendingOrdersCount = pendingList.length;
        _cachedPendingOrders = pendingList;
      });
    } catch (e) {
      debugPrint('Error loading pending count: $e');
    }
  }

  Future<void> _loadOptions() async {
    try {
      final response = await _apiService.getDropdownOptions();
      setState(() {
        _grades = (response.data['grade'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
        _brands = (response.data['brand'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
        _isLoading = false;
        _addGradeRow();
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  void _addGradeRow() => setState(() => _gradeRequests.add({'grade': '', 'brand': '', 'qty': ''}));

  void _resetAllocator() {
    setState(() {
      _gradeRequests.clear();
      _allocations.clear();
      _unallocated.clear();
      _selectedAllocations.clear();
      _showResults = false;
      _addGradeRow();
    });
  }

  Future<void> _submitAllocation() async {
    // FIX 5: Validate - grade is required for each row
    for (int i = 0; i < _gradeRequests.length; i++) {
      final request = _gradeRequests[i];
      final grade = request['grade']?.toString() ?? '';
      final brand = request['brand']?.toString() ?? '';
      final qty = double.tryParse(request['qty']?.toString() ?? '') ?? 0;
      
      // Skip empty rows
      if (grade.isEmpty && brand.isEmpty && qty <= 0) continue;
      
      // If brand is selected but grade is not, show error
      if (brand.isNotEmpty && grade.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Row ${i + 1}: Please select a Grade before selecting a Brand'),
            backgroundColor: AppTheme.danger,
          ),
        );
        return;
      }
      
      // If qty is entered but grade is not, show error
      if (qty > 0 && grade.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Row ${i + 1}: Please select a Grade'),
            backgroundColor: AppTheme.danger,
          ),
        );
        return;
      }
    }

    _selectedAllocations.clear();
    setState(() => _isLoading = true);
    try {
      // Always fetch fresh pending orders to avoid stale cache / double-dispatch
      final pendingOrders = await _apiService.getPendingOrders();
      List pendingList = (pendingOrders.data is List) ? (pendingOrders.data as List) : [];
      _cachedPendingOrders = pendingList;
      _pendingOrdersCount = pendingList.length;
      
      final List<Map<String, dynamic>> newAllocations = [];
      final Map<String, double> newUnallocated = {};
      final double EPSILON = 0.0001;

      // FIX 4: Sort by date (oldest first) per the manual
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

        // FIX 5: Match grade, and if brand is specified, match that too
        final matches = pendingList.where((o) {
          final orderGrade = o['grade']?.toString() ?? '';
          final orderBrand = o['brand']?.toString() ?? '';
          
          // Grade must match
          if (orderGrade != reqGrade) return false;
          
          // If brand is specified (not empty/Any), it must match
          if (reqBrand.isNotEmpty && orderBrand != reqBrand) return false;
          
          return true;
        }).toList();

        for (var order in matches) {
          if (remaining <= 0) break;
          final totalKgs = (order['kgs'] is num) 
              ? (order['kgs'] as num).toDouble() 
              : (double.tryParse(order['kgs'].toString()) ?? 0);
          
          // FIX 4: No Fragmentation - only allocate FULL orders
          // Skip if remaining qty is less than order kgs (can't fulfill fully)
          if (remaining + EPSILON < totalKgs) continue;
          
          newAllocations.add({
            ...Map<String, dynamic>.from(order), 
            'allocatedQty': totalKgs, 
            'reqBrand': reqBrand
          });
          remaining -= totalKgs;
        }
        
        if (remaining > EPSILON) {
          newUnallocated['$reqGrade${reqBrand.isNotEmpty ? " ($reqBrand)" : ""}'] = remaining;
        }
      }

      setState(() { 
        _allocations = newAllocations; 
        _unallocated = newUnallocated; 
        _showResults = true; 
        _isLoading = false; 
      });
    } catch (e) { 
      debugPrint('Allocation error: $e');
      setState(() => _isLoading = false); 
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.danger),
      );
    }
  }

  // Helper to parse date strings
  DateTime _parseDate(String dateStr) {
    try {
      // Try DD/MM/YY format
      if (dateStr.contains('/')) {
        final parts = dateStr.split('/');
        if (parts.length == 3) {
          final day = int.tryParse(parts[0]) ?? 1;
          final month = int.tryParse(parts[1]) ?? 1;
          int year = int.tryParse(parts[2]) ?? 2024;
          if (year < 100) year += 2000;
          return DateTime(year, month, day);
        }
      }
      return DateTime.tryParse(dateStr) ?? DateTime.now();
    } catch (_) {
      return DateTime.now();
    }
  }

  // FIX 3: Push allocations to cart
  Future<void> _pushToCart() async {
    if (_selectedAllocations.isEmpty) return;

    setState(() => _isPushing = true);

    try {
      // Only push selected allocations
      final selectedList = _selectedAllocations.toList()..sort();
      final selectedAllocations = selectedList.map((i) => _allocations[i]).toList();

      // Convert allocations to the format expected by addToCart
      final ordersToAdd = selectedAllocations.map((a) => {
        'orderDate': a['orderDate'],
        'billingFrom': a['billingFrom'],
        'client': a['client'],
        'lot': a['lot'],
        'grade': a['grade'],
        'bagbox': a['bagbox'],
        'no': a['no'],
        'kgs': a['kgs'],
        'price': a['price'],
        'brand': a['brand'],
        'status': a['status'],
        'notes': a['notes'],
        'index': a['index'],
      }).toList();
      
      await _apiService.addToCart(ordersToAdd);

      if (!mounted) return;
      setState(() => _isPushing = false);
      
      // Show success and navigate option
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 48),
                ),
                const SizedBox(height: 16),
                Text(
                  'Allocations Pushed!',
                  style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(
                  '${selectedAllocations.length} orders added to Daily Cart',
                  style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.muted),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _resetAllocator();
                          _loadPendingCount(); // Refresh count
                        },
                        child: const Text('Continue'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          Navigator.pushNamed(context, '/daily_cart');
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
                        child: const Text('View Cart'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPushing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error pushing to cart: $e'), backgroundColor: AppTheme.danger),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Grade Master',
      showAppBar: false,
      showBottomNav: false,
      disableInternalScrolling: true,
      content: Container(
        color: AppTheme.titaniumMid,
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  _buildTitaniumHeader(),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(top: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.titaniumLight,
                        borderRadius: const BorderRadius.only(topLeft: Radius.circular(40), topRight: Radius.circular(40)),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20, offset: const Offset(0, -10)),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 120, top: 20),
                        children: [
                          _buildHeroCard(),
                          const SizedBox(height: 32),
                          _buildInputPanel(),
                          if (_showResults) ...[
                            const SizedBox(height: 32),
                            _buildResultsPanel(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _buildActionArc(),
            if (_isLoading || _isPushing)
              Container(
                color: Colors.black26,
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitaniumHeader() => Builder(builder: (ctx) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _machinedBtn(Icons.menu_rounded, () => Scaffold.of(ctx).openDrawer()),
        Text('GRADE MASTER', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 2.5)),
        _machinedBtn(Icons.arrow_back_rounded, () => Navigator.pop(context)),
      ],
    ),
  ));

  Widget _machinedBtn(IconData icon, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44, height: 44,
      decoration: AppTheme.machinedDecoration,
      child: Icon(icon, color: AppTheme.primary, size: 22),
    ),
  );

  Widget _buildHeroCard() => Container(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: AppTheme.titaniumMid,
      borderRadius: BorderRadius.circular(28),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 15, offset: const Offset(6, 6)),
        BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(3, 3)),
      ],
      border: Border.all(color: AppTheme.titaniumDark.withOpacity(0.5), width: 1),
    ),
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STATUS: ALIGNMENT ACTIVE', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.primary, letterSpacing: 1.5)),
        const SizedBox(height: 4),
        Text('Grade Intelligence', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w900, color: AppTheme.title, height: 1.1)),
        const SizedBox(height: 4),
        Row(children: [const Icon(Icons.sync_rounded, size: 10, color: AppTheme.primary), const SizedBox(width: 4), Text('REAL-TIME OPTIMIZATION', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: AppTheme.primary))]),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(child: _heroStat('GRADES', '${_grades.length}', 'Options')),
          const SizedBox(width: 12),
          // FIX 1: Show actual pending count from load
          Expanded(child: _heroStat('PENDING', '$_pendingOrdersCount', 'Orders', isWarning: _pendingOrdersCount > 0)),
        ]),
      ],
    ),
  );

  Widget _heroStat(String l, String v, String t, {bool isWarning = false}) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppTheme.titaniumLight, 
      borderRadius: BorderRadius.circular(16), 
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 4, offset: const Offset(2, 2)),
      ],
      border: Border.all(color: AppTheme.titaniumDark.withOpacity(0.3), width: 0.5),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(l, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: AppTheme.primary)),
      const SizedBox(height: 4),
      Text(v, style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w900, color: AppTheme.title)),
      Text(t, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: isWarning ? AppTheme.warning : AppTheme.primary)),
    ]),
  );

  Widget _buildInputPanel() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.titaniumMid, 
        borderRadius: BorderRadius.circular(28), 
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 15, offset: const Offset(6, 6)),
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(3, 3)),
        ],
        border: Border.all(color: AppTheme.titaniumDark.withOpacity(0.5), width: 1),
      ),
      child: Column(children: [
        Text('ALLOCATION MATRICS', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 1.5)),
        const SizedBox(height: 24),
        ..._gradeRequests.asMap().entries.map((e) => _buildRow(e.key)),
        const SizedBox(height: 24),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _actionBtn('ADD', Icons.add_rounded, _addGradeRow),
          _actionBtn('RESET', Icons.restart_alt_rounded, _resetAllocator),
          _actionBtn('SYNC', Icons.bolt_rounded, _submitAllocation, isPrimary: true),
        ]),
      ]),
    ),
  );

  // FIX 2: Build row with value-retaining dropdowns
  Widget _buildRow(int idx) {
    final request = _gradeRequests[idx];
    final selectedGrade = request['grade']?.toString() ?? '';
    final selectedBrand = request['brand']?.toString() ?? '';
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.titaniumLight, 
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(2, 2)),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
      ),
      child: Column(children: [
        // Grade dropdown with grouped categories
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('GRADE', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary)),
            const SizedBox(height: 4),
            GradeGroupedDropdown(
              value: selectedGrade.isEmpty ? null : selectedGrade,
              grades: _grades,
              onChanged: (v) => setState(() => _gradeRequests[idx]['grade'] = v ?? ''),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.5),
                hintText: 'Select GRADE',
                hintStyle: GoogleFonts.manrope(fontSize: 13, color: AppTheme.muted),
              ),
              itemStyle: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w900),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // FIX 2: Brand dropdown with value
        _dropdownWithValue(
          'BRAND', 
          ['-- Any --', ..._brands], 
          selectedBrand.isEmpty ? '-- Any --' : selectedBrand,
          (v) => setState(() => _gradeRequests[idx]['brand'] = v == '-- Any --' ? '' : (v ?? '')),
        ),
        const SizedBox(height: 12),
        _inputWithController('QUANTITY KG', idx),
      ]),
    );
  }

  // FIX 2: Dropdown that shows selected value
  Widget _dropdownWithValue(String label, List<String> items, String? value, ValueChanged<String?> onCh) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, 
    children: [
      Text(label, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary)),
      const SizedBox(height: 4),
      DropdownButtonFormField<String>(
        value: (value != null && items.contains(value)) ? value : null,
        borderRadius: BorderRadius.circular(20),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          filled: true,
          fillColor: Colors.white.withOpacity(0.5),
        ),
        hint: Text('Select $label', style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.muted)),
        items: items.map((e) => DropdownMenuItem(
          value: e, 
          child: Text(e, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w900))
        )).toList(), 
        onChanged: onCh, 
        isExpanded: true, 
        icon: const Icon(Icons.expand_more_rounded, size: 18),
      ),
    ],
  );

  Widget _inputWithController(String label, int idx) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start, 
      children: [
        Text(label, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary)),
        const SizedBox(height: 4),
        TextFormField(
          initialValue: _gradeRequests[idx]['qty']?.toString() ?? '',
          onChanged: (v) => _gradeRequests[idx]['qty'] = v,
          keyboardType: TextInputType.number,
          style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w900),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            filled: true,
            fillColor: Colors.white.withOpacity(0.5),
            hintText: 'Enter quantity in kg',
            hintStyle: GoogleFonts.manrope(fontSize: 12, color: AppTheme.muted),
          ),
        ),
      ],
    );
  }

  Widget _actionBtn(String l, IconData i, VoidCallback onTap, {bool isPrimary = false}) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: isPrimary ? AppTheme.primary : AppTheme.titaniumMid, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [Icon(i, size: 16, color: isPrimary ? Colors.white : AppTheme.primary), const SizedBox(width: 8), Text(l, style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w900, color: isPrimary ? Colors.white : AppTheme.primary))]),
    ),
  );

  Widget _buildResultsPanel() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(
        children: [
          Text('ALLOCATION SUMMARY', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w900, color: AppTheme.primary, letterSpacing: 2.0)),
          const Spacer(),
          if (_allocations.isNotEmpty) ...[
            GestureDetector(
              onTap: () {
                setState(() {
                  if (_selectedAllocations.length == _allocations.length) {
                    _selectedAllocations.clear();
                  } else {
                    _selectedAllocations.clear();
                    for (int i = 0; i < _allocations.length; i++) {
                      _selectedAllocations.add(i);
                    }
                  }
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _selectedAllocations.length == _allocations.length ? Icons.deselect : Icons.select_all,
                      size: 12,
                      color: AppTheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _selectedAllocations.length == _allocations.length ? 'DESELECT ALL' : 'SELECT ALL',
                      style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w900, color: AppTheme.primary),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${_selectedAllocations.isNotEmpty ? '${_selectedAllocations.length}/' : ''}${_allocations.length} MATCHED',
                style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w900, color: AppTheme.success),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 12),
      if (_unallocated.entries.any((e) => e.value > 0.0001)) _shortfallBanner(),
      const SizedBox(height: 12),
      if (_allocations.isEmpty)
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppTheme.titaniumMid,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: Text(
              'No matching orders found',
              style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.muted),
            ),
          ),
        )
      else
        ..._allocations.asMap().entries.map((e) => _buildResultItem(e.key, e.value)),
    ]),
  );

  Widget _shortfallBanner() {
    final shortfalls = _unallocated.entries.where((e) => e.value > 0.0001).toList();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.danger.withOpacity(0.3))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.warning_rounded, color: AppTheme.danger, size: 18), 
            const SizedBox(width: 12), 
            Text('SHORTFALL IN REQUESTED GRADES', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w900, color: AppTheme.danger))
          ]),
          const SizedBox(height: 8),
          ...shortfalls.map((e) => Text(
            '${e.key}: ${e.value.toStringAsFixed(1)} kg short',
            style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.danger),
          )),
        ],
      ),
    );
  }

  Widget _buildResultItem(int idx, Map<String, dynamic> a) {
    final isSelected = _selectedAllocations.contains(idx);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedAllocations.remove(idx);
          } else {
            _selectedAllocations.add(idx);
          }
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.primary.withOpacity(0.12) : Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isSelected ? AppTheme.primary.withOpacity(0.5) : Colors.white.withOpacity(0.2)),
              ),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a['client']?.toString().toUpperCase() ?? 'UNKNOWN', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w900, color: AppTheme.title)),
                  Text('${a['grade']} | ${a['lot']}${a['brand'] != null && a['brand'].toString().isNotEmpty ? ' | ${a['brand']}' : ''}', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.muted)),
                  if (a['orderDate'] != null)
                    Text('${a['orderDate']}', style: GoogleFonts.manrope(fontSize: 9, color: AppTheme.muted)),
                ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${a['kgs']}kg', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w900, color: AppTheme.primary)),
                  Text('ALLOCATED', style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w800, color: AppTheme.muted)),
                ]),
                const SizedBox(width: 12),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isSelected ? AppTheme.primary : AppTheme.muted.withOpacity(0.5),
                      width: 1.5,
                    ),
                  ),
                  child: isSelected ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // FIX 3: Action arc with working PUSH TO CART
  Widget _buildActionArc() {
    final hasSelection = _selectedAllocations.isNotEmpty;
    final hasAllocations = _allocations.isNotEmpty;
    final String label;
    if (!hasAllocations) {
      label = 'AWAITING ALLOCATIONS';
    } else if (!hasSelection) {
      label = 'SELECT GRADES TO PUSH';
    } else {
      label = 'PUSH ${_selectedAllocations.length} TO CART';
    }

    return Positioned(
      bottom: 20, left: 20, right: 20,
      child: GestureDetector(
        onTap: hasSelection && !_isPushing ? _pushToCart : null,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: hasSelection ? AppTheme.primary : AppTheme.titaniumMid,
            borderRadius: BorderRadius.circular(32),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20, offset: const Offset(0, 10))],
          ),
          child: Center(
            child: _isPushing
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasSelection) ...[
                        const Icon(Icons.shopping_cart_checkout_rounded, color: Colors.white, size: 20),
                        const SizedBox(width: 12),
                      ],
                      Text(
                        label,
                        style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w900, color: hasSelection ? Colors.white : AppTheme.primary, letterSpacing: 1.5),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
