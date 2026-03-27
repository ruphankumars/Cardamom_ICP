import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/cache_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/offline_indicator.dart';
import '../widgets/stock_accordion.dart';

class StockCalculatorScreen extends StatefulWidget {
  const StockCalculatorScreen({super.key});

  @override
  State<StockCalculatorScreen> createState() => _StockCalculatorScreenState();
}

class _StockCalculatorScreenState extends State<StockCalculatorScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String _status = 'Ready.';
  Map<String, dynamic>? _netStock;
  String _deltaStatus = '';
  List<String> _shortages = [];
  String _userRole = 'user';
  bool _isFromCache = false;
  String _cacheAge = '';
  
  bool get _isAdmin {
    final role = _userRole.toLowerCase().trim();
    final isAdmin = role == 'superadmin' || role == 'admin' || role == 'ops';
    debugPrint('🔐 [StockCalc] Role: "$_userRole" -> isAdmin: $isAdmin');
    return isAdmin;
  }

  final List<String> _absGrades = ['8 mm', '7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below'];
  final List<String> _virtualGrades = ['8.5 mm', '7.8 bold', '7 to 8 mm', '6.5 to 8 mm', '6.5 to 7.5 mm', '6 to 7 mm', 'Mini Bold', 'Pan'];
  // All grades in display order (matching saleOrderHeaders from backend config)
  final List<String> _allGrades = [
    '8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm',
    '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm',
    '6 mm below', 'Mini Bold', 'Pan'
  ];
  final List<String> _stockTypes = ['Colour Bold', 'Fruit Bold', 'Rejection'];
  
  final ScrollController _headerScrollController = ScrollController();
  final ScrollController _dataScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _init();
    _headerScrollController.addListener(() {
      if (_dataScrollController.hasClients && _dataScrollController.offset != _headerScrollController.offset) {
        _dataScrollController.jumpTo(_headerScrollController.offset);
      }
    });
    _dataScrollController.addListener(() {
      if (_headerScrollController.hasClients && _headerScrollController.offset != _dataScrollController.offset) {
        _headerScrollController.jumpTo(_dataScrollController.offset);
      }
    });
  }

  @override
  void dispose() {
    _headerScrollController.dispose();
    _dataScrollController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _isLoading = true);
    _userRole = await _apiService.getUserRole() ?? 'user';
    await Future.wait([_loadDeltaStatus(), _refreshNetStock()]);
    setState(() => _isLoading = false);
  }

  Future<void> _loadDeltaStatus() async {
    try {
      final res = await _apiService.getDeltaStatus();
      if (!mounted) return;
      setState(() => _deltaStatus = res.data ?? '');
    } catch (e) {
      debugPrint('Error loading delta status: $e');
    }
  }

  Future<void> _refreshNetStock() async {
    try {
      final cacheManager = context.read<CacheManager>();
      final result = await cacheManager.fetchWithCache<Map<String, dynamic>>(
        apiCall: () async {
          final res = await _apiService.getNetStock();
          return Map<String, dynamic>.from(res.data);
        },
        cache: cacheManager.stockCache,
      );
      if (!mounted) return;
      setState(() {
        _netStock = result.data;
        _isFromCache = result.fromCache;
        _cacheAge = result.ageString;
      });
    } catch (e) {
      debugPrint('Error loading net stock: $e');
    }
  }

  Future<void> _recalc() async {
    setState(() => _status = '⏳ Recalculating...');
    try {
      await _apiService.recalcStock();
      if (!mounted) return;
      setState(() => _status = 'Done.');
      await _init();
    } catch (e) {
      debugPrint('Recalc error: $e');
      if (!mounted) return;
      setState(() => _status = '❌ Recalculation failed.');
    }
  }

  Future<void> _clearRejection() async {
    final confirmed = await _showConfirm('Delete ALL Rejection stock adjustments and recalculate?');
    if (confirmed != true) return;

    setState(() => _status = '⏳ Clearing rejection adjustments...');
    try {
      await _apiService.clearRejectionAdjustments();
      if (!mounted) return;
      setState(() => _status = '✅ Rejection adjustments cleared.');
      await _init();
    } catch (e) {
      debugPrint('Clear rejection error: $e');
      if (!mounted) return;
      setState(() => _status = '❌ Failed to clear rejection.');
    }
  }

  Future<void> _resetPointer() async {
    final confirmed = await _showConfirm('Reset delta pointer and clear computed stock?');
    if (confirmed != true) return;

    setState(() => _status = '⏳ Resetting pointer...');
    try {
      await _apiService.resetPointerAdmin();
      if (!mounted) return;
      setState(() => _status = 'Pointer reset.');
      await _init();
    } catch (e) {
      debugPrint('Reset pointer error: $e');
      if (!mounted) return;
      setState(() => _status = '❌ Reset failed.');
    }
  }

  Future<void> _rebuild() async {
    final confirmed = await _showConfirm('Rebuild from scratch using all purchases?');
    if (confirmed != true) return;

    setState(() => _status = '⏳ Rebuilding...');
    try {
      await _apiService.rebuildAdmin();
      if (!mounted) return;
      setState(() => _status = 'Rebuild complete.');
      await _init();
    } catch (e) {
      debugPrint('Rebuild error: $e');
      if (!mounted) return;
      setState(() => _status = '❌ Rebuild failed.');
    }
  }

  void _showShortageReport() {
    if (_netStock == null) return;
    final headers = (_netStock!['headers'] as List).cast<String>();
    final rows = _netStock!['rows'] as List;
    final List<String> newShortages = [];

    for (var row in rows) {
      final values = (row['values'] as List).cast<num>();
      final type = row['type'] as String;

      for (var grade in _absGrades) {
        final idx = headers.indexOf(grade);
        if (idx != -1) {
          final val = values[idx].round();
          if (val < 0) {
            newShortages.add('$type – $grade ➤ Short by ${val.abs()} kg');
          }
        }
      }
    }

    setState(() {
      _shortages = newShortages;
      if (_shortages.isEmpty) {
        _status = '✅ No shortages detected.';
      } else {
        _status = '📉 Shortage report generated.';
      }
    });
  }

  Future<bool?> _showConfirm(String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => _buildGlassDialog(
        title: 'Confirm Action',
        content: Text(message, style: const TextStyle(color: Color(0xFF5D6E7E))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Color(0xFF5D6E7E)))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  /// Submit action for admin approval (for non-admin users)
  Future<void> _requestApproval({
    required String actionType,
    required String resourceType,
    Map<String, dynamic>? proposedChanges,
    String? reason,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId') ?? '';
    final userName = prefs.getString('username') ?? 'Unknown User';

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.all(32),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF5D6E7E)),
            SizedBox(height: 20),
            Text('Submitting request...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );

    try {
      await _apiService.createApprovalRequest({
        'requesterId': userId,
        'requesterName': userName,
        'actionType': actionType,
        'resourceType': resourceType,
        'resourceId': 'stock_${DateTime.now().millisecondsSinceEpoch}',
        'proposedChanges': proposedChanges,
        'reason': reason ?? 'Stock operation request',
      });

      if (mounted) Navigator.pop(context); // Close loading

      // Show success
      if (mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            contentPadding: const EdgeInsets.all(24),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 64),
                const SizedBox(height: 16),
                const Text('Request Submitted', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Your request has been sent to admin for approval.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600])),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E)),
                  child: const Text('OK'),
                ),
              ],
            ),
          ),
        );
        setState(() => _status = '📨 Request submitted for approval');
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // Close loading
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
        setState(() => _status = '❌ Failed to submit request');
      }
    }
  }

  void _openPurchaseModal() {
    final boldController = TextEditingController();
    final floatController = TextEditingController();
    final mediumController = TextEditingController();
    DateTime selectedDate = DateTime.now();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => _buildGlassDialog(
        title: 'Today\'s Purchase (kg)',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: selectedDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (picked != null) setDialogState(() => selectedDate = picked);
              },
              child: InputDecorator(
                decoration: _inputDecoration('Date'),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(DateFormat('dd MMM yyyy').format(selectedDate), style: const TextStyle(fontSize: 13)),
                    const Icon(Icons.calendar_today, size: 16, color: Color(0xFF718096)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildDialogField('Bold Cardamom Qty', boldController),
            _buildDialogField('Floating Bulk Qty', floatController),
            _buildDialogField('Medium Bulk Qty', mediumController),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final bold = double.tryParse(boldController.text) ?? 0;
              final float = double.tryParse(floatController.text) ?? 0;
              final medium = double.tryParse(mediumController.text) ?? 0;

              if (bold <= 0 && float <= 0 && medium <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter at least one quantity')));
                return;
              }

              final dateStr = selectedDate.toIso8601String();
              Navigator.pop(ctx);

              // Non-admin users go through approval workflow
              if (!_isAdmin) {
                await _requestApproval(
                  actionType: 'add_purchase',
                  resourceType: 'stock',
                  proposedChanges: {
                    'bold': bold,
                    'float': float,
                    'medium': medium,
                    'date': dateStr,
                  },
                );
                return;
              }

              // Admin flow - execute directly
              setState(() => _status = '⏳ Adding purchase...');
              try {
                await _apiService.addPurchase([bold, float, medium], date: dateStr);
                if (!mounted) return;
                setState(() => _status = 'Purchase added.');
                await _init();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Purchase added and stock recalculated')));
              } catch (e) {
                if (!mounted) return;
                setState(() => _status = '❌ Purchase failed.');
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5D6E7E), 
              foregroundColor: Colors.white, 
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            child: Text(_isAdmin ? 'Add' : 'Request Approval'),
          ),
        ],
      ),
      ),
    );
  }

  void _openAdjustmentModal() {
    String selectedType = _stockTypes[0];
    String selectedGrade = _allGrades[0];
    bool isAdding = true; // true = Add, false = Subtract
    final deltaController = TextEditingController();
    final notesController = TextEditingController();
    DateTime selectedDate = DateTime.now();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => _buildGlassDialog(
          title: 'Stock Adjustment',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setDialogState(() => selectedDate = picked);
                },
                child: InputDecorator(
                  decoration: _inputDecoration('Date'),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(DateFormat('dd MMM yyyy').format(selectedDate), style: const TextStyle(fontSize: 13)),
                      const Icon(Icons.calendar_today, size: 16, color: Color(0xFF718096)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedType,
                decoration: _inputDecoration('Type'),
                borderRadius: BorderRadius.circular(20),
                items: _stockTypes.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 13)))).toList(),
                menuMaxHeight: 350,
                dropdownColor: AppTheme.bluishWhite,
                onChanged: (val) => setDialogState(() => selectedType = val!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedGrade,
                decoration: _inputDecoration('Grade'),
                borderRadius: BorderRadius.circular(20),
                items: _allGrades.map((g) {
                  final isVirtual = _virtualGrades.contains(g);
                  return DropdownMenuItem(
                    value: g, 
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(g, style: const TextStyle(fontSize: 13)),
                        if (isVirtual) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF4A5568).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('V', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
                menuMaxHeight: 400,
                dropdownColor: AppTheme.bluishWhite,
                onChanged: (val) => setDialogState(() => selectedGrade = val!),
              ),
              const SizedBox(height: 12),
              // Add / Subtract toggle
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF7FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => isAdding = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: isAdding ? const Color(0xFF48BB78) : Colors.transparent,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_circle_outline, size: 18, color: isAdding ? Colors.white : const Color(0xFF718096)),
                              const SizedBox(width: 6),
                              Text('Add', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isAdding ? Colors.white : const Color(0xFF718096))),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => isAdding = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: !isAdding ? const Color(0xFFE53E3E) : Colors.transparent,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.remove_circle_outline, size: 18, color: !isAdding ? Colors.white : const Color(0xFF718096)),
                              const SizedBox(width: 6),
                              Text('Subtract', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: !isAdding ? Colors.white : const Color(0xFF718096))),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildDialogField('Quantity (kg)', deltaController),
              _buildDialogField('Notes (optional)', notesController),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final rawDelta = double.tryParse(deltaController.text) ?? 0;
                if (rawDelta == 0) return;
                // Apply sign based on Add/Subtract toggle
                final delta = isAdding ? rawDelta.abs() : -(rawDelta.abs());

                Navigator.pop(ctx);

                final dateStr = selectedDate.toIso8601String();
                // Non-admin users go through approval workflow
                if (!_isAdmin) {
                  await _requestApproval(
                    actionType: 'stock_adjustment',
                    resourceType: 'stock',
                    proposedChanges: {
                      'type': selectedType,
                      'grade': selectedGrade,
                      'deltaKgs': delta,
                      'notes': '${isAdding ? "ADD" : "SUBTRACT"}: ${notesController.text}',
                      'date': dateStr,
                    },
                  );
                  return;
                }

                // Admin flow - execute directly
                setState(() => _status = '⏳ Applying adjustment...');
                try {
                  await _apiService.addStockAdjustment({
                    'type': selectedType,
                    'grade': selectedGrade,
                    'deltaKgs': delta,
                    'notes': '${isAdding ? "ADD" : "SUBTRACT"}: ${notesController.text}',
                    'date': dateStr,
                  });
                  if (!mounted) return;
                  setState(() => _status = 'Adjustment recorded.');
                  await _init();
                } catch (e) {
                  if (!mounted) return;
                  setState(() => _status = '❌ Adjustment failed.');
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5D6E7E), foregroundColor: Colors.white),
              child: Text(_isAdmin ? 'Apply' : 'Request Approval'),
            ),
          ],
        ),
      ),
    );
  }

  void _showHistorySheet(bool isMobile) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _StockHistorySheet(apiService: _apiService, isMobile: isMobile),
    );
  }

  Widget _buildGlassDialog({required String title, required Widget content, required List<Widget> actions}) {
    return Center(
      child: Container(
        width: 450,
        margin: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE3E3DE), Color(0xFFD1D1CB)],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20, offset: const Offset(0, 4)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                    const SizedBox(height: 12),
                    content,
                    const SizedBox(height: 16),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
      fillColor: Colors.white.withOpacity(0.5),
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    );
  }

  Widget _buildDialogField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: controller,
        decoration: _inputDecoration(label),
        keyboardType: TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      disableInternalScrolling: true,
      title: '📦 Stock Calculator',
      subtitle: 'Manage stock purchases, adjustments, and calculations.',
      topActions: [
        LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = MediaQuery.of(context).size.width < 600;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                _buildNavBtn(label: isMobile ? 'D-Board' : 'Dashboard', onPressed: () { if (Navigator.canPop(context)) Navigator.pop(context); else Navigator.pushReplacementNamed(context, '/'); }, color: const Color(0xFF5D6E7E), isMobile: isMobile),
                _buildNavBtn(label: isMobile ? 'Recalc' : '🔄 Recalculate', onPressed: _recalc, color: const Color(0xFF22C55E), isMobile: isMobile),
              ],
            );
          },
        ),
      ],
      content: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;
          return _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
            padding: EdgeInsets.symmetric(vertical: 20, horizontal: isMobile ? 12 : 16),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_isFromCache)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: CachedDataChip(ageString: _cacheAge),
                      ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          decoration: AppTheme.glassDecoration.copyWith(
                            borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                          ),
                          padding: EdgeInsets.all(isMobile ? 14 : 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(
                                child: Text(
                                  isMobile ? 'Stock Operations' : '📦 Stock Operations',
                                  style: TextStyle(fontSize: isMobile ? 18 : 22, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A), letterSpacing: -0.5),
                                ),
                              ),
                              SizedBox(height: isMobile ? 24 : 32),
                              _buildControls(isMobile),
                              const SizedBox(height: 24),
                              _buildStatusBox(isMobile),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: isMobile ? 24 : 32),
                    // SHORTAGE REPORT - Above Net Stock Table
                    if (_shortages.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            decoration: AppTheme.glassDecoration.copyWith(
                              borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                              color: const Color(0xFFFEECEC).withOpacity(0.9),
                            ),
                            padding: EdgeInsets.all(isMobile ? 14 : 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.trending_down, color: Colors.red[600], size: isMobile ? 20 : 24),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Shortage Report',
                                      style: TextStyle(
                                        fontSize: isMobile ? 16 : 18,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.red[700],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                ..._shortages.map((s) => Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFE5E5),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.warning_amber_rounded, color: Colors.red[400], size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(s, style: TextStyle(color: Colors.red[700], fontSize: isMobile ? 13 : 14)),
                                      ),
                                    ],
                                  ),
                                )),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_shortages.isNotEmpty) SizedBox(height: isMobile ? 16 : 24),
                    // NET STOCK TABLE
                    if (_netStock != null) 
                      ClipRRect(
                        borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            decoration: AppTheme.glassDecoration.copyWith(
                              borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                            ),
                            padding: EdgeInsets.all(isMobile ? 14 : 16),
                            child: _buildNetStockTable(isMobile),
                          ),
                        ),
                      ),
                    if (_deltaStatus.isNotEmpty || _shortages.isNotEmpty) ...[
                      SizedBox(height: isMobile ? 24 : 32),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            decoration: AppTheme.glassDecoration.copyWith(
                              borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
                            ),
                            padding: EdgeInsets.all(isMobile ? 14 : 16),
                            child: _buildDeltaStatus(isMobile),
                          ),
                        ),
                      ),
                    ],
                    // Bottom padding for floating navigation bar
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildNavBtn({required String label, required VoidCallback onPressed, required Color color, bool isMobile = false}) {
    return Container(
      height: isMobile ? 36 : 40,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: color,
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: Text(label, style: TextStyle(fontSize: isMobile ? 11 : 12, fontWeight: FontWeight.bold)),
      ),
    );
  }


  Widget _buildControls(bool isMobile) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildControlButton('🔄 Recalculate', const Color(0xFF22C55E), _recalc, isMobile),
        _buildControlButton('➕ Purchase', const Color(0xFF5D6E7E), _openPurchaseModal, isMobile),
        _buildControlButton('➕ Adjust', const Color(0xFF5D6E7E), _openAdjustmentModal, isMobile),
        _buildControlButton('📜 History', const Color(0xFF6366F1), () => _showHistorySheet(isMobile), isMobile),
        _buildControlButton('📉 Shortage', const Color(0xFFF43F5E), _showShortageReport, isMobile),
        _buildControlButton('🧹 Reset', const Color(0xFFF59E0B), _resetPointer, isMobile),
        _buildControlButton('🛠️ Rebuild', const Color(0xFF5D6E7E), _rebuild, isMobile),
        if (_isAdmin) _buildControlButton('🗑️ Clear Rej', const Color(0xFFEF4444), _clearRejection, isMobile),
      ],
    );
  }

  Widget _buildControlButton(String label, Color color, VoidCallback onPressed, bool isMobile) {
    return Container(
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 18, vertical: isMobile ? 10 : 14),
          child: Text(
            label, 
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: isMobile ? 12 : 13, color: color)
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBox(bool isMobile) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isMobile ? 14 : 20),
      decoration: BoxDecoration(
        color: const Color(0xFF5D6E7E).withOpacity(0.05),
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
        border: Border.all(color: const Color(0xFF5D6E7E).withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: const Color(0xFF5D6E7E), size: isMobile ? 16 : 18),
          SizedBox(width: isMobile ? 10 : 12),
          Expanded(child: Text(_status, style: TextStyle(fontWeight: FontWeight.bold, color: const Color(0xFF5D6E7E), fontSize: isMobile ? 12 : 13))),
        ],
      ),
    );
  }

  Widget _buildNetStockTable(bool isMobile) {
    final headers = (_netStock!['headers'] as List).cast<String>();
    final rows = _netStock!['rows'] as List;
    
    // Build a map of type -> grade -> value for easy lookup
    final Map<String, Map<String, num>> stockData = {};
    for (var row in rows) {
      final type = row['type'] as String;
      final values = (row['values'] as List).cast<num>();
      stockData[type] = {};
      for (int i = 0; i < headers.length && i < values.length; i++) {
        stockData[type]![headers[i]] = values[i];
      }
    }

    // MOBILE: Use StockAccordion for consistent accordion-style display
    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Net Stock Status', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
          const SizedBox(height: 16),
          StockAccordion(
            netStock: _netStock!,
            virtualGrades: _virtualGrades,
            stockTypes: _stockTypes,
            initiallyExpanded: true,
          ),
        ],
      );
    }

    // DESKTOP: Original table layout
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('📦 Net Stock Status', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.9),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row with grade labels
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9).withOpacity(0.7),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  border: const Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 90,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        child: Text('Type', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                      ),
                    ),
                    ...headers.where((grade) => !_virtualGrades.contains(grade)).map((grade) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                        child: Text(grade, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Color(0xFF64748B)), maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                    )),
                  ],
                ),
              ),
              // Data rows for each stock type
              ..._stockTypes.map((type) {
                final typeData = stockData[type] ?? {};
                return Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0), width: 0.5))),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                          child: Text(type, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF334155)), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      ...headers.where((grade) => !_virtualGrades.contains(grade)).map((grade) {
                        final val = (typeData[grade] ?? 0).round();
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                            child: val == 0
                                ? const SizedBox.shrink()
                                : Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: val < 0 ? const Color(0xFFFEF2F2) : (val < 50 ? Colors.orange.withOpacity(0.1) : const Color(0xFFF0FDF4)),
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(color: val < 0 ? const Color(0xFFFEE2E2) : (val < 50 ? Colors.orange.withOpacity(0.3) : const Color(0xFFDCFCE7))),
                                    ),
                                    child: Text(
                                      '${val > 0 ? "+" : ""}$val',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: val < 0 ? Colors.red : (val < 50 ? Colors.orange[800] : Colors.green[700])),
                                    ),
                                  ),
                          ),
                        );
                      }),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }


  Widget _buildDeltaStatus(bool isMobile) {
    // Parse the HTML delta status into structured data
    Widget parsedDeltaWidget = const SizedBox.shrink();
    
    if (_deltaStatus.isNotEmpty) {
      // Extract values from HTML using regex
      final processedRowMatch = RegExp(r'Processed up to row:</div><div><b>(\d+)</b>').firstMatch(_deltaStatus);
      final lastDateMatch = RegExp(r'Last processed date:</div><div><b>([^<]+)</b>').firstMatch(_deltaStatus);
      final liveStockRowMatch = RegExp(r'live_stock last row:</div><div><b>(\d+)</b>').firstMatch(_deltaStatus);
      final pendingRowsMatch = RegExp(r'Pending new rows:</div><div><b[^>]*>(\d+)</b>').firstMatch(_deltaStatus);
      final nextPendingMatch = RegExp(r'Next pending date:</div><div><b>([^<]+)</b>').firstMatch(_deltaStatus);
      final statusMsgMatch = RegExp(r'<div style="margin-top:8px[^"]*">([^<]+)</div>').firstMatch(_deltaStatus);
      
      final processedRow = processedRowMatch?.group(1) ?? '—';
      final lastDate = lastDateMatch?.group(1) ?? '—';
      final liveStockRow = liveStockRowMatch?.group(1) ?? '—';
      final pendingRows = pendingRowsMatch?.group(1) ?? '0';
      final nextPending = nextPendingMatch?.group(1) ?? '—';
      final statusMsg = statusMsgMatch?.group(1) ?? '';
      
      final isUpToDate = pendingRows == '0';
      
      parsedDeltaWidget = Container(
        width: double.infinity,
        padding: EdgeInsets.all(isMobile ? 16 : 20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isUpToDate ? const Color(0xFF22C55E).withOpacity(0.3) : const Color(0xFFF59E0B).withOpacity(0.3),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: (isUpToDate ? const Color(0xFF22C55E) : const Color(0xFFF59E0B)).withOpacity(0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (isUpToDate ? const Color(0xFF22C55E) : const Color(0xFFF59E0B)).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isUpToDate ? Icons.check_circle_rounded : Icons.pending_rounded,
                    size: 20,
                    color: isUpToDate ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Delta Mode Status',
                  style: TextStyle(
                    fontSize: isMobile ? 14 : 16,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0F172A),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Stats grid
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildDeltaStatItem('Processed Row', processedRow, Icons.table_rows_rounded, isMobile),
                _buildDeltaStatItem('Last Processed', lastDate, Icons.calendar_today_rounded, isMobile),
                _buildDeltaStatItem('Live Stock Row', liveStockRow, Icons.inventory_2_rounded, isMobile),
                _buildDeltaStatItem('Pending Rows', pendingRows, Icons.pending_actions_rounded, isMobile, 
                  highlight: !isUpToDate),
              ],
            ),
            if (statusMsg.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isUpToDate ? const Color(0xFFF0FDF4) : const Color(0xFFFFFBEB),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      isUpToDate ? Icons.check_rounded : Icons.info_outline_rounded,
                      size: 16,
                      color: isUpToDate ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        statusMsg,
                        style: TextStyle(
                          fontSize: isMobile ? 11 : 12,
                          fontWeight: FontWeight.w500,
                          color: isUpToDate ? const Color(0xFF15803D) : const Color(0xFF92400E),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_deltaStatus.isNotEmpty) ...[
          Text(
            isMobile ? 'Delta Status' : '⚙️ Delta Status', 
            style: TextStyle(fontSize: isMobile ? 16 : 18, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A))
          ),
          const SizedBox(height: 16),
          parsedDeltaWidget,
        ],
        // Shortage report is now shown above Net Stock Table, not here
      ],
    );
  }

  Widget _buildDeltaStatItem(String label, String value, IconData icon, bool isMobile, {bool highlight = false}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 12, vertical: isMobile ? 8 : 10),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFFFEF3C7) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlight ? const Color(0xFFFDE68A) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: isMobile ? 14 : 16, color: highlight ? const Color(0xFFF59E0B) : const Color(0xFF64748B)),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: isMobile ? 9 : 10,
                  color: const Color(0xFF64748B),
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: isMobile ? 11 : 12,
                  fontWeight: FontWeight.bold,
                  color: highlight ? const Color(0xFFB45309) : const Color(0xFF0F172A),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Stock History Bottom Sheet
// =============================================================================

class _StockHistorySheet extends StatefulWidget {
  final ApiService apiService;
  final bool isMobile;

  const _StockHistorySheet({required this.apiService, required this.isMobile});

  @override
  State<_StockHistorySheet> createState() => _StockHistorySheetState();
}

class _StockHistorySheetState extends State<_StockHistorySheet> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoading = true;
  List<dynamic> _purchases = [];
  List<dynamic> _adjustments = [];
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadHistory();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    try {
      final startStr = _startDate?.toIso8601String();
      final endStr = _endDate?.toIso8601String();
      final results = await Future.wait([
        widget.apiService.getStockPurchaseHistory(startDate: startStr, endDate: endStr),
        widget.apiService.getStockAdjustmentHistory(startDate: startStr, endDate: endStr),
      ]);
      if (!mounted) return;
      setState(() {
        _purchases = (results[0].data['entries'] as List?) ?? [];
        _adjustments = (results[1].data['entries'] as List?) ?? [];
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading stock history: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
    );
    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      await _loadHistory();
    }
  }

  void _clearFilter() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.85;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: AppTheme.titaniumLight,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.titaniumBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.history, color: AppTheme.primary, size: 22),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Stock History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.title)),
                ),
                if (_startDate != null)
                  GestureDetector(
                    onTap: _clearFilter,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${DateFormat('dd/MM').format(_startDate!)} - ${DateFormat('dd/MM').format(_endDate!)}',
                            style: const TextStyle(fontSize: 11, color: AppTheme.primary),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.close, size: 14, color: AppTheme.primary),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.date_range, color: AppTheme.primary, size: 20),
                  onPressed: _pickDateRange,
                  tooltip: 'Filter by date',
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: AppTheme.muted, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          // Tabs
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: AppTheme.machinedDecoration.copyWith(borderRadius: BorderRadius.circular(12)),
            child: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: AppTheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              labelColor: Colors.white,
              unselectedLabelColor: AppTheme.muted,
              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              tabs: [
                Tab(text: 'Purchases (${_purchases.length})'),
                Tab(text: 'Adjustments (${_adjustments.length})'),
              ],
            ),
          ),
          // Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildPurchaseList(),
                      _buildAdjustmentList(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPurchaseList() {
    if (_purchases.isEmpty) {
      return const Center(child: Text('No purchase entries found.', style: TextStyle(color: AppTheme.muted)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: _purchases.length,
      itemBuilder: (ctx, i) {
        final entry = _purchases[i] as Map<String, dynamic>;
        final bold = (entry['boldQty'] as num?)?.toDouble() ?? 0;
        final float = (entry['floatQty'] as num?)?.toDouble() ?? 0;
        final medium = (entry['mediumQty'] as num?)?.toDouble() ?? 0;
        final total = bold + float + medium;
        final ts = entry['timestamp'] as String?;
        final dateStr = ts != null ? DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.parse(ts).toLocal()) : 'N/A';

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: AppTheme.bevelDecoration.copyWith(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.shopping_cart_outlined, size: 16, color: AppTheme.primary),
                  const SizedBox(width: 6),
                  Expanded(child: Text(dateStr, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.title))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF22C55E).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('${total.toStringAsFixed(1)} kg', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF22C55E))),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _gradeChip('Bold', bold),
                  const SizedBox(width: 8),
                  _gradeChip('Float', float),
                  const SizedBox(width: 8),
                  _gradeChip('Medium', medium),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _gradeChip(String label, double value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.titaniumMid.withOpacity(0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.muted)),
            const SizedBox(height: 2),
            Text('${value.toStringAsFixed(1)} kg', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.title)),
          ],
        ),
      ),
    );
  }

  Widget _buildAdjustmentList() {
    if (_adjustments.isEmpty) {
      return const Center(child: Text('No adjustment entries found.', style: TextStyle(color: AppTheme.muted)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: _adjustments.length,
      itemBuilder: (ctx, i) {
        final entry = _adjustments[i] as Map<String, dynamic>;
        final type = entry['type'] as String? ?? '';
        final grade = entry['grade'] as String? ?? '';
        final delta = (entry['deltaKgs'] as num?)?.toDouble() ?? 0;
        final notes = entry['notes'] as String? ?? '';
        final appliedBy = entry['appliedBy'] as String? ?? '';
        final ts = entry['timestamp'] as String?;
        final dateStr = ts != null ? DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.parse(ts).toLocal()) : 'N/A';
        final isPositive = delta >= 0;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: AppTheme.bevelDecoration.copyWith(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isPositive ? Icons.add_circle_outline : Icons.remove_circle_outline,
                    size: 16,
                    color: isPositive ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(dateStr, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.title))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (isPositive ? const Color(0xFF22C55E) : const Color(0xFFEF4444)).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${isPositive ? '+' : ''}${delta.toStringAsFixed(1)} kg',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isPositive ? const Color(0xFF22C55E) : const Color(0xFFEF4444)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(type, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.titaniumMid.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(grade, style: const TextStyle(fontSize: 11, color: AppTheme.title)),
                  ),
                ],
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(notes, style: const TextStyle(fontSize: 12, color: AppTheme.muted)),
              ],
              if (appliedBy.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('By: $appliedBy', style: const TextStyle(fontSize: 11, color: AppTheme.muted, fontStyle: FontStyle.italic)),
              ],
            ],
          ),
        );
      },
    );
  }
}
