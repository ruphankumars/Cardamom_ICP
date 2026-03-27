/// Admin dashboard screen - thin orchestrator module.
///
/// Re-exports the AdminDashboard widget from the original monolith while
/// providing access to all extracted widget and controller modules.
///
/// As the refactoring progresses, this file will become the sole entry point
/// for the dashboard, with the monolith's internal methods migrated to use
/// the extracted widgets and controllers.
///
/// Usage in routes:
///   import 'screens/admin_dashboard/admin_dashboard_screen.dart';
///   '/admin_dashboard': (context) => const AdminDashboard(),
library admin_dashboard_screen;

// Re-export the main dashboard widget from the original location.
// This preserves backward compatibility while the barrel file
// provides access to all extracted sub-modules.
export '../admin_dashboard.dart' show AdminDashboard;
