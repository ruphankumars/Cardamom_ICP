import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/api_service.dart';

class WebDropdownManagement extends StatefulWidget {
  const WebDropdownManagement({super.key});

  @override
  State<WebDropdownManagement> createState() => _WebDropdownManagementState();
}

class _WebDropdownManagementState extends State<WebDropdownManagement> with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;
  bool _isLoading = true;

  final List<_TabInfo> _tabs = [
    _TabInfo('Clients', 'clients', Icons.people),
    _TabInfo('Grades', 'grades', Icons.grain),
    _TabInfo('Bag/Box', 'bagbox', Icons.inventory_2),
    _TabInfo('Brands', 'brands', Icons.branding_watermark),
    _TabInfo('Workers', 'workers', Icons.badge),
  ];

  final Map<String, List<String>> _data = {
    'clients': [],
    'grades': [],
    'bagbox': [],
    'brands': [],
    'workers': [],
  };

  String _searchQuery = '';
  // Inline editing state
  String? _editingItem;
  final TextEditingController _editController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          _searchQuery = '';
          _editingItem = null;
        });
      }
    });
    _loadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _editController.dispose();
    super.dispose();
  }

  String get _currentCategory => _tabs[_tabController.index].category;

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getDropdownOptions();
      final d = response.data;
      if (!mounted) return;

      final workersResponse = await _apiService.getWorkers();
      final workers = workersResponse.data is List
          ? (workersResponse.data as List).map((w) => w['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList()
          : <String>[];

      setState(() {
        _data['clients'] = List<String>.from(d['client'] ?? []);
        _data['grades'] = List<String>.from(d['grade'] ?? []);
        _data['bagbox'] = List<String>.from(d['bagbox'] ?? []);
        _data['brands'] = List<String>.from(d['brand'] ?? []);
        _data['workers'] = List<String>.from(workers);
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading dropdowns: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  List<String> get _filteredItems {
    final items = _data[_currentCategory] ?? [];
    if (_searchQuery.isEmpty) return items;
    return items.where((i) => i.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
  }

  Future<void> _addItem(String value) async {
    if (value.isEmpty) return;

    // For clients and workers, check for similar names first
    if (_currentCategory == 'clients' || _currentCategory == 'workers') {
      List<Map<String, dynamic>> similarItems = [];
      try {
        final response = _currentCategory == 'workers'
            ? await _apiService.searchWorkers(value)
            : await _apiService.searchDropdownItems(_currentCategory, value);
        final data = response.data as Map<String, dynamic>;
        final exact = (data['exactMatches'] as List<dynamic>?) ?? [];
        final similar = (data['similarMatches'] as List<dynamic>?) ?? [];
        similarItems = [...exact, ...similar].cast<Map<String, dynamic>>();
      } catch (e) {
        debugPrint('Error searching for similar items: $e');
      }

      if (!mounted) return;

      bool shouldAdd = true;
      if (similarItems.isNotEmpty) {
        final label = _currentCategory == 'workers' ? 'Worker' : 'Client';
        shouldAdd = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text('Similar $label Found', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Found ${label.toLowerCase()}s with similar names:'),
                const SizedBox(height: 12),
                ...similarItems.take(5).map((c) {
                  final itemName = c['value'] ?? c['name'] ?? '';
                  final similarity = c['similarity'];
                  final pct = similarity != null
                      ? (similarity is int ? '$similarity% similar' : '${(similarity * 100).toInt()}% similar')
                      : '';
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: const Color(0xFFE2E8F0),
                      child: Text(
                        itemName.isNotEmpty ? itemName[0].toUpperCase() : '?',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF5D6E7E)),
                      ),
                    ),
                    title: Text(itemName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: pct.isNotEmpty
                        ? Text(pct, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12))
                        : null,
                  );
                }),
                const SizedBox(height: 12),
                Text('Do you still want to add "$value" as a new ${label.toLowerCase()}?'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
                child: const Text('Add Anyway', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ) ?? false;
      }

      if (!shouldAdd || !mounted) return;

      try {
        final result = _currentCategory == 'workers'
            ? (similarItems.isNotEmpty
                ? await _apiService.forceAddWorker({'name': value})
                : await _apiService.addWorker({'name': value}))
            : (similarItems.isNotEmpty
                ? await _apiService.forceAddDropdownItem(_currentCategory, value)
                : await _apiService.addDropdownItem(_currentCategory, value));
        if (!mounted) return;
        if (result.data['success'] == true) {
          setState(() => _data[_currentCategory]?.add(value));
          _showSnackBar('"$value" added');
        } else if (result.data['isDuplicate'] == true) {
          _showSnackBar('"${result.data['existingValue']}" already exists', isError: true);
        }
      } catch (e) {
        _showSnackBar('Error: $e', isError: true);
      }
      return;
    }

    // For other categories (grades, bagbox, brands) — direct add
    try {
      final result = await _apiService.addDropdownItem(_currentCategory, value);
      if (!mounted) return;
      if (result.data['success'] == true) {
        setState(() => _data[_currentCategory]?.add(value));
        _showSnackBar('"$value" added');
      } else if (result.data['isDuplicate'] == true) {
        _showSnackBar('"${result.data['existingValue']}" already exists', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  Future<void> _editItem(String oldValue, String newValue) async {
    if (newValue.isEmpty || oldValue == newValue) {
      setState(() => _editingItem = null);
      return;
    }
    try {
      final result = _currentCategory == 'workers'
          ? await _apiService.updateWorker(oldValue, {'name': newValue})
          : await _apiService.updateDropdownItem(_currentCategory, oldValue, newValue);
      if (!mounted) return;
      if (result.data['success'] == true) {
        setState(() {
          final list = _data[_currentCategory]!;
          final idx = list.indexOf(oldValue);
          if (idx >= 0) list[idx] = newValue;
          _editingItem = null;
        });
        _showSnackBar('Renamed "$oldValue" to "$newValue"');
      } else {
        _showSnackBar(result.data['error'] ?? 'Update failed', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  Future<void> _deleteItem(String value) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete Item'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Delete "$value"?'),
            const SizedBox(height: 8),
            Text(
              'Existing orders referencing this value will not be affected.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444), foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final result = _currentCategory == 'workers'
          ? await _apiService.deleteWorker(value)
          : await _apiService.deleteDropdownItem(_currentCategory, value);
      if (!mounted) return;
      if (result.data['success'] == true) {
        setState(() => _data[_currentCategory]?.remove(value));
        _showSnackBar('"$value" deleted');
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  void _showAddDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Add ${_tabs[_tabController.index].label}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: 'Enter new value',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onSubmitted: (_) {
            Navigator.pop(ctx);
            _addItem(controller.text.trim());
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _addItem(controller.text.trim());
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22C55E), foregroundColor: Colors.white),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF5D6E7E)))
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Sidebar tabs
                      _buildSidebar(),
                      // Content
                      Expanded(child: _buildItemsPanel()),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Dropdown Management', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
              const SizedBox(height: 4),
              Text('Manage dropdown options for orders and system forms', style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF6B7280))),
            ],
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _showAddDialog,
            icon: const Icon(Icons.add, size: 18),
            label: Text('Add Item', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF22C55E),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 220,
      margin: const EdgeInsets.fromLTRB(24, 24, 0, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _tabs.length,
        itemBuilder: (context, index) {
          final tab = _tabs[index];
          final isActive = _tabController.index == index;
          final count = _data[tab.category]?.length ?? 0;
          return InkWell(
            onTap: () => setState(() => _tabController.index = index),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isActive ? const Color(0xFF5D6E7E).withOpacity(0.08) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(tab.icon, size: 18, color: isActive ? const Color(0xFF5D6E7E) : const Color(0xFF9CA3AF)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tab.label,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                        color: isActive ? const Color(0xFF111827) : const Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: isActive ? const Color(0xFF5D6E7E).withOpacity(0.12) : const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF6B7280)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildItemsPanel() {
    final items = _filteredItems;
    return Container(
      margin: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      child: Column(
        children: [
          // Search header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F5F9),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Text(
                  '${_tabs[_tabController.index].label} (${_data[_currentCategory]?.length ?? 0})',
                  style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700, color: const Color(0xFF111827)),
                ),
                const Spacer(),
                SizedBox(
                  width: 260,
                  child: TextField(
                    onChanged: (v) => setState(() => _searchQuery = v),
                    decoration: InputDecoration(
                      hintText: 'Search...',
                      hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9CA3AF)),
                      prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Items list
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inbox_outlined, size: 48, color: Colors.grey[300]),
                        const SizedBox(height: 12),
                        Text(
                          _searchQuery.isEmpty ? 'No items' : 'No matching items',
                          style: GoogleFonts.inter(color: const Color(0xFF9CA3AF)),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                    itemBuilder: (context, index) => _buildItemRow(items[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemRow(String item) {
    final isEditing = _editingItem == item;

    if (isEditing) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        color: const Color(0xFFFFFBEB),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _editController,
                autofocus: true,
                style: GoogleFonts.inter(fontSize: 14),
                decoration: InputDecoration(
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  isDense: true,
                ),
                onSubmitted: (v) => _editItem(item, v.trim()),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.check, size: 18, color: Color(0xFF22C55E)),
              onPressed: () => _editItem(item, _editController.text.trim()),
              tooltip: 'Save',
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
              onPressed: () => setState(() => _editingItem = null),
              tooltip: 'Cancel',
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(item, style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF111827))),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16, color: Color(0xFF3B82F6)),
            onPressed: () {
              setState(() {
                _editingItem = item;
                _editController.text = item;
              });
            },
            tooltip: 'Edit',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16, color: Color(0xFFEF4444)),
            onPressed: () => _deleteItem(item),
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
}

class _TabInfo {
  final String label;
  final String category;
  final IconData icon;
  const _TabInfo(this.label, this.category, this.icon);
}
