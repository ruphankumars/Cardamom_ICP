import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Report type definition
class ReportType {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> supportedFormats;

  const ReportType({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.supportedFormats,
  });
}

/// Main Reports screen with card-based grid of available report types.
/// Admin and ops users can generate, download, and share reports.
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  static const List<ReportType> reportTypes = [
    ReportType(
      id: 'invoice',
      title: 'Invoice',
      subtitle: 'Generate client invoices',
      icon: Icons.receipt_long,
      supportedFormats: ['pdf'],
    ),
    ReportType(
      id: 'dispatch-summary',
      title: 'Dispatch Summary',
      subtitle: 'Daily packing & dispatch',
      icon: Icons.local_shipping,
      supportedFormats: ['pdf'],
    ),
    ReportType(
      id: 'stock-position',
      title: 'Stock Position',
      subtitle: 'Current stock snapshot',
      icon: Icons.inventory,
      supportedFormats: ['pdf', 'excel'],
    ),
    ReportType(
      id: 'stock-movement',
      title: 'Stock Movement',
      subtitle: 'Purchases vs dispatches',
      icon: Icons.swap_vert,
      supportedFormats: ['excel'],
    ),
    ReportType(
      id: 'client-statement',
      title: 'Client Statement',
      subtitle: 'Order & balance history',
      icon: Icons.account_balance,
      supportedFormats: ['pdf'],
    ),
    ReportType(
      id: 'sales-summary',
      title: 'Sales Summary',
      subtitle: 'Revenue analytics',
      icon: Icons.bar_chart,
      supportedFormats: ['pdf', 'excel'],
    ),
    ReportType(
      id: 'attendance',
      title: 'Attendance',
      subtitle: 'Monthly worker attendance',
      icon: Icons.event_available,
      supportedFormats: ['excel'],
    ),
    ReportType(
      id: 'expenses',
      title: 'Expenses',
      subtitle: 'Daily/monthly expenses',
      icon: Icons.account_balance_wallet,
      supportedFormats: ['pdf', 'excel'],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.titaniumLight,
      appBar: AppBar(
        title: const Text('Reports'),
        backgroundColor: Colors.white,
        foregroundColor: AppTheme.title,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.steelBlue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.description, color: AppTheme.steelBlue, size: 24),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Generate Reports',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.title,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Download PDF or Excel reports for invoices, stock, sales, and more',
                            style: TextStyle(fontSize: 12, color: AppTheme.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Report cards grid
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.1,
                  ),
                  itemCount: reportTypes.length,
                  itemBuilder: (context, index) {
                    final report = reportTypes[index];
                    return _ReportCard(
                      report: report,
                      onTap: () {
                        Navigator.pushNamed(
                          context,
                          '/report_filter',
                          arguments: {'reportType': report},
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final ReportType report;
  final VoidCallback onTap;

  const _ReportCard({required this.report, required this.onTap});

  Color get _iconColor {
    switch (report.id) {
      case 'invoice':
        return const Color(0xFF2E7D32);
      case 'dispatch-summary':
        return AppTheme.steelBlue;
      case 'stock-position':
        return const Color(0xFF1565C0);
      case 'stock-movement':
        return const Color(0xFF6A1B9A);
      case 'client-statement':
        return const Color(0xFFE65100);
      case 'sales-summary':
        return const Color(0xFF00838F);
      case 'attendance':
        return const Color(0xFF4527A0);
      case 'expenses':
        return const Color(0xFFC62828);
      default:
        return AppTheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _iconColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(report.icon, color: _iconColor, size: 28),
            ),
            const SizedBox(height: 10),
            Text(
              report.title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.title,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              report.subtitle,
              style: const TextStyle(fontSize: 11, color: AppTheme.muted),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            // Format badges
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: report.supportedFormats.map((fmt) {
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: fmt == 'pdf'
                        ? const Color(0xFFEF4444).withOpacity(0.1)
                        : const Color(0xFF22C55E).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    fmt.toUpperCase(),
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: fmt == 'pdf'
                          ? const Color(0xFFEF4444)
                          : const Color(0xFF16A34A),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
