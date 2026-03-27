import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../models/worker.dart';
import '../services/attendance_service.dart';
import '../services/auth_provider.dart';
import '../services/cache_manager.dart';
import '../services/navigation_service.dart';
import '../services/notification_service.dart';
import '../widgets/offline_indicator.dart';

class AttendanceDashboardScreen extends StatefulWidget {
  final String? initialDate; // Optional date parameter for viewing specific dates
  
  const AttendanceDashboardScreen({super.key, this.initialDate});

  @override
  State<AttendanceDashboardScreen> createState() => _AttendanceDashboardScreenState();
}

class _AttendanceDashboardScreenState extends State<AttendanceDashboardScreen> with RouteAware {
  final TextEditingController _searchController = TextEditingController();
  List<Worker> _filteredWorkers = [];
  bool _showSearchResults = false;
  bool _isLoading = true;
  final FocusNode _searchFocusNode = FocusNode();
  late String _selectedDate; // The date being viewed
  
  // Offline cache state
  bool _isFromCache = false;
  String _cacheAge = '';

  // Bulk wage selection state
  final Set<String> _selectedWorkerIds = {};
  bool get _isSelectionMode => _selectedWorkerIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Use passed date or default to today
    _selectedDate = widget.initialDate ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
    _loadData();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  void didPopNext() => _loadData();

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final service = Provider.of<AttendanceService>(context, listen: false);
    try {
      final cacheManager = context.read<CacheManager>();
      final result = await cacheManager.fetchWithCache<Map<String, dynamic>>(
        apiCall: () async {
          await Future.wait([
            service.loadWorkers(),
            service.loadSummary(_selectedDate),
          ]);
          // Bundle into a cacheable map
          return {
            'workers': service.workers.map((w) => w.toJson()).toList(),
            'date': _selectedDate,
          };
        },
        cache: cacheManager.attendanceCache,
      );
      // When loaded from cache, restore workers into the service
      if (result.fromCache && service.workers.isEmpty) {
        final cachedWorkers = result.data['workers'] as List<dynamic>? ?? [];
        if (cachedWorkers.isNotEmpty) {
          service.restoreWorkersFromCache(
            cachedWorkers.map((w) => Worker.fromJson(w as Map<String, dynamic>)).toList(),
          );
        }
      }
      setState(() {
        _isFromCache = result.fromCache;
        _cacheAge = result.ageString;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading attendance data: $e');
      setState(() => _isLoading = false);
    }
  }

  /// Check if viewing today's attendance
  bool get _isToday {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    return _selectedDate == today;
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _filteredWorkers = [];
        _showSearchResults = false;
      });
      return;
    }

    final service = Provider.of<AttendanceService>(context, listen: false);
    final todayAttendance = service.todaySummary?.workers.map((a) => a.workerId).toSet() ?? {};
    
    // Filter workers not already marked for today
    final available = service.workers.where((w) => 
      !todayAttendance.contains(w.id) &&
      w.name.toLowerCase().contains(query.toLowerCase())
    ).toList();

    setState(() {
      _filteredWorkers = available.take(5).toList();
      _showSearchResults = true;
    });
  }

  Future<void> _addWorkerToAttendance(Worker worker) async {
    final service = Provider.of<AttendanceService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);

    await service.markAttendance(
      workerId: worker.id,
      workerName: worker.name,
      date: _selectedDate, // Use selected date
      status: AttendanceStatus.full,
      wageOverride: null, // Keep wage empty initially - set later
      markedBy: auth.username ?? 'Unknown',
    );

    // Explicitly reload summary for selected date to ensure UI updates
    await service.loadSummary(_selectedDate);

    if (!mounted) return;
    _searchController.clear();
    if (mounted) {
      setState(() {
        _showSearchResults = false;
      });
    }
  }

  Future<void> _showNewWorkerDialog(String name) async {
    final service = Provider.of<AttendanceService>(context, listen: false);
    
    // First search for similar names
    final searchResult = await service.searchWorkers(name);
    
    if (!mounted) return;

    if (searchResult.hasMatches) {
      // Show confirmation dialog with similar names
      final shouldAdd = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Similar Worker Found', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Found workers with similar names:'),
              const SizedBox(height: 12),
              ...searchResult.exactMatches.take(3).map((w) => _buildSimilarWorkerTile(w)),
              ...searchResult.similarMatches.take(3).map((w) => _buildSimilarWorkerTile(w, showSimilarity: true)),
              const SizedBox(height: 12),
              Text('Do you still want to add "$name" as a new worker?'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
              child: const Text('Add Anyway'),
            ),
          ],
        ),
      );

      if (shouldAdd != true) return;
      
      // Force add
      final result = await service.forceAddWorker(name: name);
      _notifyNewWorkerAdded(name, result);
    } else {
      // No similar matches, add directly
      final result = await service.addWorker(name: name);
      _notifyNewWorkerAdded(name, result);
    }

    if (!mounted) return;
    _searchController.clear();
    setState(() => _showSearchResults = false);

    // Reload workers list to ensure it's updated
    await service.loadWorkers();
    if (!mounted) return;
  }

  /// Trigger a notification when a new worker is added
  void _notifyNewWorkerAdded(String workerName, Map<String, dynamic> result) {
    if (!mounted) return;
    if (result['success'] == true) {
      // Show success SnackBar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text('Worker "$workerName" added successfully!')),
            ],
          ),
          backgroundColor: AppTheme.success,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      
      // Also add to notification center
      final notificationService = Provider.of<NotificationService>(context, listen: false);
      final auth = Provider.of<AuthProvider>(context, listen: false);
      
      notificationService.addNotification(AppNotification(
        id: 'new_worker_${DateTime.now().millisecondsSinceEpoch}',
        title: 'New Worker Added',
        body: 'Worker "$workerName" was added by ${auth.username ?? "someone"}',
        timestamp: DateTime.now(),
        type: 'alert',
      ));
    } else {
      // Show error message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text(result['error'] ?? 'Failed to add worker')),
            ],
          ),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _buildSimilarWorkerTile(Worker worker, {bool showSimilarity = false}) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: AppTheme.titaniumMid,
        child: Text(
          worker.name.isNotEmpty ? worker.name[0].toUpperCase() : '?',
          style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: AppTheme.primary),
        ),
      ),
      title: Text(worker.name),
      trailing: showSimilarity && worker.similarity != null
        ? Text('${(worker.similarity! * 100).toInt()}% similar', 
            style: TextStyle(color: AppTheme.muted, fontSize: 12))
        : null,
      onTap: () {
        Navigator.pop(context);
        _addWorkerToAttendance(worker);
      },
    );
  }

  Future<void> _showStatusDialog(AttendanceRecord record) async {
    final service = Provider.of<AttendanceService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    
    AttendanceStatus selectedStatus = record.status;
    double otHours = record.otHours;
    // Only prefill wage if user has explicitly set it (wageOverride != null)
    double? wageAmount = record.wageOverride != null && record.wageOverride! > 0 ? record.wageOverride : null;
    final otController = TextEditingController(text: otHours > 0 ? otHours.toString() : '');
    final wageController = TextEditingController(text: wageAmount != null ? wageAmount.toStringAsFixed(0) : '');

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.titaniumLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: AppTheme.primary,
                    child: Text(record.workerName[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(record.workerName, 
                      style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: AppTheme.danger),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await service.removeAttendance(record.date, record.workerId);
                    },
                  ),
                ],
              ),
              const Divider(height: 24),
              Text('Attendance Type', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: AttendanceStatus.values.map((status) {
                  final isSelected = selectedStatus == status;
                  return ChoiceChip(
                    label: Text(status.displayName),
                    selected: isSelected,
                    selectedColor: AppTheme.primary.withOpacity(0.2),
                    onSelected: (sel) {
                      setModalState(() => selectedStatus = status);
                    },
                  );
                }).toList(),
              ),
              if (selectedStatus == AttendanceStatus.ot) ...[
                const SizedBox(height: 16),
                Text('OT Hours', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: otController,
                  keyboardType: TextInputType.number,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: 'Enter overtime hours',
                    suffixText: 'hours',
                  ),
                  onChanged: (val) {
                    otHours = double.tryParse(val) ?? 0;
                  },
                ),
              ],
              const SizedBox(height: 16),
              Text('Wage Amount', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: wageController,
                keyboardType: TextInputType.number,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: 'Enter wage amount',
                  prefixText: '₹ ',
                  filled: true,
                  fillColor: Colors.white,
                ),
                onChanged: (val) {
                  wageAmount = double.tryParse(val);
                },
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    try {
                      await service.markAttendance(
                        workerId: record.workerId,
                        date: record.date,
                        status: selectedStatus,
                        otHours: otHours,
                        wageOverride: wageAmount,
                        markedBy: auth.username ?? 'Unknown',
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(children: [
                              const Icon(Icons.check_circle, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Text('Attendance saved for ${record.workerName}'),
                            ]),
                            backgroundColor: const Color(0xFF22C55E),
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(children: [
                              const Icon(Icons.error_outline, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Expanded(child: Text('Failed to save: $e')),
                            ]),
                            backgroundColor: AppTheme.danger,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        );
                      }
                    }
                  },
                  child: Text(wageAmount != null ? 'Save (₹${wageAmount!.toStringAsFixed(0)})' : 'Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyYesterdaysTeam() async {
    final service = Provider.of<AttendanceService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    
    final added = await service.copyPreviousDayWorkers(auth.username ?? 'Unknown');
    
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added $added workers from yesterday')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              if (_isFromCache)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: CachedDataChip(ageString: _cacheAge),
                ),
              _buildHeader(),
              Expanded(
                child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _loadData,
                      child: _buildContent(),
                    ),
              ),
            ],
          ),
        ),
      ),
      // Floating Set Wage button - only visible when workers selected
      floatingActionButton: _isSelectionMode
        ? FloatingActionButton.extended(
            onPressed: _showBulkWageDialog,
            icon: const Icon(Icons.payments_rounded),
            label: Text('Set Wage (${_selectedWorkerIds.length})'),
            backgroundColor: AppTheme.primary,
          )
        : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 44, height: 44,
                  decoration: AppTheme.machinedDecoration,
                  child: const Icon(Icons.arrow_back_rounded, color: AppTheme.primary, size: 22),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isToday ? 'ATTENDANCE' : 'ATTENDANCE (VIEW)',
                      style: GoogleFonts.manrope(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.primary,
                        letterSpacing: 2.5,
                      ),
                    ),
                    Text(
                      DateFormat('EEEE, MMM d').format(DateTime.tryParse(_selectedDate) ?? DateTime.now()),
                      style: TextStyle(color: AppTheme.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (_isToday) ...[
                GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/face_attendance'),
                  child: Container(
                    width: 44, height: 44,
                    decoration: AppTheme.machinedDecoration,
                    child: const Icon(Icons.face_rounded, color: AppTheme.primary, size: 22),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/attendance/calendar'),
                child: Container(
                  width: 44, height: 44,
                  decoration: AppTheme.machinedDecoration,
                  child: const Icon(Icons.calendar_month_rounded, color: AppTheme.primary, size: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSearchBar(),
          if (_showSearchResults) _buildSearchResults(),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.8),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: 'Add worker...',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _searchController.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _searchController.clear();
                  FocusScope.of(context).unfocus(); // Proper way to unfocus
                },
              )
            : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        onSubmitted: (val) {
          if (val.trim().isNotEmpty && _filteredWorkers.isEmpty) {
            _showNewWorkerDialog(val.trim());
          }
        },
      ),
    );
  }

  Widget _buildSearchResults() {
    final query = _searchController.text.trim();
    
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.floatingShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_filteredWorkers.isEmpty && query.isNotEmpty)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.success,
                child: const Icon(Icons.person_add, color: Colors.white, size: 18),
              ),
              title: Text('Add "$query" as new worker'),
              subtitle: const Text('Tap to create'),
              onTap: () => _showNewWorkerDialog(query),
            )
          else
            ..._filteredWorkers.map((w) => ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.titaniumMid,
                child: Text(w.name[0].toUpperCase(),
                  style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: AppTheme.primary)),
              ),
              title: Text(w.name),
              subtitle: Text(w.team),
              trailing: const Icon(Icons.add_circle_outline, color: AppTheme.success),
              onTap: () => _addWorkerToAttendance(w),
            )),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Consumer<AttendanceService>(
      builder: (ctx, service, _) {
        final summary = service.todaySummary;
        final markedWorkers = summary?.workers ?? [];
        final markedIds = markedWorkers.map((r) => r.workerId).toSet();
        final availableWorkers = service.workers.where((w) => !markedIds.contains(w.id)).toList();

        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSummaryCards(summary),
              const SizedBox(height: 20),
              _buildQuickActions(),
              const SizedBox(height: 20),
              _buildWorkersList(markedWorkers),
              if (availableWorkers.isNotEmpty) ...[
                const SizedBox(height: 24),
                _buildAvailableWorkers(availableWorkers),
              ],
              if (markedWorkers.isEmpty && availableWorkers.isEmpty)
                Container(
                  padding: const EdgeInsets.all(40),
                  child: Column(
                    children: [
                      Icon(Icons.person_add_alt_1_rounded, size: 64, color: AppTheme.titaniumDark),
                      const SizedBox(height: 16),
                      Text('No workers yet', style: GoogleFonts.outfit(
                        fontSize: 18, fontWeight: FontWeight.w600, color: AppTheme.muted)),
                      const SizedBox(height: 8),
                      Text('Search and add workers above',
                        style: TextStyle(color: AppTheme.muted)),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummaryCards(AttendanceSummary? summary) {
    return Row(
      children: [
        Expanded(child: _buildStatCard(
          'Workers',
          '${summary?.totalWorkers ?? 0}',
          Icons.people_alt_rounded,
          AppTheme.primary,
        )),
        const SizedBox(width: 12),
        Expanded(child: _buildStatCard(
          'Total Wages',
          '₹${(summary?.totalWages ?? 0).toStringAsFixed(0)}',
          Icons.currency_rupee_rounded,
          AppTheme.success,
        )),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.extrudedCardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: AppTheme.muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: GoogleFonts.outfit(
            fontSize: 24, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Column(
      children: [
        if (_isToday) ...[
          Row(
            children: [
              Expanded(
                child: _buildActionButton(
                  'Face Roll Call',
                  Icons.face_retouching_natural_rounded,
                  () => Navigator.pushNamed(context, '/face_attendance'),
                  accent: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildActionButton(
                  'Face Enroll',
                  Icons.app_registration_rounded,
                  () => Navigator.pushNamed(context, '/face_management'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Expanded(
              child: _buildActionButton(
                'Yesterday\'s Team',
                Icons.content_copy_rounded,
                _copyYesterdaysTeam,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActionButton(String label, IconData icon, VoidCallback onTap, {bool accent = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: accent ? AppTheme.primary : AppTheme.titaniumMid,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent ? AppTheme.primary : AppTheme.titaniumBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: accent ? Colors.white : AppTheme.primary, size: 18),
            const SizedBox(width: 8),
            Text(label, style: GoogleFonts.outfit(
              fontWeight: FontWeight.w600, color: accent ? Colors.white : AppTheme.primary)),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkersList(List<AttendanceRecord> workers) {
    if (workers.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('TODAY\'S WORKERS', style: GoogleFonts.manrope(
              fontSize: 12, fontWeight: FontWeight.w700, 
              color: AppTheme.muted, letterSpacing: 1)),
            if (_isSelectionMode)
              TextButton(
                onPressed: () => setState(() => _selectedWorkerIds.clear()),
                child: Text('Cancel', style: TextStyle(color: AppTheme.muted)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ...workers.map((record) => _buildWorkerCard(record)),
      ],
    );
  }

  Widget _buildAvailableWorkers(List<Worker> workers) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ALL WORKERS', style: GoogleFonts.manrope(
          fontSize: 12, fontWeight: FontWeight.w700,
          color: AppTheme.muted, letterSpacing: 1)),
        const SizedBox(height: 4),
        Text('Tap to mark attendance', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
        const SizedBox(height: 12),
        ...workers.map((worker) => _buildAvailableWorkerCard(worker)),
      ],
    );
  }

  Widget _buildAvailableWorkerCard(Worker worker) {
    return GestureDetector(
      onTap: () => _addWorkerToAttendance(worker),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.titaniumBorder, width: 1),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppTheme.titaniumMid,
              child: Text(
                worker.name.isNotEmpty ? worker.name[0].toUpperCase() : '?',
                style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(worker.name, style: GoogleFonts.outfit(
                    fontWeight: FontWeight.w600, fontSize: 15)),
                  if (worker.team.isNotEmpty)
                    Text(worker.team, style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                ],
              ),
            ),
            Icon(Icons.add_circle_outline, color: AppTheme.success, size: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkerCard(AttendanceRecord record) {
    Color statusColor;
    switch (record.status) {
      case AttendanceStatus.full:
        statusColor = AppTheme.success;
        break;
      case AttendanceStatus.halfAm:
      case AttendanceStatus.halfPm:
        statusColor = AppTheme.warning;
        break;
      case AttendanceStatus.ot:
        statusColor = AppTheme.secondary;
        break;
    }

    final isSelected = _selectedWorkerIds.contains(record.workerId);

    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          // Toggle selection
          setState(() {
            if (isSelected) {
              _selectedWorkerIds.remove(record.workerId);
            } else {
              _selectedWorkerIds.add(record.workerId);
            }
          });
        } else {
          _showStatusDialog(record);
        }
      },
      onLongPress: () {
        // Enter selection mode and select this card
        setState(() {
          _selectedWorkerIds.add(record.workerId);
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected 
            ? AppTheme.primary.withOpacity(0.1)
            : Colors.white.withOpacity(0.8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.titaniumBorder,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: statusColor.withOpacity(0.2),
              child: Text(
                record.workerName.isNotEmpty ? record.workerName[0].toUpperCase() : '?',
                style: TextStyle(color: statusColor, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(record.workerName, style: GoogleFonts.outfit(
                    fontWeight: FontWeight.w600, fontSize: 15)),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          record.status.displayName,
                          style: TextStyle(fontSize: 11, color: statusColor, fontWeight: FontWeight.w500),
                        ),
                      ),
                      if (record.otHours > 0) ...[
                        const SizedBox(width: 8),
                        Text('+${record.otHours}h OT', 
                          style: TextStyle(fontSize: 11, color: AppTheme.muted)),
                      ],
                    ],
                  ),
                  if (record.checkInTime != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.login, size: 12, color: Colors.green),
                        const SizedBox(width: 4),
                        Text(DateFormat.jm().format(record.checkInTime!.toLocal()), 
                          style: TextStyle(fontSize: 11, color: AppTheme.muted)),
                        if (record.checkOutTime != null) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.logout, size: 12, color: Colors.orange),
                          const SizedBox(width: 4),
                          Text(DateFormat.jm().format(record.checkOutTime!.toLocal()), 
                            style: TextStyle(fontSize: 11, color: AppTheme.muted)),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // Show checkbox in selection mode, else show wage
            if (_isSelectionMode)
              Checkbox(
                value: _selectedWorkerIds.contains(record.workerId),
                activeColor: AppTheme.primary,
                onChanged: (val) {
                  setState(() {
                    if (val == true) {
                      _selectedWorkerIds.add(record.workerId);
                    } else {
                      _selectedWorkerIds.remove(record.workerId);
                    }
                  });
                },
              )
            else ...[
              record.wageOverride != null && record.wageOverride! > 0
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '₹${record.wageOverride!.toStringAsFixed(0)}',
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: statusColor,
                        ),
                      ),
                      if (record.status == AttendanceStatus.ot && record.otHours > 0)
                        Text(
                          '(Base + OT ${record.otHours.toStringAsFixed(0)}h)',
                          style: TextStyle(fontSize: 10, color: const Color(0xFF94A3B8)),
                        )
                      else if (record.status == AttendanceStatus.halfAm || record.status == AttendanceStatus.halfPm)
                        Text(
                          '(Half day)',
                          style: TextStyle(fontSize: 10, color: const Color(0xFF94A3B8)),
                        ),
                    ],
                  )
                : Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('Set wage', style: TextStyle(
                      fontSize: 12, color: AppTheme.warning, fontWeight: FontWeight.w600)),
                  ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
            ],
          ],
        ),
      ),
    );
  }

  /// Show bulk wage dialog for selected workers
  Future<void> _showBulkWageDialog() async {
    String selectedType = 'full'; // full, halfAm, halfPm, ot
    final wageController = TextEditingController();
    
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.titaniumLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.group, color: AppTheme.primary),
                  const SizedBox(width: 12),
                  Text(
                    'Set Wage for ${_selectedWorkerIds.length} Worker${_selectedWorkerIds.length > 1 ? 's' : ''}',
                    style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const Divider(height: 24),
              Text('Attendance Type', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _buildTypeChip('Full Day', 'full', selectedType, (val) => setModalState(() => selectedType = val)),
                  _buildTypeChip('Half AM', 'halfAm', selectedType, (val) => setModalState(() => selectedType = val)),
                  _buildTypeChip('Half PM', 'halfPm', selectedType, (val) => setModalState(() => selectedType = val)),
                  _buildTypeChip('Extra Time', 'ot', selectedType, (val) => setModalState(() => selectedType = val)),
                ],
              ),
              const SizedBox(height: 16),
              Text('Wage Amount', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: wageController,
                keyboardType: TextInputType.number,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: 'Enter wage amount',
                  prefixText: '₹ ',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: AppTheme.titaniumBorder),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.success,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () async {
                    final wage = double.tryParse(wageController.text);
                    if (wage == null || wage <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a valid wage amount'), backgroundColor: Colors.orange),
                      );
                      return;
                    }
                    Navigator.pop(ctx);
                    await _applyBulkWage(selectedType, wage);
                  },
                  child: Text('Apply to ${_selectedWorkerIds.length} Worker${_selectedWorkerIds.length > 1 ? 's' : ''}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypeChip(String label, String value, String selected, Function(String) onSelect) {
    final isSelected = value == selected;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: AppTheme.primary.withOpacity(0.2),
      onSelected: (_) => onSelect(value),
    );
  }

  Future<void> _applyBulkWage(String type, double wage) async {
    final service = Provider.of<AttendanceService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    
    AttendanceStatus status;
    switch (type) {
      case 'halfAm':
        status = AttendanceStatus.halfAm;
        break;
      case 'halfPm':
        status = AttendanceStatus.halfPm;
        break;
      case 'ot':
        status = AttendanceStatus.ot;
        break;
      default:
        status = AttendanceStatus.full;
    }

    int successCount = 0;
    for (final workerId in _selectedWorkerIds) {
      final result = await service.markAttendance(
        workerId: workerId,
        date: _selectedDate,
        status: status,
        wageOverride: wage,
        markedBy: auth.username ?? 'Unknown',
      );
      if (result['success'] == true) successCount++;
    }

    // Reload and clear selection
    await service.loadSummary(_selectedDate);
    if (!mounted) return;
    setState(() => _selectedWorkerIds.clear());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Updated wage for $successCount worker${successCount > 1 ? 's' : ''}'),
          backgroundColor: AppTheme.success,
        ),
      );
    }
  }
}
