import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/attendance_service.dart';
import '../services/api_service.dart';
import '../models/worker.dart';
import 'face_enroll_screen.dart';
import 'liveness_check_screen.dart';
import '../services/liveness_detection_service.dart';

/// Screen to manage worker face enrollment for face-scan attendance.
class WorkerFaceManagementScreen extends StatefulWidget {
  const WorkerFaceManagementScreen({super.key});

  @override
  State<WorkerFaceManagementScreen> createState() => _WorkerFaceManagementScreenState();
}

class _WorkerFaceManagementScreenState extends State<WorkerFaceManagementScreen> {
  List<Worker> _workers = [];
  bool _isLoading = true;
  String _filter = 'all'; // 'all', 'enrolled', 'not_enrolled'

  @override
  void initState() {
    super.initState();
    _loadWorkers();
  }

  Future<void> _loadWorkers() async {
    setState(() => _isLoading = true);
    try {
      final service = Provider.of<AttendanceService>(context, listen: false);
      await service.loadWorkers();
      if (!mounted) return;
      setState(() {
        _workers = List.from(service.workers);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load workers: $e')),
      );
    }
  }

  List<Worker> get _filteredWorkers {
    switch (_filter) {
      case 'enrolled':
        return _workers.where((w) => w.hasFaceEnrolled).toList();
      case 'not_enrolled':
        return _workers.where((w) => !w.hasFaceEnrolled).toList();
      default:
        return _workers;
    }
  }

  int get _enrolledCount => _workers.where((w) => w.hasFaceEnrolled).length;

  Future<void> _enrollWorker(Worker worker) async {
    // Face enrollment (modern sentient web network UI)
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => FaceEnrollScreen(enrollLabel: worker.name),
      ),
    );

    if (result == null || !mounted) return;

    final rawLandmarks = result['landmarks'];
    if (rawLandmarks == null) return;

    // Sanitize: remove NaN/Infinity values before sending to API
    final landmarks = Map<String, double>.from(rawLandmarks)
      ..removeWhere((_, v) => v.isNaN || v.isInfinite);
    if (landmarks.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Face capture failed. No valid landmarks extracted.'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    try {
      final api = ApiService();
      final response = await api.storeFaceData(worker.id, landmarks);
      if (!mounted) return;
      final data = response.data;

      if (data is Map && data['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Face enrolled for ${worker.name} (liveness verified)'),
            backgroundColor: AppTheme.success,
          ),
        );
        _loadWorkers(); // Refresh to show updated status
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Enrollment failed: ${data is Map ? data['error'] ?? 'Unknown error' : 'Unknown error'}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<void> _confirmDeleteFace(Worker worker) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Face Data', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text(
          'Delete face data for ${worker.name}? They\'ll need to be re-enrolled for face attendance.',
          style: GoogleFonts.manrope(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.manrope(color: AppTheme.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: GoogleFonts.manrope(color: Colors.redAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await ApiService().deleteWorkerFaceData(worker.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Face data deleted for ${worker.name}'),
          backgroundColor: AppTheme.success,
        ),
      );
      _loadWorkers();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildFilterBar(),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: _loadWorkers,
                        child: _buildWorkerList(),
                      ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pushNamed(context, '/face_attendance'),
        icon: const Icon(Icons.face_retouching_natural),
        label: const Text('Roll Call'),
        backgroundColor: AppTheme.primary,
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
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
                  'FACE ENROLLMENT',
                  style: GoogleFonts.manrope(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.primary,
                    letterSpacing: 2.5,
                  ),
                ),
                Text(
                  '$_enrolledCount / ${_workers.length} workers enrolled',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _buildFilterChip('All', 'all'),
          const SizedBox(width: 8),
          _buildFilterChip('Enrolled', 'enrolled'),
          const SizedBox(width: 8),
          _buildFilterChip('Not Enrolled', 'not_enrolled'),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isSelected = _filter == value;
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() => _filter = value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primary : Colors.white.withOpacity(0.6),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.titaniumBorder,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.manrope(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: isSelected ? Colors.white : AppTheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildWorkerList() {
    final workers = _filteredWorkers;
    if (workers.isEmpty) {
      return Center(
        child: Text(
          _filter == 'enrolled' ? 'No workers enrolled yet' : 'No workers found',
          style: TextStyle(color: AppTheme.muted, fontSize: 14),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: workers.length,
      itemBuilder: (context, index) => _buildWorkerTile(workers[index]),
    );
  }

  Widget _buildWorkerTile(Worker worker) {
    final enrolled = worker.hasFaceEnrolled;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.titaniumBorder),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: enrolled ? AppTheme.success.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            enrolled ? Icons.face_rounded : Icons.face_outlined,
            color: enrolled ? AppTheme.success : Colors.grey,
            size: 24,
          ),
        ),
        title: Text(
          worker.name,
          style: GoogleFonts.manrope(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: AppTheme.title,
          ),
        ),
        subtitle: Text(
          enrolled ? 'Face enrolled - Liveness verified' : 'Not enrolled',
          style: TextStyle(
            color: enrolled ? AppTheme.success : AppTheme.muted,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (enrolled)
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _confirmDeleteFace(worker);
                },
                child: Container(
                  width: 36, height: 36,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                ),
              ),
            GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                _enrollWorker(worker);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: enrolled ? AppTheme.primary.withOpacity(0.1) : AppTheme.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  enrolled ? 'Re-enroll' : 'Enroll',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: enrolled ? AppTheme.primary : Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
