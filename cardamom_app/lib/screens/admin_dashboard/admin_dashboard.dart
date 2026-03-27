/// Barrel file for the admin dashboard module.
///
/// Re-exports the main dashboard screen and all public widget/controller classes
/// for use elsewhere in the app.
library admin_dashboard;

// Main screen
export 'admin_dashboard_screen.dart';

// Widgets - Task 1: Painters
export 'widgets/mini_charts.dart';

// Widgets - Task 2: Hero, Header, NavBar
export 'widgets/titanium_hero_card.dart';
export 'widgets/frosted_header.dart';
export 'widgets/titanium_nav_bar.dart';

// Widgets - Task 3: Stats, Intelligence, Carousel, Ghost/Intent
export 'widgets/ghost_suggestion.dart';
export 'widgets/intent_prompt.dart';
export 'widgets/intelligence_card.dart';
export 'widgets/glass_carousel.dart';

// Widgets - Task 4: Evening Summary
export 'widgets/evening_summary_card.dart';

// Widgets - Task 5: Action Panels, Draggable Buttons, Task Panel
export 'widgets/precision_tools_grid.dart';
export 'widgets/draggable_action_arc.dart';
export 'widgets/draggable_cart_button.dart';
export 'widgets/user_task_panel.dart';
export 'widgets/offline_indicator.dart';

// Widgets - Task 6: Modal Dialogs
export 'widgets/daily_cart_modal.dart';
export 'widgets/available_stock_modal.dart';
export 'widgets/request_details_popup.dart';

// Controllers - Task 7
export 'controllers/dashboard_data_controller.dart';
export 'controllers/dashboard_animation_controller.dart';
