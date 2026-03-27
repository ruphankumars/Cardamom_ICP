import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/analytics_service.dart';
import '../mixins/pagination_mixin.dart';
import '../widgets/status_indicator.dart';

class AuditTrailScreen extends StatefulWidget {
  const AuditTrailScreen({super.key});

  @override
  State<AuditTrailScreen> createState() => _AuditTrailScreenState();
}

class _AuditTrailScreenState extends State<AuditTrailScreen>
    with PaginationMixin {
  final AnalyticsService _analyticsService = AnalyticsService();
  bool _isLoading = true;
  List<AuditLog> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    paginationInfo.reset();
    setState(() {
      _isLoading = true;
      _logs = [];
    });
    await loadNextPage();
  }

  @override
  Future<void> loadNextPage() async {
    try {
      final result = await _analyticsService.getAuditLogsPaginated(
        limit: paginationInfo.limit,
        cursor: paginationInfo.cursor,
      );
      if (mounted) {
        setState(() {
          _logs.addAll(result.logs);
          paginationInfo.cursor = result.cursor;
          paginationInfo.hasMore = result.hasMore;
          paginationInfo.isLoadingMore = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading audit logs: $e');
      if (mounted) {
        setState(() {
          paginationInfo.isLoadingMore = false;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadLogs,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
              ? const Center(child: Text('No audit logs found'))
              : NotificationListener<ScrollNotification>(
                  onNotification: onScrollNotification,
                  child: RefreshIndicator(
                    onRefresh: () => resetAndReload(),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _logs.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _logs.length) {
                          return buildPaginationFooter();
                        }
                        final log = _logs[index];
                        return _buildLogCard(log);
                      },
                    ),
                  ),
                ),
    );
  }

  Widget _buildLogCard(AuditLog log) {
    final Color color = _getActionColor(log.action);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      log.action,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    log.user,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              Text(
                log.timestamp,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            log.target,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 4),
          if (log.details.isNotEmpty)
            _buildDetails(log.details),
        ],
      ),
    );
  }

  Widget _buildDetails(Map<String, dynamic> details) {
    String summary = '';
    if (details.containsKey('grade')) {
      summary = '${details['grade']} - ${details['kgs']} kgs';
    } else if (details.containsKey('orderData')) {
      final data = details['orderData'] is Map ? details['orderData'] as Map<String, dynamic> : <String, dynamic>{};
      summary = '${data['grade']} - ${data['kgs']} kgs (Lot ${data['lot']})';
    } else {
      summary = details.toString();
    }

    return Text(
      summary,
      style: const TextStyle(
        fontSize: 12,
        color: Color(0xFF64748B),
      ),
    );
  }

  Color _getActionColor(String action) {
    switch (action) {
      case 'CREATE':
        return const Color(0xFF10B981);
      case 'UPDATE':
        return const Color(0xFF5D6E7E);
      case 'DELETE':
        return const Color(0xFFEF4444);
      case 'DISPATCH':
        return const Color(0xFF5D6E7E);
      default:
        return const Color(0xFF64748B);
    }
  }
}
