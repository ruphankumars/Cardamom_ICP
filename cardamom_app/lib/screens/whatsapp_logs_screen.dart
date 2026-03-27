import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

class WhatsappLogsScreen extends StatefulWidget {
  const WhatsappLogsScreen({super.key});

  @override
  State<WhatsappLogsScreen> createState() => _WhatsappLogsScreenState();
}

class _WhatsappLogsScreenState extends State<WhatsappLogsScreen> {
  final ApiService _api = ApiService();
  List<dynamic> _logs = [];
  bool _isLoading = true;
  String _channelFilter = 'all';
  String _statusFilter = 'all';

  // Stats
  int _totalSent = 0;
  int _totalFailed = 0;
  int _totalMessages = 0;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);
    try {
      final logs = await _api.getWhatsappLogs(
        channel: _channelFilter == 'all' ? null : _channelFilter,
        status: _statusFilter == 'all' ? null : _statusFilter,
        limit: 200,
      );
      // Calculate stats
      int sent = 0, failed = 0;
      for (final log in logs) {
        if (log is Map) {
          if (log['status'] == 'accepted') sent++;
          if (log['status'] == 'failed') failed++;
        }
      }
      setState(() {
        _logs = logs;
        _totalSent = sent;
        _totalFailed = failed;
        _totalMessages = logs.length;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load logs: $e'), backgroundColor: AppTheme.danger),
        );
      }
    }
  }

  String _formatPhone(String? phone) {
    if (phone == null || phone.isEmpty) return '-';
    if (phone.startsWith('91') && phone.length == 12) {
      return '+91 ${phone.substring(2, 7)} ${phone.substring(7)}';
    }
    return '+$phone';
  }

  String _formatTime(String? ts) {
    if (ts == null) return '-';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24 && dt.day == now.day) return 'Today, ${DateFormat('hh:mm a').format(dt)}';
      if (diff.inHours < 48) return 'Yesterday, ${DateFormat('hh:mm a').format(dt)}';
      return DateFormat('dd MMM, hh:mm a').format(dt);
    } catch (_) {
      return ts;
    }
  }

  String _channelLabel(String? channel) {
    if (channel == 'meta-sygt') return 'SYGT';
    if (channel == 'meta-espl') return 'ESPL';
    if (channel == 'meta') return 'Meta API';
    return channel ?? 'WhatsApp';
  }

  Color _channelColor(String? channel) {
    if (channel == 'meta-sygt') return const Color(0xFF25D366);
    if (channel == 'meta-espl') return const Color(0xFF128C7E);
    return const Color(0xFF25D366);
  }

  IconData _channelIcon(String? channel) {
    return Icons.message_rounded;
  }

  String _typeLabel(String? type) {
    if (type == null || type.isEmpty) return '';
    return type.replaceAll('_', ' ').split(' ').map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : w).join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      disableInternalScrolling: true,
      title: 'WhatsApp Send History',
      topActions: [
        GestureDetector(
          onTap: _loadLogs,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: AppTheme.machinedDecoration,
            child: Icon(Icons.refresh_rounded, size: 18, color: AppTheme.primary),
          ),
        ),
      ],
      content: Column(
        children: [
          // Stats cards
          _buildStatsRow(),
          // Filter chips
          _buildFilterBar(),
          // Logs list
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: AppTheme.primary))
                : _logs.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _loadLogs,
                        color: AppTheme.primary,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          itemCount: _logs.length,
                          itemBuilder: (ctx, i) => _buildLogCard(_logs[i]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Row(
        children: [
          _buildStatChip(Icons.message_rounded, '$_totalMessages', 'Total', AppTheme.primary),
          const SizedBox(width: 8),
          _buildStatChip(Icons.check_circle_rounded, '$_totalSent', 'Sent', AppTheme.success),
          const SizedBox(width: 8),
          _buildStatChip(Icons.error_rounded, '$_totalFailed', 'Failed', AppTheme.danger),
        ],
      ),
    );
  }

  Widget _buildStatChip(IconData icon, String count, String label, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.15)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 4),
            Text(count, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.title)),
            Text(label, style: TextStyle(fontSize: 10, color: AppTheme.muted, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          // Channel filter
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.titaniumLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.titaniumBorder.withOpacity(0.6)),
                boxShadow: [
                  const BoxShadow(color: Colors.white70, blurRadius: 1, offset: Offset(-1, -1)),
                  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 2, offset: const Offset(1, 1)),
                ],
              ),
              child: Row(
                children: [
                  _buildFilterChip('All', 'all', isChannel: true),
                  _buildFilterChip('SYGT', 'meta-sygt', isChannel: true),
                  _buildFilterChip('ESPL', 'meta-espl', isChannel: true),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Status filter
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.titaniumLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.titaniumBorder.withOpacity(0.6)),
                boxShadow: [
                  const BoxShadow(color: Colors.white70, blurRadius: 1, offset: Offset(-1, -1)),
                  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 2, offset: const Offset(1, 1)),
                ],
              ),
              child: Row(
                children: [
                  _buildFilterChip('All', 'all', isChannel: false),
                  _buildFilterChip('Sent', 'accepted', isChannel: false),
                  _buildFilterChip('Failed', 'failed', isChannel: false),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value, {required bool isChannel}) {
    final isSelected = isChannel ? _channelFilter == value : _statusFilter == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            if (isChannel) {
              _channelFilter = value;
            } else {
              _statusFilter = value;
            }
          });
          _loadLogs();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: isSelected
                ? [BoxShadow(color: AppTheme.primary.withOpacity(0.3), blurRadius: 4, offset: const Offset(0, 1))]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? Colors.white : AppTheme.muted,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppTheme.titaniumMid.withOpacity(0.5),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(Icons.message_outlined, size: 36, color: AppTheme.muted.withOpacity(0.4)),
          ),
          const SizedBox(height: 16),
          Text('No messages found', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppTheme.title)),
          const SizedBox(height: 6),
          Text(
            _channelFilter != 'all' || _statusFilter != 'all' ? 'Try adjusting your filters' : 'WhatsApp send logs will appear here',
            style: TextStyle(fontSize: 13, color: AppTheme.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildLogCard(dynamic log) {
    final map = log is Map ? Map<String, dynamic>.from(log) : <String, dynamic>{};
    final channel = map['channel'] as String? ?? '';
    final status = map['status'] as String? ?? '';
    final recipient = map['recipient'] as String? ?? '';
    final sender = map['sender'] as String? ?? '';
    final clientName = map['clientName'] as String? ?? '';
    final company = map['company'] as String? ?? '';
    final error = map['error'];
    final timestamp = map['timestamp'] as String?;
    final type = map['type'] as String? ?? '';
    final isSent = status == 'accepted';
    final channelCol = _channelColor(channel);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.titaniumLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isSent ? Colors.white.withOpacity(0.4) : AppTheme.danger.withOpacity(0.2),
          width: 0.5,
        ),
        boxShadow: [
          const BoxShadow(color: Colors.white, blurRadius: 3, offset: Offset(-1, -1)),
          BoxShadow(color: Colors.black.withOpacity(0.07), blurRadius: 6, offset: const Offset(2, 3)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: channel + status + time
            Row(
              children: [
                // Channel badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: channelCol.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: channelCol.withOpacity(0.2)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_channelIcon(channel), size: 13, color: channelCol),
                      const SizedBox(width: 5),
                      Text(
                        _channelLabel(channel),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: channelCol),
                      ),
                    ],
                  ),
                ),
                if (type.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.secondary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _typeLabel(type),
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.secondary, letterSpacing: -0.2),
                    ),
                  ),
                ],
                const Spacer(),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isSent
                          ? [AppTheme.success.withOpacity(0.12), AppTheme.success.withOpacity(0.06)]
                          : [AppTheme.danger.withOpacity(0.12), AppTheme.danger.withOpacity(0.06)],
                    ),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isSent ? AppTheme.success.withOpacity(0.2) : AppTheme.danger.withOpacity(0.2)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSent ? Icons.check_circle_rounded : Icons.cancel_rounded,
                        size: 12,
                        color: isSent ? AppTheme.success : AppTheme.danger,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isSent ? 'Sent' : 'Failed',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isSent ? AppTheme.success : AppTheme.danger,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Client name row
            if (clientName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.person_rounded, size: 16, color: AppTheme.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            clientName,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (company.isNotEmpty)
                            Text(company, style: TextStyle(fontSize: 11, color: AppTheme.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

            // Phone numbers row
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.35),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.call_made_rounded, size: 13, color: AppTheme.success),
                  const SizedBox(width: 4),
                  Text(_formatPhone(sender), style: TextStyle(fontSize: 12, color: AppTheme.title, fontWeight: FontWeight.w500)),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, size: 12, color: AppTheme.muted.withOpacity(0.4)),
                  const SizedBox(width: 4),
                  Icon(Icons.call_received_rounded, size: 13, color: AppTheme.secondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _formatPhone(recipient),
                      style: TextStyle(fontSize: 12, color: AppTheme.title, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

            // Error row
            if (!isSent && error != null && error.toString().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.danger.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.danger.withOpacity(0.1)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 14, color: AppTheme.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        error.toString(),
                        style: TextStyle(fontSize: 11, color: AppTheme.danger, height: 1.3),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Timestamp
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                _formatTime(timestamp),
                style: TextStyle(fontSize: 11, color: AppTheme.muted.withOpacity(0.7), fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
