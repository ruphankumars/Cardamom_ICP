import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

class PackedBoxScreen extends StatefulWidget {
  const PackedBoxScreen({super.key});

  @override
  State<PackedBoxScreen> createState() => _PackedBoxScreenState();
}

class _PackedBoxScreenState extends State<PackedBoxScreen> {
  int _selectedPage = -1; // -1 = main menu

  @override
  Widget build(BuildContext context) {
    Widget content;
    String title = 'Packed Box';

    switch (_selectedPage) {
      case 0:
        content = _AddTodayPage(onBack: () => setState(() => _selectedPage = -1));
        title = 'Add Today';
        break;
      case 1:
        content = _BilledTodayPage(onBack: () => setState(() => _selectedPage = -1));
        title = 'Billed Today';
        break;
      case 2:
        content = _RemainingBoxPage(onBack: () => setState(() => _selectedPage = -1));
        title = 'Remaining Box Ready';
        break;
      case 3:
        content = _HistoryPage(onBack: () => setState(() => _selectedPage = -1));
        title = 'History';
        break;
      default:
        content = _buildMainMenu();
        title = 'Packed Box';
    }

    return AppShell(
      title: title,
      topActions: _selectedPage != -1
          ? [
              GestureDetector(
                onTap: () => setState(() => _selectedPage = -1),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.titaniumMid,
                    borderRadius: BorderRadius.circular(9999),
                    boxShadow: [
                      const BoxShadow(color: Colors.white70, blurRadius: 2, offset: Offset(-1, -1)),
                      BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 4, offset: const Offset(2, 2)),
                    ],
                  ),
                  child: Icon(Icons.arrow_back_rounded, size: 18, color: AppTheme.primary),
                ),
              ),
            ]
          : null,
      content: content,
    );
  }

  Widget _buildMainMenu() {
    final items = [
      _MenuOption(
        icon: Icons.add_box_rounded,
        label: 'Add Today',
        subtitle: 'Add packed boxes for today',
        color: AppTheme.success,
      ),
      _MenuOption(
        icon: Icons.receipt_long_rounded,
        label: 'Billed Today',
        subtitle: 'Mark boxes as billed/shipped',
        color: AppTheme.secondary,
      ),
      _MenuOption(
        icon: Icons.inventory_rounded,
        label: 'Remaining Box Ready',
        subtitle: 'View available packed boxes',
        color: AppTheme.primary,
      ),
      _MenuOption(
        icon: Icons.calendar_month_rounded,
        label: 'History',
        subtitle: 'Calendar-based history view',
        color: AppTheme.warning,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: items.asMap().entries.map((entry) {
          final idx = entry.key;
          final item = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GestureDetector(
              onTap: () => setState(() => _selectedPage = idx),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.titaniumLight, AppTheme.titaniumMid],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
                  boxShadow: [
                    const BoxShadow(color: Colors.white, blurRadius: 4, offset: Offset(-2, -2)),
                    BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(2, 2)),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: item.color.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(item.icon, color: item.color, size: 26),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.label,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.title,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.subtitle,
                            style: TextStyle(fontSize: 13, color: AppTheme.muted),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: AppTheme.muted, size: 24),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _MenuOption {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  const _MenuOption({required this.icon, required this.label, required this.subtitle, required this.color});
}

// ═══════════════════════════════════════════════════════════════════
// ADD TODAY SUB-PAGE
// ═══════════════════════════════════════════════════════════════════

class _AddTodayPage extends StatefulWidget {
  final VoidCallback onBack;
  const _AddTodayPage({required this.onBack});
  @override
  State<_AddTodayPage> createState() => _AddTodayPageState();
}

class _AddTodayPageState extends State<_AddTodayPage> {
  final ApiService _api = ApiService();
  bool _isLoading = true;
  bool _isSubmitting = false;

  List<String> _grades = [];
  List<String> _brands = [];
  String? _selectedGrade;
  String? _selectedBrand;
  final _boxController = TextEditingController();
  DateTime _selectedDate = DateTime.now();

  List<Map<String, dynamic>> _todayEntries = [];
  Map<String, dynamic>? _remainingSummary;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _boxController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      // Load dropdowns
      final dropRes = await _api.getDropdownOptions();
      final data = dropRes.data;
      if (data != null && data is Map) {
        _grades = List<String>.from(data['grade'] ?? data['grades'] ?? []);
        _brands = List<String>.from(data['brand'] ?? data['brands'] ?? []);
      }

      // Load today's entries
      await _loadTodayEntries();

      // Load remaining summary
      await _loadRemainingSummary();
    } catch (e) {
      debugPrint('Error loading packed box data: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadTodayEntries() async {
    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final res = await _api.getPackedBoxesToday(dateStr);
      if (res.data is Map && res.data['entries'] is List) {
        _todayEntries = List<Map<String, dynamic>>.from(res.data['entries']);
      } else if (res.data is List) {
        _todayEntries = List<Map<String, dynamic>>.from(res.data);
      }
      // Normalize field names: backend uses boxesAdded/boxesBilled, UI uses boxes/billed
      for (var e in _todayEntries) {
        e['boxes'] = e['boxesAdded'] ?? e['boxes'] ?? 0;
        e['billed'] = e['boxesBilled'] ?? e['billed'] ?? 0;
      }
    } catch (e) {
      debugPrint('Error loading today entries: $e');
    }
  }

  Future<void> _loadRemainingSummary() async {
    try {
      final res = await _api.getRemainingBoxes();
      if (res.data is Map && res.data['remaining'] is List) {
        final items = List<Map<String, dynamic>>.from(res.data['remaining']);
        int totalBoxes = 0;
        int totalKgs = 0;
        for (var item in items) {
          totalBoxes += (item['remainingBoxes'] as num?)?.toInt() ?? 0;
          totalKgs += (item['remainingKgs'] as num?)?.toInt() ?? 0;
        }
        _remainingSummary = {'totalBoxes': totalBoxes, 'totalKgs': totalKgs, 'items': items};
      } else if (res.data is Map) {
        _remainingSummary = Map<String, dynamic>.from(res.data);
      }
    } catch (e) {
      debugPrint('Error loading remaining: $e');
    }
  }

  int get _quantity {
    final boxes = int.tryParse(_boxController.text) ?? 0;
    return boxes * 20;
  }

  Future<void> _submit() async {
    if (_selectedGrade == null || _selectedBrand == null || _boxController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields'), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await _api.addPackedBoxes({
        'grade': _selectedGrade,
        'brand': _selectedBrand,
        'boxes': int.tryParse(_boxController.text) ?? 0,
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Packed boxes added'),
          backgroundColor: AppTheme.success,
        ),
      );
      _boxController.clear();
      _selectedGrade = null;
      _selectedBrand = null;
      await _loadTodayEntries();
      await _loadRemainingSummary();
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
    if (mounted) setState(() => _isSubmitting = false);
  }

  Future<void> _deleteEntry(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry'),
        content: const Text('Are you sure you want to delete this entry?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.deletePackedBoxEntry(id);
      await _loadTodayEntries();
      await _loadRemainingSummary();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
      await _loadTodayEntries();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.primary));
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Remaining summary card
          if (_remainingSummary != null) _buildRemainingSummaryCard(),
          const SizedBox(height: 16),

          // Form card
          _buildFormCard(),
          const SizedBox(height: 16),

          // Today's entries
          if (_todayEntries.isNotEmpty) _buildTodayEntriesCard(),
        ],
      ),
    );
  }

  Widget _buildRemainingSummaryCard() {
    final totalBoxes = _remainingSummary?['totalBoxes'] ?? 0;
    final totalKgs = _remainingSummary?['totalKgs'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.success.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.success.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.inventory_rounded, color: AppTheme.success, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Remaining Boxes Available Till Today',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.success),
                ),
                const SizedBox(height: 4),
                Text(
                  '$totalBoxes boxes ($totalKgs kgs)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.title),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AppTheme.bevelDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add Packed Boxes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.title)),
          const SizedBox(height: 16),

          // Grade dropdown
          _buildDropdown(
            label: 'Grade',
            value: _selectedGrade,
            items: _grades,
            onChanged: (v) => setState(() => _selectedGrade = v),
          ),
          const SizedBox(height: 12),

          // Brand dropdown
          _buildDropdown(
            label: 'Brand',
            value: _selectedBrand,
            items: _brands,
            onChanged: (v) => setState(() => _selectedBrand = v),
          ),
          const SizedBox(height: 12),

          // No of Box
          _buildTextField(
            label: 'No of Box',
            controller: _boxController,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),

          // Quantity (auto-calculated)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.titaniumMid.withOpacity(0.4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.titaniumBorder),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Quantity (kgs)', style: TextStyle(fontSize: 14, color: AppTheme.muted)),
                Text(
                  '$_quantity kgs',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.title),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Date picker
          GestureDetector(
            onTap: _pickDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.titaniumBorder),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Date', style: TextStyle(fontSize: 14, color: AppTheme.muted)),
                  Row(
                    children: [
                      Text(
                        DateFormat('dd MMM yyyy').format(_selectedDate),
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.title),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.calendar_today_rounded, size: 18, color: AppTheme.primary),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Submit button
          ElevatedButton(
            onPressed: _isSubmitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 0,
            ),
            child: _isSubmitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('Add Packed Boxes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildTodayEntriesCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.bevelDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Today's Entries (${DateFormat('dd MMM').format(_selectedDate)})",
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.title),
          ),
          const SizedBox(height: 12),
          ..._todayEntries.map((entry) {
            final grade = entry['grade'] ?? '';
            final brand = entry['brand'] ?? '';
            final boxes = entry['boxes'] ?? 0;
            final id = entry['id'] ?? entry['_id'] ?? '';
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.titaniumBorder.withOpacity(0.5)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(grade, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.title)),
                        Text(brand, style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                      ],
                    ),
                  ),
                  Text('$boxes boxes', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  const SizedBox(width: 8),
                  Text('${boxes * 20} kgs', style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                  const SizedBox(width: 8),
                  if (id.toString().isNotEmpty)
                    GestureDetector(
                      onTap: () => _deleteEntry(id.toString()),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppTheme.danger.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.delete_outline_rounded, size: 16, color: AppTheme.danger),
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

  Widget _buildDropdown({
    required String label,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppTheme.muted, fontSize: 14),
        filled: true,
        fillColor: Colors.white.withOpacity(0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.titaniumBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.titaniumBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      items: items.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 14)))).toList(),
      onChanged: onChanged,
      isExpanded: true,
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppTheme.muted, fontSize: 14),
        filled: true,
        fillColor: Colors.white.withOpacity(0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.titaniumBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.titaniumBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// BILLED TODAY SUB-PAGE
// ═══════════════════════════════════════════════════════════════════

class _BilledTodayPage extends StatefulWidget {
  final VoidCallback onBack;
  const _BilledTodayPage({required this.onBack});
  @override
  State<_BilledTodayPage> createState() => _BilledTodayPageState();
}

class _BilledTodayPageState extends State<_BilledTodayPage> {
  final ApiService _api = ApiService();
  bool _isLoading = true;
  bool _isSaving = false;
  List<Map<String, dynamic>> _entries = [];
  final Map<String, TextEditingController> _billedControllers = {};

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  @override
  void dispose() {
    for (final c in _billedControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadEntries() async {
    setState(() => _isLoading = true);
    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final res = await _api.getPackedBoxesToday(dateStr);
      if (res.data is Map && res.data['entries'] is List) {
        _entries = List<Map<String, dynamic>>.from(res.data['entries']);
      } else if (res.data is List) {
        _entries = List<Map<String, dynamic>>.from(res.data);
      }
      // Normalize field names
      for (var e in _entries) {
        e['boxes'] = e['boxesAdded'] ?? e['boxes'] ?? 0;
        e['billed'] = e['boxesBilled'] ?? e['billed'] ?? 0;
      }
      // Create controllers for billed values
      _billedControllers.clear();
      for (final entry in _entries) {
        final key = '${entry['grade']}_${entry['brand']}_${entry['id'] ?? ''}';
        final billed = entry['billed'] ?? 0;
        _billedControllers[key] = TextEditingController(text: billed.toString());
      }
    } catch (e) {
      debugPrint('Error loading billed entries: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      final updates = <Map<String, dynamic>>[];
      for (final entry in _entries) {
        final key = '${entry['grade']}_${entry['brand']}_${entry['id'] ?? ''}';
        final controller = _billedControllers[key];
        if (controller != null) {
          final billed = int.tryParse(controller.text) ?? 0;
          updates.add({
            'id': entry['id'] ?? entry['_id'],
            'grade': entry['grade'],
            'brand': entry['brand'],
            'billed': billed,
            'date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
          });
        }
      }
      await _api.updateBilledBoxes({'entries': updates});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Billed data saved'), backgroundColor: AppTheme.success),
      );
      await _loadEntries();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
    if (mounted) setState(() => _isSaving = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.primary));
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_rounded, size: 48, color: AppTheme.muted.withOpacity(0.4)),
            const SizedBox(height: 12),
            Text('No entries for today', style: TextStyle(fontSize: 16, color: AppTheme.muted)),
            const SizedBox(height: 8),
            Text('Add packed boxes first', style: TextStyle(fontSize: 13, color: AppTheme.muted.withOpacity(0.6))),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.bevelDecoration,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Today's Entries - Mark Billed",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.title),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('dd MMM yyyy').format(DateTime.now()),
                  style: TextStyle(fontSize: 12, color: AppTheme.muted),
                ),
                const SizedBox(height: 16),

                // Header row
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(flex: 2, child: Text('Grade/Brand', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary))),
                      Expanded(child: Text('Added', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary), textAlign: TextAlign.center)),
                      Expanded(child: Text('Billed', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary), textAlign: TextAlign.center)),
                      Expanded(child: Text('Remain', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary), textAlign: TextAlign.center)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Data rows
                ..._entries.map((entry) {
                  final key = '${entry['grade']}_${entry['brand']}_${entry['id'] ?? ''}';
                  final controller = _billedControllers[key];
                  final added = entry['boxes'] ?? 0;
                  final billed = int.tryParse(controller?.text ?? '0') ?? 0;
                  final remaining = added - billed;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.titaniumBorder.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry['grade'] ?? '', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.title)),
                              Text(entry['brand'] ?? '', style: TextStyle(fontSize: 11, color: AppTheme.muted)),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Text('$added', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.title), textAlign: TextAlign.center),
                        ),
                        Expanded(
                          child: SizedBox(
                            height: 36,
                            child: TextFormField(
                              controller: controller,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              onChanged: (_) => setState(() {}),
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                              decoration: InputDecoration(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.titaniumBorder)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.titaniumBorder)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.primary)),
                                filled: true,
                                fillColor: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '$remaining',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: remaining < 0 ? AppTheme.danger : AppTheme.success,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  );
                }),

                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _isSaving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  child: _isSaving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Save Billed Data', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// REMAINING BOX READY SUB-PAGE
// ═══════════════════════════════════════════════════════════════════

class _RemainingBoxPage extends StatefulWidget {
  final VoidCallback onBack;
  const _RemainingBoxPage({required this.onBack});
  @override
  State<_RemainingBoxPage> createState() => _RemainingBoxPageState();
}

class _RemainingBoxPageState extends State<_RemainingBoxPage> {
  final ApiService _api = ApiService();
  bool _isLoading = true;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final res = await _api.getRemainingBoxes();
      if (res.data is Map && res.data['remaining'] is List) {
        _items = List<Map<String, dynamic>>.from(res.data['remaining']);
      } else if (res.data is Map && res.data['items'] is List) {
        _items = List<Map<String, dynamic>>.from(res.data['items']);
      } else if (res.data is List) {
        _items = List<Map<String, dynamic>>.from(res.data);
      }
    } catch (e) {
      debugPrint('Error loading remaining boxes: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.primary));
    }

    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline_rounded, size: 48, color: AppTheme.success.withOpacity(0.4)),
            const SizedBox(height: 12),
            Text('No remaining boxes', style: TextStyle(fontSize: 16, color: AppTheme.muted)),
            const SizedBox(height: 8),
            Text('All boxes have been billed', style: TextStyle(fontSize: 13, color: AppTheme.muted.withOpacity(0.6))),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.bevelDecoration,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Remaining Boxes Ready',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.title),
                    ),
                    GestureDetector(
                      onTap: _load,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppTheme.titaniumMid,
                          borderRadius: BorderRadius.circular(9999),
                          boxShadow: [
                            const BoxShadow(color: Colors.white70, blurRadius: 2, offset: Offset(-1, -1)),
                            BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 4, offset: const Offset(2, 2)),
                          ],
                        ),
                        child: Icon(Icons.refresh_rounded, size: 18, color: AppTheme.primary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(flex: 2, child: Text('Grade', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary))),
                      Expanded(flex: 2, child: Text('Brand', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary))),
                      Expanded(child: Text('Boxes', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary), textAlign: TextAlign.center)),
                      Expanded(child: Text('Kgs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary), textAlign: TextAlign.center)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                ..._items.map((item) {
                  final boxes = item['remainingBoxes'] ?? item['boxes'] ?? 0;
                  final kgs = item['remainingKgs'] ?? (boxes * 20);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.titaniumBorder.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        Expanded(flex: 2, child: Text(item['grade'] ?? '', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.title))),
                        Expanded(flex: 2, child: Text(item['brand'] ?? '', style: TextStyle(fontSize: 13, color: AppTheme.muted))),
                        Expanded(child: Text('$boxes', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primary), textAlign: TextAlign.center)),
                        Expanded(child: Text('$kgs', style: TextStyle(fontSize: 13, color: AppTheme.muted), textAlign: TextAlign.center)),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// HISTORY SUB-PAGE
// ═══════════════════════════════════════════════════════════════════

class _HistoryPage extends StatefulWidget {
  final VoidCallback onBack;
  const _HistoryPage({required this.onBack});
  @override
  State<_HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<_HistoryPage> {
  final ApiService _api = ApiService();
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = false;
  List<Map<String, dynamic>> _historyData = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final res = await _api.getPackedBoxHistory(dateStr);
      if (res.data is Map && res.data['entries'] is List) {
        _historyData = List<Map<String, dynamic>>.from(res.data['entries']);
      } else if (res.data is List) {
        _historyData = List<Map<String, dynamic>>.from(res.data);
      }
      // Normalize field names
      for (var e in _historyData) {
        e['boxes'] = e['boxesAdded'] ?? e['boxes'] ?? 0;
        e['billed'] = e['boxesBilled'] ?? e['billed'] ?? 0;
      }
    } catch (e) {
      debugPrint('Error loading history: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
      await _loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Date selector
          GestureDetector(
            onTap: _pickDate,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: AppTheme.bevelDecoration,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.calendar_month_rounded, color: AppTheme.primary, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Selected Date', style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                          const SizedBox(height: 2),
                          Text(
                            DateFormat('dd MMM yyyy, EEEE').format(_selectedDate),
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.title),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Icon(Icons.edit_calendar_rounded, color: AppTheme.primary, size: 22),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // History data
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
            )
          else if (_historyData.isEmpty)
            Container(
              padding: const EdgeInsets.all(32),
              decoration: AppTheme.bevelDecoration,
              child: Column(
                children: [
                  Icon(Icons.history_rounded, size: 48, color: AppTheme.muted.withOpacity(0.4)),
                  const SizedBox(height: 12),
                  Text('No data for this date', style: TextStyle(fontSize: 16, color: AppTheme.muted)),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: AppTheme.bevelDecoration,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Packed Box History',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.title),
                  ),
                  const SizedBox(height: 16),

                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Expanded(flex: 2, child: Text('Grade/Brand', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary))),
                        Expanded(child: Text('Added', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary), textAlign: TextAlign.center)),
                        Expanded(child: Text('Billed', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary), textAlign: TextAlign.center)),
                        Expanded(child: Text('Remain', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary), textAlign: TextAlign.center)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  ..._historyData.map((entry) {
                    final added = entry['boxes'] ?? 0;
                    final billed = entry['billed'] ?? 0;
                    final remaining = added - billed;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.titaniumBorder.withOpacity(0.5)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(entry['grade'] ?? '', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.title)),
                                Text(entry['brand'] ?? '', style: TextStyle(fontSize: 11, color: AppTheme.muted)),
                              ],
                            ),
                          ),
                          Expanded(child: Text('$added', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.title), textAlign: TextAlign.center)),
                          Expanded(child: Text('$billed', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.secondary), textAlign: TextAlign.center)),
                          Expanded(
                            child: Text(
                              '$remaining',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: remaining > 0 ? AppTheme.success : AppTheme.muted,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
