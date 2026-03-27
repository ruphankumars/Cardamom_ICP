import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/navigation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import 'new_order_screen.dart';
import 'dart:async';
import 'dart:convert';

final List<String> _premiumBrands = [
  'Aladdin\'s',
  'Emperor',
  'Yoga',
  'Local Pouch',
  'No Brand',
  'Green Cardamom',
  'Royal Spec',
];

// Helper widget for focus-aware input with box shadow matching CSS
class _FocusAwareContainer extends StatefulWidget {
  final FocusNode focusNode;
  final Widget child;

  const _FocusAwareContainer({
    required this.focusNode,
    required this.child,
  });

  @override
  State<_FocusAwareContainer> createState() => _FocusAwareContainerState();
}

class _FocusAwareContainerState extends State<_FocusAwareContainer> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        // matches panelChat.css: .draft-qty:focus box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.1) - Line 798
        boxShadow: widget.focusNode.hasFocus
            ? [
                BoxShadow(
                  color: const Color(0xFF5D6E7E).withOpacity(0.1),
                  blurRadius: 0,
                  spreadRadius: 2,
                  offset: Offset.zero, // matches CSS: 0 0 (first two values)
                ),
              ]
            : null,
      ),
      child: widget.child,
    );
  }
}

// iMessage-style smooth curved tail painter using quadratic bezier curves
// Replaces old triangular tails with smooth flowing connector from bubble corner
class _MessageTailPainter extends CustomPainter {
  final Color color;
  final bool isRight; // true for sent (right), false for received (left)
  final double shadowOpacity;
  final Color? borderColor;

  _MessageTailPainter({
    required this.color,
    required this.isRight,
    this.shadowOpacity = 0.1,
    this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();

    if (isRight) {
      // Sent (right) tail: smooth curve flowing from top-left down and curving right
      path.moveTo(0, 0); // start at top-left (connects to bubble bottom-right corner)
      path.lineTo(0, size.height * 0.45); // go down along the bubble edge
      path.quadraticBezierTo(
        0, size.height,               // control point: bottom-left
        size.width * 0.85, size.height, // end point: bottom-right (tail tip)
      );
      path.quadraticBezierTo(
        size.width * 0.4, size.height * 0.7, // control point: curves back
        0, 0,                                  // end point: back to start
      );
      path.close();
    } else {
      // Received (left) tail: mirrored smooth curve
      path.moveTo(size.width, 0); // start at top-right (connects to bubble bottom-left corner)
      path.lineTo(size.width, size.height * 0.45); // go down along bubble edge
      path.quadraticBezierTo(
        size.width, size.height,       // control point: bottom-right
        size.width * 0.15, size.height, // end point: bottom-left (tail tip)
      );
      path.quadraticBezierTo(
        size.width * 0.6, size.height * 0.7, // control point: curves back
        size.width, 0,                          // end point: back to start
      );
      path.close();
    }

    // Draw subtle shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(shadowOpacity * 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path.shift(const Offset(0, 1)), shadowPaint);

    // Draw the tail fill
    canvas.drawPath(path, paint);

    // Draw border if provided (for received messages with border)
    if (borderColor != null) {
      final borderPaint = Paint()
        ..color = borderColor!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawPath(path, borderPaint);
    }
  }

  @override
  bool shouldRepaint(_MessageTailPainter oldDelegate) {
    return oldDelegate.color != color ||
           oldDelegate.isRight != isRight ||
           oldDelegate.shadowOpacity != shadowOpacity ||
           oldDelegate.borderColor != borderColor;
  }
}

class NegotiationScreen extends StatefulWidget {
  final String requestId;
  const NegotiationScreen({super.key, required this.requestId});

  @override
  State<NegotiationScreen> createState() => _NegotiationScreenState();
}

class _NegotiationScreenState extends State<NegotiationScreen> with TickerProviderStateMixin, RouteAware {
  // Core properties matching PanelChat.js structure
  final ApiService _apiService = ApiService();
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _draftNoteController = TextEditingController(); // matches PanelChat.js: draft-note
  final ScrollController _scrollController = ScrollController();
  
  // State matching PanelChat.js
  bool _isLoading = true;
  List<dynamic> _messages = []; // matches: this.messages = []
  Map<String, dynamic>? _requestMeta; // matches: this.requestMeta
  String? _previousStatus; // matches: this.previousStatus
  List<dynamic>? _currentDraftItems; // matches: this.currentDraftItems (renamed from _draftItems)
  String? _initialDraftState; // matches: this.initialDraftState (for dirty check)
  
  // Dropdowns and brands matching PanelChat.js
  Map<String, dynamic> _dropdowns = {'grades': [], 'brands': []}; // matches: this.dropdowns
  List<String> _brands = []; // matches: this.brands
  
  // Polling
  Timer? _pollTimer; // matches: this.pollInterval
  bool _isPolling = false; // Guard against overlapping poll calls
  bool _initComplete = false; // Prevent timer from firing before init finishes
  
  // Auto-draft tracking matching PanelChat.js
  bool _autoDraftInFlight = false; // matches: this._autoDraftInFlight
  
  // Draft editing state (Flutter-specific helpers)
  String? _validationError;
  Set<int> _selectedEnquiryIndices = {};
  DateTime? _lastFetchTime;
  dynamic _lastMessageTimestamp;
  
  // Rendering optimization (matches PanelChat.js pattern)
  String? _lastInputSignature; // matches: this._lastInputSignature
  String? _lastRenderSignature; // matches: this._lastRenderSignature
  
  // Scroll position preservation (Task 12)
  double? _savedScrollPosition;
  bool _wasScrolledToBottom = true;
  
  // Auto-open draft editor (Task 14)
  bool _hasAutoOpenedDraft = false;
  String? _lastDraftStatus;

  // Persistent controllers for draft item inputs (prevents cursor jump on rebuild)
  final Map<String, TextEditingController> _draftControllers = {};

  // BUG 25 fix: Managed FocusNode map to prevent leaks in build methods
  final Map<String, FocusNode> _draftFocusNodes = {};

  // Stream 1B: Acceptance timeout countdown
  Timer? _countdownTimer;
  Duration _timeRemaining = Duration.zero;
  bool _isAcceptanceExpired = false;

  // Stream 1B: Admin 2hr reminder animation
  AnimationController? _bellAnimController;
  Animation<double>? _bellScaleAnim;
  AnimationController? _glowAnimController;
  Animation<double>? _glowOpacityAnim;

  @override
  void initState() {
    super.initState();

    // Stream 1B: Bell pulse animation for 2hr reminder (scale 1.0 -> 1.3)
    _bellAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _bellScaleAnim = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _bellAnimController!, curve: Curves.easeInOut),
    );

    // Stream 1B: Glowing border animation (opacity 0.2 -> 0.6)
    _glowAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _glowOpacityAnim = Tween<double>(begin: 0.2, end: 0.6).animate(
      CurvedAnimation(parent: _glowAnimController!, curve: Curves.easeInOut),
    );

    _init(); // matches PanelChat.js: this.init()
  }

  @override
  /// Get or create a persistent TextEditingController for a draft item field.
  /// Prevents cursor jump issues caused by recreating controllers on every rebuild.
  TextEditingController _getDraftController(int index, String type, String value) {
    final key = '${index}_$type';
    final existing = _draftControllers[key];
    if (existing != null) {
      // BUG 26 fix: Only update text if changed externally AND field not focused
      if (existing.text != value && !existing.selection.isValid && !(existing.selection.baseOffset >= 0 && existing.selection.extentOffset >= 0)) {
        existing.text = value;
      }
      return existing;
    }
    final controller = TextEditingController(text: value);
    _draftControllers[key] = controller;
    return controller;
  }

  /// BUG 25 fix: Get or create a managed FocusNode for a draft field
  FocusNode _getDraftFocusNode(String key) {
    return _draftFocusNodes.putIfAbsent(key, () => FocusNode());
  }

  /// Clear all draft controllers (call when draft items change/reload)
  void _clearDraftControllers() {
    for (final c in _draftControllers.values) {
      c.dispose();
    }
    _draftControllers.clear();
    // BUG 25: Also dispose and clear managed FocusNodes
    for (final f in _draftFocusNodes.values) {
      f.dispose();
    }
    _draftFocusNodes.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    _bellAnimController?.dispose();
    _glowAnimController?.dispose();
    _messageController.dispose();
    _draftNoteController.dispose();
    _scrollController.dispose();
    _clearDraftControllers();
    super.dispose();
  }

  @override
  void didPopNext() => _loadMessages();

  // matches PanelChat.js: async init()
  Future<void> _init() async {
    setState(() => _isLoading = true); // matches: this.renderLoading()
    try {
      // Fetch request metadata first, as it's used by other parts like render()
      // matches PanelChat.js: const metaResponse = await this.api.getRequest(this.requestId);
      final metaResponse = await _apiService.getRequest(widget.requestId);
      if (!mounted) return;
      if (metaResponse.data['success'] == true || metaResponse.statusCode == 200) {
        setState(() {
          _requestMeta = metaResponse.data['request'];
        });
      } else {
        throw Exception(metaResponse.data['error']?.toString() ?? 'Failed to load request metadata');
      }

      // Load dropdowns for editing grades and Brand options
      // matches PanelChat.js: const dropdowns = await window.api.getDropdownOptions();
      try {
        final dropdownResponse = await _apiService.getDropdownOptions();
        if (!mounted) return;
        if (dropdownResponse.data != null) {
          final dropdowns = dropdownResponse.data;
          setState(() {
            _dropdowns = Map<String, dynamic>.from(dropdowns);
            // Support both 'brand' (singular, backend) and 'brands' (plural, some frontend parts)
            final brandArr = dropdowns['brands'] ?? dropdowns['brand'] ?? [];
            _brands = (brandArr as List? ?? [])
                .map((b) => (b ?? '').toString().trim())
                .where((b) => b.isNotEmpty)
                .toList()
                .cast<String>();
          });
        }
      } catch (e) {
        debugPrint('[PanelChat] Failed to load dropdown options: $e');
        if (!mounted) return;
        setState(() {
          _brands = [];
        });
      }

      // Load messages and render
      // matches PanelChat.js: await this.loadMessages();
      await _loadMessages();

      if (!mounted) return;
      // matches PanelChat.js: this.render(); // Initial render after loading messages
      setState(() {
        _isLoading = false;
      });
      
      // Mark init complete before starting polling
      _initComplete = true;
      // matches PanelChat.js: this.startPolling(); // Poll for updates (5s to avoid flooding)
      _startPolling(5000);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _validationError = err.toString(); // matches: this.renderError(err.message)
      });
      debugPrint('Init error: $err');
    }
  }

  // Sequential polling: each poll starts only AFTER the previous one completes.
  // This prevents overlapping calls entirely (Timer.periodic can't do this).
  void _startPolling([int interval = 5000]) {
    _pollTimer?.cancel();
    _schedulePoll(interval);
  }

  void _schedulePoll(int interval) {
    _pollTimer?.cancel();
    _pollTimer = Timer(Duration(milliseconds: interval), () async {
      if (!mounted || !_initComplete) return;
      await _loadMessages();
      if (mounted) _schedulePoll(interval); // Schedule next poll only after completion
    });
  }

  // Helper to get user role (matches PanelChat.js: this.userRole)
  String? _getUserRole() {
    try {
      return context.read<AuthProvider>().role?.toLowerCase();
    } catch (e) {
      return null;
    }
  }

  // matches PanelChat.js: async loadMessages()
  Future<void> _loadMessages() async {
    if (!mounted) return;
    if (_isPolling) {
      debugPrint('[NegotiationScreen] _loadMessages SKIPPED (already polling)');
      return;
    }
    _isPolling = true;
    debugPrint('[NegotiationScreen] _loadMessages START');
    try {
      final prevStatus = _requestMeta?['status'];

      // Fetch request metadata for header status
      final metaResponse = await _apiService.getRequest(widget.requestId);
      if (!mounted) return;
      if (metaResponse.data['success'] == true || metaResponse.statusCode == 200) {
        final newMeta = metaResponse.data['request'];
        // Only setState if meta actually changed
        if (_requestMeta == null || newMeta['status'] != _requestMeta?['status'] ||
            newMeta['panelVersion'] != _requestMeta?['panelVersion'] ||
            newMeta['updatedAt'] != _requestMeta?['updatedAt']) {
          setState(() {
            _requestMeta = newMeta;
          });
        } else {
          _requestMeta = newMeta; // Silent update without rebuild
        }
      }

      // Stream 1B: Update acceptance countdown whenever metadata refreshes
      _updateAcceptanceCountdown();

      // Reset draft when moving out of an edit state
      if (prevStatus != null && _requestMeta != null && _requestMeta!['status'] != prevStatus &&
          !['ADMIN_DRAFT', 'CLIENT_DRAFT'].contains(_requestMeta!['status'])) {
        if (!mounted) return;
        setState(() {
          _currentDraftItems = null;
          _clearDraftControllers();
        });
      }

      // Auto-pull admin into draft mode (only once, not recursively)
      if (!_autoDraftInFlight) {
        final userRole = _getUserRole();
        if ((userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') &&
            _requestMeta != null) {
          final status = _requestMeta!['status'];
          if (status == 'OPEN' || status == 'CLIENT_SENT') {
            _autoDraftInFlight = true;
            try {
              await _apiService.adminStartDraft(widget.requestId);
              if (!mounted) return;
            } catch (err) {
              debugPrint('Auto draft start failed: $err');
            } finally {
              if (mounted) _autoDraftInFlight = false;
            }
            // Re-fetch meta after draft start (inline, no recursion)
            final refreshMeta = await _apiService.getRequest(widget.requestId);
            if (!mounted) return;
            if (refreshMeta.data['success'] == true || refreshMeta.statusCode == 200) {
              setState(() { _requestMeta = refreshMeta.data['request']; });
            }
          }
        }
      }

      // Fetch messages
      final chatResponse = await _apiService.getRequestChat(widget.requestId);
      if (!mounted) return;
      if (chatResponse.data['success'] == true || chatResponse.statusCode == 200) {
        final newMessages = (chatResponse.data['messages'] as List?) ?? [];

        // Only re-render if messages actually changed
        final shouldRender = newMessages.length != _messages.length ||
            (newMessages.isNotEmpty && _messages.isNotEmpty &&
             newMessages.last['messageId'] != _messages.last['messageId']);

        if (shouldRender) {
          setState(() {
            _messages = newMessages;
          });
          _scrollToBottom();
        }
      }

      if (!mounted) return;
      final newStatus = _requestMeta?['status'];
      if (_previousStatus != newStatus) {
        setState(() {
          _previousStatus = newStatus;
        });
      }
    } catch (err) {
      debugPrint('[NegotiationScreen] _loadMessages ERROR: $err');
    } finally {
      debugPrint('[NegotiationScreen] _loadMessages END');
      _isPolling = false;
    }
  }

  // Legacy _fetchUpdates removed — all callers now use _loadMessages()

  // Manual trigger for admin to start draft (from UI button)
  Future<void> _maybeAutoStartAdminDraft() async {
    if (_autoDraftInFlight || _requestMeta == null) return;
    final status = _requestMeta!['status'];
    if (status != 'OPEN' && status != 'CLIENT_SENT') return;
    _autoDraftInFlight = true;
    try {
      await _apiService.adminStartDraft(widget.requestId);
      if (!mounted) return;
      // Fetch updated meta and messages inline (don't call _loadMessages to avoid re-entry)
      final metaResp = await _apiService.getRequest(widget.requestId);
      if (!mounted) return;
      if (metaResp.data['success'] == true) {
        setState(() { _requestMeta = metaResp.data['request']; });
      }
      final chatResp = await _apiService.getRequestChat(widget.requestId);
      if (!mounted) return;
      if (chatResp.data['success'] == true) {
        final msgs = (chatResp.data['messages'] as List?) ?? [];
        if (msgs.length != _messages.length) {
          setState(() { _messages = msgs; });
          _scrollToBottom();
        }
      }
    } catch (err) {
      debugPrint('Manual draft start failed: $err');
    } finally {
      if (mounted) _autoDraftInFlight = false;
    }
  }

  // Initializes draft items from request metadata.
  // 
  // Data Source Priority:
  // 1. currentItems (from latest panel or draft state)
  // 2. requestedItems (fallback to original request)
  // 
  // Special Logic for Admin v1 Offers:
  // - For admin's first offer (panelVersion == 1), auto-fills offered quantities
  //   with requested quantities if not already set
  // - This matches PanelChat.js behavior where admin's initial offer
  //   defaults to matching the client's request
  // 
  // State Management:
  // - Creates deep copy of items to avoid mutation issues
  // - Stores initial state as JSON for dirty checking
  void _initDraftItems() {
    final items = _requestMeta?['currentItems'] ?? _requestMeta?['requestedItems'] ?? [];
    final role = _getUserRole();
    final panelVersion = _requestMeta?['panelVersion'] ?? 0;

    setState(() {
      _currentDraftItems = items.map((i) {
        final item = Map<String, dynamic>.from(i);

        // Admin v1 Auto-Fill Logic: If first offer, offered = requested
        // This provides a sensible default for admin's initial offer
        if ((role == 'admin' || role == 'ops' || role == 'superadmin') && panelVersion == 1) {
          if (item['offeredKgs'] == null || item['offeredKgs'] == 0) {
            item['offeredKgs'] = item['requestedKgs'] ?? 0;
          }
          if (item['offeredNo'] == null || item['offeredNo'] == 0) {
            item['offeredNo'] = item['requestedNo'] ?? 0;
          }
        }
        return item;
      }).toList();

      // BUG 30 fix: Removed dead orderDate sort - draft items don't have orderDate field

      // Store initial state for dirty checking (detects unsaved changes)
      _initialDraftState = jsonEncode(_currentDraftItems);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Stream 1B: Start/update the 1-hour acceptance countdown timer
  void _updateAcceptanceCountdown() {
    final status = _requestMeta?['status']?.toString();
    if (status != 'ADMIN_SENT') {
      _countdownTimer?.cancel();
      if (mounted) {
        setState(() {
          _isAcceptanceExpired = false;
          _timeRemaining = Duration.zero;
        });
      }
      return;
    }

    final lastPanelSentAt = _requestMeta?['lastPanelSentAt'];
    if (lastPanelSentAt == null) return;

    DateTime sentTime;
    if (lastPanelSentAt is Map && lastPanelSentAt['_seconds'] != null) {
      sentTime = DateTime.fromMillisecondsSinceEpoch(
        (lastPanelSentAt['_seconds'] as int) * 1000,
      );
    } else {
      sentTime = DateTime.tryParse(lastPanelSentAt.toString()) ?? DateTime.now();
    }

    final expiresAt = sentTime.add(const Duration(hours: 1));

    void tick() {
      if (!mounted) {
        _countdownTimer?.cancel();
        return;
      }
      final now = DateTime.now();
      final remaining = expiresAt.difference(now);
      setState(() {
        if (remaining.isNegative) {
          _isAcceptanceExpired = true;
          _timeRemaining = Duration.zero;
          _countdownTimer?.cancel();
        } else {
          _isAcceptanceExpired = false;
          _timeRemaining = remaining;
        }
      });
    }

    tick(); // immediate first tick
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  // Stream 1B: Check if request has been pending > 2 hours (admin reminder)
  bool _isAdminReminderNeeded() {
    if (_requestMeta == null) return false;
    final status = _requestMeta!['status']?.toString();
    if (status != 'ADMIN_DRAFT' && status != 'ADMIN_SENT') return false;

    final updatedAt = _requestMeta!['updatedAt'] ?? _requestMeta!['lastPanelSentAt'] ?? _requestMeta!['createdAt'];
    if (updatedAt == null) return false;

    DateTime refTime;
    if (updatedAt is Map && updatedAt['_seconds'] != null) {
      refTime = DateTime.fromMillisecondsSinceEpoch((updatedAt['_seconds'] as int) * 1000);
    } else {
      refTime = DateTime.tryParse(updatedAt.toString()) ?? DateTime.now();
    }

    return DateTime.now().difference(refTime).inHours >= 2;
  }

  // Stream 1B: Reinitiate negotiation when acceptance expired
  Future<void> _reinitiateNegotiation() async {
    setState(() => _isLoading = true);
    try {
      await _apiService.reinitiateNegotiation(widget.requestId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Negotiation reinitiated. Client can respond again.')),
      );
      await _loadMessages();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to reinitiate: ${e.toString()}')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;
    final text = _messageController.text.trim();
    _messageController.clear();
    
    try {
      await _apiService.sendNegotiationMessage(widget.requestId, text);
      if (!mounted) return;
      await _loadMessages();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to send: $e')));
    }
  }

  // matches PanelChat.js: async saveDraft()
  // 
  // Saves the current draft items to the server without sending them.
  // This allows users to preserve their work-in-progress edits.
  // 
  // Key behaviors:
  // - Role-based API call (admin/ops vs client)
  // - Updates _initialDraftState to track dirty state
  // - Does NOT send the panel, only saves for later
  // - Used by auto-save or manual save functionality
  Future<void> _saveDraft() async {
    if (_currentDraftItems == null || _currentDraftItems!.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final role = _getUserRole();
      final panelSnapshot = {
        'items': _currentDraftItems,
      };

      if (role == 'admin' || role == 'ops' || role == 'superadmin') {
        await _apiService.adminSaveDraft(widget.requestId, panelSnapshot);
      } else {
        await _apiService.clientSaveDraft(widget.requestId, panelSnapshot);
      }
      if (!mounted) return;

      // Update initial state to mark draft as saved (dirty check will pass)
      setState(() {
        _initialDraftState = jsonEncode(_currentDraftItems);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Draft saved successfully')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // ============================================================================
  // TASK 6: ACTION METHODS (PART 2) - Matching PanelChat.js
  // ============================================================================
  // matches PanelChat.js: async toggleDecline(index) - Lines 1217-1256

  Future<void> _toggleDecline(int index) async {
    // This is a DESTRUCTIVE action.
    // matches PanelChat.js: if (confirm('Are you sure you want to remove this item? This cannot be undone.'))
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Item?'),
        content: const Text('Are you sure you want to remove this item? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('Yes, Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final userRole = _getUserRole()?.toUpperCase() ?? 'ADMIN';
      final response = await _apiService.cancelRequestItem(
        widget.requestId,
        index,
        userRole,
        'Admin cancelled item',
      );

      if (!mounted) return;
      if (response.data['success'] == true && response.data['currentItems'] != null) {
        setState(() {
          _currentDraftItems = (response.data['currentItems'] as List)
              .map((i) => Map<String, dynamic>.from(i))
              .toList();
          _initialDraftState = jsonEncode(_currentDraftItems);
        });
        await _loadMessages();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to cancel item: ${response.data['error'] ?? 'Unknown error'}'),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error cancelling item: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error cancelling item: ${e.toString()}')),
      );
    }
  }

  void _updateDraftItem(int index, String type, String value) {
    if (_currentDraftItems == null) return;
    final item = _currentDraftItems![index];
    final role = context.read<AuthProvider>().role?.toLowerCase();
    final panelVersion = _requestMeta?['panelVersion'] ?? 1;

    // BUG 13 fix: Admin can edit Quantity/Packaging in Round 1 only (panelVersion <= 1)
    // In Round 2+, admin already approved qty in Round 1, so only price editing allowed
    // Client cannot edit these fields
    bool isQuantityEditable = (role == 'admin' || role == 'ops' || role == 'superadmin') && panelVersion <= 1;
    
    // Security: Both can edit price, but Client has <= Admin constraint (checked on submit)
    bool isPriceEditable = true;
    if (role == 'admin' || role == 'ops' || role == 'superadmin') {
        // Admin can only edit Price in Round 2+ (v3+)
        // Everything is editable in Round 1 (v1)
    }

    // Security: Client can only edit Price, Brand, Notes
    if (role == 'client') {
        if (['kgs', 'no', 'bagbox'].contains(type)) return;
    }

    setState(() {
      // matches PanelChat.js: updateDraftItem() - Lines 1137-1192
      final multiplier = _getBagboxMultiplier(item['bagbox']?.toString());

      if (type == 'kgs' && isQuantityEditable) {
        // matches PanelChat.js: type === 'qty' - Lines 1142-1156
        final val = double.tryParse(value) ?? 0.0;
        item['offeredKgs'] = val;

        // Sync Bags from Qty
        if (multiplier != null && val > 0) {
          final calcNo = val / multiplier;
          item['offeredNo'] = double.parse(calcNo.toStringAsFixed(2));
          // Update the synced bags controller
          final bagsKey = '${index}_no';
          _draftControllers[bagsKey]?.text = item['offeredNo'].toStringAsFixed(0);
        }
      } else if (type == 'no' && isQuantityEditable) {
        // matches PanelChat.js: type === 'bags' - Lines 1157-1169
        final val = double.tryParse(value) ?? 0.0;
        item['offeredNo'] = val;

        // Sync Qty from Bags
        if (multiplier != null) {
          item['offeredKgs'] = double.parse((val * multiplier).toStringAsFixed(2));
          // Update the synced kgs controller
          final kgsKey = '${index}_kgs';
          _draftControllers[kgsKey]?.text = item['offeredKgs'].toStringAsFixed(0);
        }
      } else if (type == 'price' && isPriceEditable) {
        // matches PanelChat.js: type === 'price' - Line 1170
        item['unitPrice'] = double.tryParse(value) ?? 0.0;
      } else if (type == 'grade') {
        // matches PanelChat.js: type === 'grade' - Line 1171
        item['grade'] = value;
      } else if (type == 'brand') {
        // matches PanelChat.js: type === 'brand' - Line 1172
        item['brand'] = value;
      } else if (type == 'notes') {
        // matches PanelChat.js: type === 'notes' - Lines 1173-1176
        if (role == 'client') {
          item['clientNote'] = value;
        } else {
          item['adminNote'] = value;
        }
      } else if (type == 'bagbox' && isQuantityEditable) {
        // matches PanelChat.js: type === 'bagbox' - Lines 1177-1188
        item['bagbox'] = value;
        // Re-sync Qty from Bags since multiplier changed
        final newMult = _getBagboxMultiplier(value);
        if (newMult != null && (item['offeredNo'] ?? 0) > 0) {
          item['offeredKgs'] = double.parse(((item['offeredNo'] ?? 0) * newMult).toStringAsFixed(2));
        }
      }

      // Auto-Check Dirty State to disable Confirm button
      // matches PanelChat.js: this.checkDirtyState() - Line 1191
      _checkDirtyState();
    });
  }

  double _getDraftTotal() {
    if (_currentDraftItems == null) return 0;
    return _currentDraftItems!.fold(0.0, (sum, item) => sum + (double.tryParse(item['offeredKgs'].toString()) ?? 0.0));
  }

  double _getDraftPriceTotal() {
    if (_currentDraftItems == null) return 0;
    return _currentDraftItems!.fold(0.0, (sum, item) => sum + ((double.tryParse(item['offeredKgs'].toString()) ?? 0.0) * (double.tryParse(item['unitPrice'].toString()) ?? 0.0)));
  }

  Future<bool> _showParityConfirmation(String title, String content) async {
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('CONFIRM'),
          ),
        ],
      ),
    ) ?? false;
  }

  // matches PanelChat.js: checkDirtyState() - Lines 1194-1215
  void _checkDirtyState() {
    if (_initialDraftState == null || _currentDraftItems == null) return;

    // In Flutter, we track dirty state for UI updates
    // The Confirm button will be disabled if dirty (handled in draft editor)
    // Dirty state is tracked via _isDraftDirty() method
    setState(() {
      // Trigger rebuild to update UI based on dirty state
    });
  }

  // Helper to check if draft is dirty
  bool _isDraftDirty() {
    if (_initialDraftState == null || _currentDraftItems == null) return false;
    return jsonEncode(_currentDraftItems) != _initialDraftState;
  }

  void _onBargain(Map<String, dynamic> panel) {
    setState(() {
      _currentDraftItems = (panel['items'] as List).map((i) => Map<String, dynamic>.from(i)).toList();
      _initialDraftState = jsonEncode(_currentDraftItems);
    });
    _scrollToBottom();
  }

  void _onConfirm(Map<String, dynamic> panel) {
    final role = context.read<AuthProvider>().role?.toLowerCase();
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Offer?'),
        content: Text(_isDraftDirty() 
          ? 'You have modified the offer draft. Please click "SEND UPDATED OFFER" instead of confirming the old one.' 
          : 'Do you want to accept this offer and proceed to final order creation?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (!_isDraftDirty())
            ElevatedButton(
              onPressed: () {
              Navigator.pop(ctx);
              if (role == 'admin' || role == 'ops' || role == 'superadmin') {
                Navigator.pushNamed(context, '/new_order', arguments: {
                  'client': _requestMeta?['clientName'],
                  'requestId': widget.requestId,
                  'items': panel['items'],
                });
              } else {
                _clientConfirm();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
            child: const Text('Yes, Confirm'),
          ),
        ],
      ),
    );
  }

  Future<void> _clientConfirm() async {
    setState(() => _isLoading = true);
    try {
      await _apiService.confirmRequest(widget.requestId);
      if (!mounted) return;
      await _loadMessages();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // matches PanelChat.js: render()
  @override
  Widget build(BuildContext context) {
    if (_isLoading && _requestMeta == null) {
      // matches PanelChat.js: this.renderLoading()
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_requestMeta == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final userRole = _getUserRole();
    
    // matches PanelChat.js structure:
    // 1. Header
    // 2. Messages Container  
    // 3. Input / Action Area
    
    return AppShell(
      disableInternalScrolling: true,
      title: userRole == 'client' 
          ? 'Negotiation with Admin'  // matches PanelChat.js: 'Negotiation with Admin'
          : 'Negotiation: ${_requestMeta!['clientName']}',  // matches: `Negotiation: ${this.requestMeta.clientName}`
      subtitle: _requestMeta!['status'].toString().replaceAll('_', ' '), // Status badge will be in header
      content: Column(
          children: [
            // 1. Header with status badge (matches PanelChat.js header structure)
            _buildHeader(userRole),
            // 2. Messages Container (matches PanelChat.js: this.messagesContainer)
            Expanded(
              child: _buildMessagesContainer(),
            ),
            // 3. Input / Action Area (matches PanelChat.js: this.renderInputArea())
            _buildInputArea(),
          ],
      ),
    );
  }

  // matches PanelChat.js: Header structure
  Widget _buildHeader(String? userRole) {
    final status = _requestMeta!['status']?.toString() ?? 'OPEN';
    final bool showReminder = _isAdminReminderNeeded() && (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.1))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        userRole == 'client'
                            ? 'Negotiation with Admin'
                            : 'Negotiation: ${_requestMeta!['clientName']}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.title,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Stream 1B: Blipping bell icon for 2hr admin reminder
                    // Stream 1B: Blipping bell icon for 2hr admin reminder
                    if (showReminder)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: ScaleTransition(
                          scale: _bellScaleAnim!,
                          child: const Icon(
                            Icons.notifications_active_rounded,
                            color: Color(0xFFF97316),
                            size: 22,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Status badge (matches PanelChat.js: status-badge)
              _buildStatusBadge(status),
            ],
          ),
          // Stream 1B: Countdown timer for ADMIN_SENT status
          if (status == 'ADMIN_SENT') ...[
            const SizedBox(height: 8),
            _buildAcceptanceTimer(userRole),
          ],
        ],
      ),
    );
  }

  // Stream 1B: Build the acceptance countdown timer widget
  Widget _buildAcceptanceTimer(String? userRole) {
    if (_isAcceptanceExpired) {
      // Expired state
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444).withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.2)),
        ),
        child: Row(
          children: [
            const Icon(Icons.timer_off_rounded, size: 16, color: Color(0xFFEF4444)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Acceptance window has expired',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFEF4444)),
              ),
            ),
            if (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin')
              InkWell(
                onTap: _reinitiateNegotiation,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Reinitiate',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // Active countdown
    final minutes = _timeRemaining.inMinutes;
    final seconds = _timeRemaining.inSeconds % 60;
    final timeStr = '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    final isLow = _timeRemaining.inMinutes < 10;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (isLow ? const Color(0xFFF97316) : const Color(0xFF3B82F6)).withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (isLow ? const Color(0xFFF97316) : const Color(0xFF3B82F6)).withOpacity(0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_rounded, size: 14, color: isLow ? const Color(0xFFF97316) : const Color(0xFF3B82F6)),
          const SizedBox(width: 6),
          Text(
            'Acceptance window: $timeStr remaining',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isLow ? const Color(0xFFF97316) : const Color(0xFF3B82F6),
            ),
          ),
        ],
      ),
    );
  }

  // Stream 1B: Animated glow wrapper for 2hr admin reminder on panel cards
  Widget _buildGlowWrapper({
    required bool showGlow,
    required BorderRadius borderRadius,
    required Widget child,
  }) {
    if (!showGlow) return child;

    return AnimatedBuilder(
      animation: _glowOpacityAnim!,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFF97316).withOpacity(_glowOpacityAnim!.value),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }

  // ============================================================================
  // TASK 10: CSS STYLING PARITY - Status Badge
  // ============================================================================
  // matches panelChat.css: .status-badge - Lines 53-105

  Widget _buildStatusBadge(String status) {
    Color badgeColor;
    Color textColor;
    Color borderColor;
    
    switch (status.toUpperCase()) {
      case 'OPEN':
        // matches panelChat.css: .status-badge.OPEN - Lines 65-69
        badgeColor = const Color(0xFF5D6E7E); // rgba(59, 130, 246, 0.15)
        textColor = const Color(0xFF2563EB);
        borderColor = const Color(0xFF5D6E7E).withOpacity(0.3);
        break;
      case 'ADMIN_DRAFT':
        badgeColor = AppTheme.statusAdminDraft;
        textColor = AppTheme.statusAdminDraft;
        borderColor = AppTheme.statusAdminDraft.withOpacity(0.3);
        break;
      case 'ADMIN_SENT':
        // matches panelChat.css: .status-badge.ADMIN_SENT - Lines 71-75
        badgeColor = const Color(0xFFF97316); // rgba(249, 115, 22, 0.15)
        textColor = const Color(0xFFC2410C);
        borderColor = const Color(0xFFF97316).withOpacity(0.3);
        break;
      case 'CLIENT_DRAFT':
        // matches panelChat.css: .status-badge.CLIENT_DRAFT - Lines 77-81
        badgeColor = const Color(0xFFEAB308); // rgba(234, 179, 8, 0.15)
        textColor = const Color(0xFFA16207);
        borderColor = const Color(0xFFEAB308).withOpacity(0.3);
        break;
      case 'CLIENT_SENT':
        // matches panelChat.css: .status-badge.CLIENT_SENT - Lines 83-87
        badgeColor = const Color(0xFFA855F7); // rgba(168, 85, 247, 0.15)
        textColor = const Color(0xFF7E22CE);
        borderColor = const Color(0xFFA855F7).withOpacity(0.3);
        break;
      case 'CONFIRMED':
        // matches panelChat.css: .status-badge.CONFIRMED - Lines 89-93
        badgeColor = const Color(0xFF22C55E); // rgba(34, 197, 94, 0.15)
        textColor = const Color(0xFF15803D);
        borderColor = const Color(0xFF22C55E).withOpacity(0.3);
        break;
      case 'CANCELLED':
        // matches panelChat.css: .status-badge.CANCELLED - Lines 95-99
        badgeColor = const Color(0xFFEF4444); // rgba(239, 68, 68, 0.15)
        textColor = const Color(0xFFB91C1C);
        borderColor = const Color(0xFFEF4444).withOpacity(0.3);
        break;
      case 'CONVERTED_TO_ORDER':
      case 'CONVERTED':
        // matches panelChat.css: .status-badge.CONVERTED_TO_ORDER - Lines 101-105
        badgeColor = const Color(0xFF6B7280); // rgba(107, 114, 128, 0.15)
        textColor = const Color(0xFF374151);
        borderColor = const Color(0xFF6B7280).withOpacity(0.3);
        break;
      default:
        badgeColor = const Color(0xFF5D6E7E);
        textColor = const Color(0xFF2563EB);
        borderColor = const Color(0xFF5D6E7E).withOpacity(0.3);
    }
    
    return Container(
      // matches panelChat.css: padding: 3px 10px, border-radius: 999px - Lines 56-57
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        // matches panelChat.css: background: rgba(59, 130, 246, 0.15) - Line 66
        color: badgeColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
        // matches panelChat.css: border: 1px solid rgba(59, 130, 246, 0.3) - Line 68
        border: Border.all(color: borderColor, width: 1),
        // matches panelChat.css: box-shadow: 0 2px 6px rgba(0, 0, 0, 0.06) - Line 62
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        status.replaceAll('_', ' ').toUpperCase(),
        style: TextStyle(
          color: textColor,
          // matches panelChat.css: font-size: 11px, font-weight: 600, text-transform: uppercase - Lines 58-60
          fontWeight: FontWeight.w600,
          fontSize: 11,
          letterSpacing: 0.05,
        ),
      ),
    );
  }

  // matches PanelChat.js: messages-container
  Widget _buildMessagesContainer() {
    return _renderMessages(_messages, _requestMeta!);
  }

  // matches PanelChat.js: chat-input-area  
  Widget _buildInputArea() {
    return _renderInputArea(_requestMeta!);
  }

  Widget _renderInputArea(Map<String, dynamic> requestMeta) {
    final userRole = _getUserRole() ?? '';
    final status = requestMeta['status']?.toString() ?? 'OPEN';
    
    final isAdminEditTurn = (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') && (status == 'ADMIN_DRAFT');
    final isClientEditTurn = (userRole == 'client') && (status == 'CLIENT_DRAFT');

    // If it's my turn to edit the draft, show the draft editor (which now handles its own layout)
    if (isAdminEditTurn || isClientEditTurn) {
      return _renderDraftEditor(requestMeta);
    }

    // Otherwise show the chat bar + any state-specific action buttons (Confirm, Counter, etc.)
    return _buildChatBar(requestMeta);
  }

  Widget _buildChatBar(Map<String, dynamic> requestMeta) {
    final userRole = _getUserRole();
    final status = requestMeta['status']?.toString() ?? 'OPEN';
    
    // Determine if we should show "action buttons" above the chat bar
    // e.g. "START COUNTER", "CONFIRM", etc.
    final List<Widget> actionButtons = [];
    
    if (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') {
      if (status == 'OPEN' || status == 'CLIENT_SENT') {
        actionButtons.add(_buildActionChip('START OFFER', Icons.edit_note_rounded, () => _maybeAutoStartAdminDraft()));
      }
    } else if (userRole == 'client') {
      if (status == 'ADMIN_SENT') {
        // Stream 1B: Disable client actions when acceptance window expired
        if (_isAcceptanceExpired) {
          actionButtons.add(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withOpacity(0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.2)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.timer_off_rounded, size: 14, color: Color(0xFFEF4444)),
                  SizedBox(width: 6),
                  Text('Acceptance window expired', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFEF4444))),
                ],
              ),
            ),
          );
        } else {
          actionButtons.add(_buildActionChip('COUNTER OFFER', Icons.edit_note_rounded, () => _startBargain()));
          actionButtons.add(const SizedBox(width: 8));
          actionButtons.add(_buildActionChip('CONFIRM OFFER', Icons.check_circle_outline_rounded, () => _onConfirm(_getLatestPanelItems().isNotEmpty ? {'items': _getLatestPanelItems()} : {})));
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: const Color(0xFFE2E8F0))),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -4)),
        ],
      ),
      padding: const EdgeInsets.only(bottom: 24, top: 12, left: 16, right: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (actionButtons.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: actionButtons,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: InputBorder.none,
                      hintStyle: TextStyle(color: Color(0xFF94A3B8)),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Material(
                color: const Color(0xFF1E293B),
                shape: const CircleBorder(),
                elevation: 4,
                shadowColor: const Color(0xFF1E293B).withOpacity(0.4),
                child: InkWell(
                  onTap: _sendMessage,
                  customBorder: const CircleBorder(),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.send_rounded, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _getStatusInfoText(status, userRole),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF94A3B8), letterSpacing: 0.5),
          ),
        ],
      ),
    );
  }

  Widget _buildActionChip(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF3B82F6).withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: const Color(0xFF3B82F6)),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF3B82F6), letterSpacing: 0.5)),
          ],
        ),
      ),
    );
  }

  String _getStatusInfoText(String status, String? userRole) {
    switch (status) {
      case 'OPEN':
      case 'CLIENT_SENT':
        return userRole == 'client' ? 'WAITING FOR ADMIN RESPONSE' : 'WAITING FOR YOUR OFFER';
      case 'ADMIN_SENT':
        return userRole == 'client' ? 'YOUR TURN TO RESPOND' : 'WAITING FOR CLIENT RESPONSE';
      case 'ADMIN_DRAFT':
        return 'ADMIN IS DRAFTING OFFER';
      case 'CLIENT_DRAFT':
        return 'CLIENT IS DRAFTING COUNTER';
      case 'CONFIRMED':
        return 'NEGOTIATION COMPLETED';
      default:
        return 'STATUS: ${status.replaceAll('_', ' ')}';
    }
  }

  // ============================================================================
  // TASK 4: DRAFT EDITOR (Matching PanelChat.js)
  // ============================================================================
  // matches PanelChat.js: renderDraftEditor() - Lines 745-869

  Widget _renderDraftEditor(Map<String, dynamic> requestMeta) {
    final userRole = _getUserRole();
    
    // Initialize draft items if not active
    // matches PanelChat.js: Lines 758-803
    if (_currentDraftItems == null) {
      final isMyDraft = (userRole == 'admin' && requestMeta['status'] == 'ADMIN_DRAFT') ||
          (userRole == 'client' && requestMeta['status'] == 'CLIENT_DRAFT');

      if (isMyDraft && requestMeta['currentItems'] != null && 
          (requestMeta['currentItems'] as List).isNotEmpty) {
        // Priority 1: Resume Saved Draft
        _currentDraftItems = (requestMeta['currentItems'] as List)
            .map((i) => Map<String, dynamic>.from(i))
            .toList();
      } else {
        // Priority 2: Initialize from latest message or Fallback
        List<dynamic> sourceItems = _getLatestPanelItems();
        if (sourceItems.isEmpty) {
          sourceItems = (requestMeta['currentItems'] as List?) ?? [];
        }

        if (sourceItems.isNotEmpty) {
          _currentDraftItems = sourceItems.map((i) => Map<String, dynamic>.from(i)).toList();
        } else {
          _currentDraftItems = [];
        }
      }

      // AUTO-POPULATE FIX (Applied to ALL sources)
      // matches PanelChat.js: Lines 780-799
      if (_currentDraftItems!.isNotEmpty && 
          userRole == 'admin' && 
          (requestMeta['panelVersion'] == 1 || requestMeta['panelVersion'] == '1')) {
        _currentDraftItems = _currentDraftItems!.map((item) {
          if ((item['offeredKgs'] == 0 || item['offeredKgs'] == null) &&
              (item['offeredNo'] == 0 || item['offeredNo'] == null)) {
            return {
              ...item,
              'offeredKgs': item['requestedKgs'] ?? 0,
              'offeredNo': item['requestedNo'] ?? 0,
              'unitPrice': item['unitPrice'] ?? 0,
              'status': item['status'] ?? 'OFFERED',
            };
          }
          return item;
        }).toList();
      }

      // Set Initial State for Dirty Check
      _initialDraftState = jsonEncode(_currentDraftItems);
    }

    // Allow admin to edit quantity/packaging fields in ALL rounds (not just Round 1)
    // User requested fix: Admin should be able to edit fields even in Round 2+
    final isAdminEditing = userRole == 'admin' || userRole == 'ops';
    // Keep this for backwards compatibility with some UI elements
    final isAdminInitialOffer = isAdminEditing && 
        (requestMeta['panelVersion'] == 1 || requestMeta['panelVersion'] == '1' || requestMeta['panelVersion'] == null);
    final iterationsLocked = _hasReachedIterationCap();

    // ============================================================================
    // TASK 10: CSS STYLING PARITY - Draft Editor Container
    // ============================================================================
    // matches panelChat.css: draft editor container styling
    // Container: White background, border-radius 15px, shadow 0 4px 15px rgba(0,0,0,0.15)
    
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        
        return Container(
          width: double.infinity,
          margin: EdgeInsets.all(isMobile ? 8 : 12),
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3B82F6).withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.edit_note_rounded, size: 20, color: Color(0xFF3B82F6)),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        userRole == 'client' ? 'COUNTER-OFFER' : 'OFFER DRAFT',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF1E293B),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  if (iterationsLocked && userRole == 'client')
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'FINAL ROUND',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFFEF4444)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Stream 1B: Info banner for client counter-offers (rate-only restriction)
              if (userRole == 'client' && !isAdminInitialOffer)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF3B82F6)),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'You can only modify the rate in counter-offers. Other fields are locked.',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF3B82F6)),
                        ),
                      ),
                    ],
                  ),
                ),

              // Items List/Table
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: isMobile ? 400 : 300),
                child: _renderDraftItemsTable(isAdminEditing, userRole, isMobile),
              ),
              
              const SizedBox(height: 16),
              
              // Note & Actions
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withOpacity(0.03),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: _draftNoteController,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      decoration: const InputDecoration(
                        hintText: 'Add a summary note...',
                        hintStyle: TextStyle(color: Color(0xFF94A3B8)),
                        border: InputBorder.none,
                        isDense: true,
                        prefixIcon: Icon(Icons.notes_rounded, size: 18, color: Color(0xFF94A3B8)),
                      ),
                      maxLines: 2,
                    ),
                    const Divider(height: 20, color: Color(0xFFE2E8F0)),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => _cancelRequest(),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEF4444).withOpacity(0.08),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.2)),
                              ),
                              child: const Center(
                                child: Text('CANCEL REQ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFEF4444), letterSpacing: 0.5)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: InkWell(
                            onTap: () => _validateAndSend(),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(color: const Color(0xFF1E293B).withOpacity(0.2), blurRadius: 8, offset: const Offset(0, 4)),
                                ],
                              ),
                              child: Center(
                                child: Text(
                                  userRole == 'client' ? 'SEND COUNTER' : 'SEND OFFER',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 0.5),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              
              if (_validationError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, size: 16, color: Color(0xFFEF4444)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_validationError!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFEF4444))),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // matches PanelChat.js: renderDraftItems(tbody) - Lines 871-952
  Widget _renderDraftItemsTable(bool isAdminEditing, String? userRole, bool isMobile) {
    if (_currentDraftItems == null || _currentDraftItems!.isEmpty) {
      return const Center(child: Text('No items to edit', style: TextStyle(color: Color(0xFF94A3B8))));
    }

    if (isMobile) {
      return ListView.builder(
        shrinkWrap: true,
        itemCount: _currentDraftItems!.length,
        itemBuilder: (context, index) {
          final item = _currentDraftItems![index];
          final isDeclined = item['status']?.toString() == 'DECLINED';
          final isClient = userRole == 'client';
          final offeredNo = (item['offeredNo'] ?? item['requestedNo'] ?? 0).toDouble();
          final offeredKgs = (item['offeredKgs'] ?? item['requestedKgs'] ?? 0).toDouble();
          
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDeclined ? const Color(0xFFF1F5F9) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDeclined ? Colors.transparent : const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item['grade']?.toString() ?? '-', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: isDeclined ? const Color(0xFF94A3B8) : const Color(0xFF1E293B))),
                          Text(item['type']?.toString() ?? 'N/A', style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    if ((userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') && _currentDraftItems!.length > 1)
                      IconButton(
                        icon: Icon(isDeclined ? Icons.restore_rounded : Icons.delete_outline_rounded, color: isDeclined ? const Color(0xFF3B82F6) : const Color(0xFFEF4444), size: 18),
                        onPressed: () => _toggleDecline(index),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    // Admin can edit quantity fields in ALL rounds
                    if (isAdminEditing) ...[
                      Expanded(child: _buildBagBoxDropdown(index, item['bagbox']?.toString() ?? 'Bag')),
                      const SizedBox(width: 8),
                      Expanded(child: _buildNumberInput(index, 'no', offeredNo.toStringAsFixed(0), label: 'Bags')),
                      const SizedBox(width: 8),
                      Expanded(child: _buildNumberInput(index, 'kgs', offeredKgs.toStringAsFixed(0), label: 'Kgs')),
                    ] else ...[
                      // Client sees read-only quantity fields
                      Expanded(
                        child: _StatBox(label: 'PKGING', value: item['bagbox']?.toString() ?? '-', isDeclined: isDeclined),
                      ),
                      Expanded(
                        child: _StatBox(label: 'BAGS', value: offeredNo.toStringAsFixed(0), isDeclined: isDeclined),
                      ),
                      Expanded(
                        child: _StatBox(label: 'KGS', value: offeredKgs.toStringAsFixed(0), isDeclined: isDeclined),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _buildNumberInput(index, 'price', (item['unitPrice'] ?? 0).toStringAsFixed(0), label: 'Price (₹)')),
                    const SizedBox(width: 8),
                    // Admin can edit brand; client sees read-only
                    Expanded(
                      child: isAdminEditing
                          ? _buildBrandInput(index, item['brand']?.toString() ?? '')
                          : _StatBox(label: 'BRAND', value: item['brand']?.toString() ?? '-', isDeclined: isDeclined),
                    ),
                  ],
                ),
                // Stream 1B: Notes read-only for client counter-offers; show existing notes
                if (isClient && (item['clientNote'] ?? item['adminNote'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _StatBox(label: 'NOTES', value: (item['clientNote'] ?? item['adminNote'] ?? '').toString(), isDeclined: isDeclined),
                ],
              ],
            ),
          );
        },
      );
    }

    // Tablet/Web Desktop view - keep table but style it
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: const {
          0: FixedColumnWidth(120), // Grade
          1: FixedColumnWidth(80),  // Bag/Box
          2: FixedColumnWidth(60),  // No.
          3: FixedColumnWidth(60),  // Kgs
          4: FixedColumnWidth(80),  // Price
          5: FixedColumnWidth(100), // Brand
          6: FixedColumnWidth(150), // Notes
          7: FixedColumnWidth(40),  // Actions
        },
        children: [
          TableRow(
            decoration: BoxDecoration(color: const Color(0xFF1E293B).withOpacity(0.04)),
            children: const [
              _TableHeaderCell('Grade'), _TableHeaderCell('Pkg'), _TableHeaderCell('No'), 
              _TableHeaderCell('Kgs'), _TableHeaderCell('Price'), _TableHeaderCell('Brand'), 
              _TableHeaderCell('Notes'), _TableHeaderCell(''),
            ],
          ),
          ..._currentDraftItems!.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            final isDeclined = item['status']?.toString() == 'DECLINED';
            final isClient = userRole == 'client';
            
            return TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item['grade']?.toString() ?? '-', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, decoration: isDeclined ? TextDecoration.lineThrough : null)),
                      Text(item['type']?.toString() ?? '', style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(4.0),
                  // Admin can edit bag/box in all rounds; client sees read-only
                  child: isAdminEditing 
                      ? _buildBagBoxDropdown(index, item['bagbox']?.toString() ?? 'Bag') 
                      : Text(item['bagbox']?.toString() ?? '-'),
                ),
                // Admin can edit no/kgs in all rounds
                isAdminEditing 
                    ? _buildNumberInput(index, 'no', (item['offeredNo'] ?? item['requestedNo'] ?? 0).toStringAsFixed(0))
                    : Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text((item['offeredNo'] ?? item['requestedNo'] ?? 0).toStringAsFixed(0)),
                      ),
                isAdminEditing
                    ? _buildNumberInput(index, 'kgs', (item['offeredKgs'] ?? item['requestedKgs'] ?? 0).toStringAsFixed(0))
                    : Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text((item['offeredKgs'] ?? item['requestedKgs'] ?? 0).toStringAsFixed(0)),
                      ),
                _buildNumberInput(index, 'price', (item['unitPrice'] ?? 0).toStringAsFixed(0)),
                // Admin can edit brand; client sees read-only
                isAdminEditing
                    ? Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: SizedBox(
                          width: 100,
                          child: DropdownButton<String>(
                            value: _brands.contains(item['brand']?.toString()) 
                                ? item['brand']?.toString() 
                                : null,
                            isExpanded: true,
                            isDense: true,
                            hint: Text(item['brand']?.toString() ?? 'Select', style: const TextStyle(fontSize: 12)),
                            style: const TextStyle(fontSize: 12, color: Colors.black),
                            items: _brands.map((brand) => DropdownMenuItem(
                              value: brand,
                              child: Text(brand, style: const TextStyle(fontSize: 11)),
                            )).toList(),
                            onChanged: (val) {
                              if (val != null) _updateDraftItem(index, 'brand', val);
                            },
                          ),
                        ),
                      )
                    : Text(item['brand']?.toString() ?? '-'),
                Text((isClient ? (item['clientNote'] ?? item['adminNote'] ?? '') : (item['adminNote'] ?? '')).toString()),
                (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') && _currentDraftItems!.length > 1
                  ? IconButton(icon: Icon(isDeclined ? Icons.restore : Icons.close, color: isDeclined ? Colors.blue : Colors.red, size: 16), onPressed: () => _toggleDecline(index))
                  : const SizedBox.shrink(),
              ],
            );
          }),
        ],
      ),
    );
  }

  // Helper widgets for the redesign
  Widget _StatBox({required String label, required String value, required bool isDeclined}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withOpacity(0.02),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFF94A3B8), letterSpacing: 0.5)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isDeclined ? const Color(0xFF94A3B8) : const Color(0xFF1E293B))),
        ],
      ),
    );
  }
  
  // Helper widget for focus-aware input with box shadow
  Widget _buildFocusAwareInput({
    required Widget child,
    required FocusNode focusNode,
  }) {
    return _FocusAwareContainer(
      focusNode: focusNode,
      child: child,
    );
  }

  // Helper widgets for draft editor inputs
  // matches panelChat.css: .draft-qty, .draft-bags, .draft-price - Lines 778-799
  Widget _buildNumberInput(int index, String type, String value, {double? width, String? label}) {
    final controller = _getDraftController(index, type, value);
    final focusNode = _getDraftFocusNode('${index}_$type');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 2),
            child: Text(label, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFF94A3B8), letterSpacing: 0.5)),
          ),
        _buildFocusAwareInput(
          focusNode: focusNode,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: Color(0xFF1E293B),
            ),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              fillColor: Colors.white,
              filled: true,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
              ),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (val) => _updateDraftItem(index, type, val),
          ),
        ),
      ],
    );
  }

  Widget _buildBagBoxDropdown(int index, String currentValue) {
    final focusNode = _getDraftFocusNode('${index}_bagbox');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 4, left: 2),
          child: Text('PKGING', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFF94A3B8), letterSpacing: 0.5)),
        ),
        _buildFocusAwareInput(
          focusNode: focusNode,
          child: DropdownButtonFormField<String>(
            value: currentValue,
            focusNode: focusNode,
            isDense: true,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              fillColor: Colors.white,
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
              ),
            ),
            items: const [
              DropdownMenuItem(value: 'Bag', child: Text('Bag', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900))),
              DropdownMenuItem(value: 'Box', child: Text('Box', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900))),
            ],
            onChanged: (val) {
              if (val != null) {
                _updateDraftItem(index, 'bagbox', val);
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBrandInput(int index, String currentValue) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 4, left: 2),
          child: Text('BRAND', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFF94A3B8), letterSpacing: 0.5)),
        ),
        Autocomplete<String>(
          initialValue: TextEditingValue(text: currentValue),
          optionsBuilder: (textEditingValue) {
            if (textEditingValue.text.isEmpty) return _brands;
            return _brands.where((brand) => brand.toLowerCase().contains(textEditingValue.text.toLowerCase()));
          },
          onSelected: (value) => _updateDraftItem(index, 'brand', value),
          fieldViewBuilder: (context, controller, focusNode, onEditingComplete) {
            // Don't reset controller.text here - initialValue handles it
            return _buildFocusAwareInput(
              focusNode: focusNode,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onEditingComplete: onEditingComplete,
                onChanged: (val) => _updateDraftItem(index, 'brand', val),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF1E293B)),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  fillColor: Colors.white,
                  filled: true,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildNotesInput(int index, String currentValue) {
    final controller = _getDraftController(index, 'notes', currentValue);
    final focusNode = _getDraftFocusNode('${index}_notes');
    return _buildFocusAwareInput(
      focusNode: focusNode,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: (val) => _updateDraftItem(index, 'notes', val),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
        decoration: InputDecoration(
          hintText: 'Add private note for this item...',
          hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          fillColor: const Color(0xFF1E293B).withOpacity(0.04),
          filled: true,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          prefixIcon: const Icon(Icons.sticky_note_2_outlined, size: 16, color: Color(0xFF94A3B8)),
        ),
      ),
    );
  }

  Widget _buildDraftActionButton({
    required String label,
    required String icon,
    required VoidCallback onPressed,
    bool isPrimary = false,
    bool isSecondary = false,
    bool isDanger = false,
  }) {
    // Use the same button widget as panel action buttons for consistency
    // matches panelChat.css: .panel-action-btn - Lines 576-626
    return _ButtonWithHover(
      label: label,
      icon: icon,
      onPressed: onPressed,
      isPrimary: isPrimary,
      isSecondary: isSecondary,
      isDanger: isDanger,
      isDisabled: false,
    );
  }

  // matches PanelChat.js: validateAndSend() - Lines 954-1043
  // 
  // Comprehensive validation before sending a panel offer.
  // 
  // Validation Rules:
  // 1. Iteration Cap: Client cannot bargain after 4 panels
  // 2. Quantity Constraints: Admin cannot exceed requested quantities
  // 3. Bag/Box Multiplier: Quantities must be multiples of 50kg (bag) or 20kg (box)
  // 4. Price Constraint: Client cannot increase price above admin's last offer
  // 5. Required Fields: All items must have valid quantities > 0
  // 
  // Deviations from PanelChat.js:
  // - Uses Flutter's setState for error display instead of DOM manipulation
  // - Error messages are collected and displayed as a single block
  Future<void> _validateAndSend() async {
    setState(() {
      _validationError = null;
    });

    final userRole = _getUserRole();
    final iterationsLocked = _hasReachedIterationCap();

    // Rule 1: Iteration cap check (prevents infinite bargaining)
    if (userRole == 'client' && iterationsLocked) {
      setState(() {
        _validationError = 'Further bargaining is closed. You can only confirm or cancel.';
      });
      return;
    }

    final errors = <String>[];

    // For client, get admin's last offered prices to prevent increases
    // This ensures clients can only counter with lower or equal prices
    Map<String, double> adminPrices = {};
    if (userRole == 'client') {
      final latestPanelItems = _getLatestPanelItems();
      for (var item in latestPanelItems) {
        final key = item['itemId'] ?? item['grade'];
        adminPrices[key] = (item['unitPrice'] ?? 0.0).toDouble();
      }
    }

    for (var item in _currentDraftItems ?? []) {
      if (item['status']?.toString() == 'DECLINED') continue;

      final qty = (item['offeredKgs'] ?? 0.0).toDouble();
      final requestedKgs = (item['requestedKgs'] ?? 0.0).toDouble();
      final offeredNo = (item['offeredNo'] ?? 0.0).toDouble();
      final requestedNo = (item['requestedNo'] ?? 0.0).toDouble();
      final label = item['grade'] ?? item['type'] ?? 'Item';
      final multiplier = _getBagboxMultiplier(item['bagbox']?.toString());

      // Validation Logic
      if (requestedNo > 0 && (offeredNo < 0 || !offeredNo.isFinite)) {
        errors.add('$label: enter valid bags/boxes count.');
      }

      // 1. Max Quantity Constraint (Admin only)
      if (userRole != 'client') {
        if (requestedNo > 0 && offeredNo > requestedNo) {
          errors.add('$label: cannot exceed requested ${offeredNo.toInt()} ${item['bagbox']}.');
        }
        if (requestedKgs > 0 && qty > requestedKgs) {
          errors.add('$label: cannot exceed requested ${requestedKgs.toStringAsFixed(0)} kgs.');
        }
      }

      if (!qty.isFinite || qty <= 0) {
        errors.add('$label: quantity (kgs) must be greater than 0.');
      }

      // 2. Bag/Box Multiplier Logic
      if (multiplier != null && multiplier > 0 && qty > 0) {
        final remainder = qty % multiplier;
        final isMultiple = remainder < 0.01 || (remainder - multiplier).abs() < 0.01;
        if (!isMultiple) {
          errors.add('$label: quantity must be multiple of ${multiplier.toInt()}kg (per ${item['bagbox']}).');
        }
      }

      // 3. Price Constraint (Client cannot Increase)
      if (userRole == 'client') {
        final itemKey = item['itemId'] ?? item['grade'];
        final adminPrice = adminPrices[itemKey] ?? 0.0;
        final clientPrice = (item['unitPrice'] ?? 0.0).toDouble();

        if (adminPrice > 0 && clientPrice > adminPrice) {
          errors.add('$label: cannot increase price above ₹${adminPrice.toStringAsFixed(0)} (Admin\'s offer).');
        }
      }
    }

    if (errors.isNotEmpty) {
      setState(() {
        _validationError = errors.join('\n');
      });
      return;
    }

    // Stock validation warning (admin only) — L733 requirement
    if (userRole != 'client') {
      final stockWarnings = await _checkStockSufficiency();
      if (stockWarnings.isNotEmpty && mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 22),
                SizedBox(width: 8),
                Text('Stock Warning', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Some items may exceed available stock:', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                const SizedBox(height: 8),
                ...stockWarnings.map((w) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $w', style: const TextStyle(fontSize: 12, color: Color(0xFFEF4444), fontWeight: FontWeight.w500)),
                )),
                const SizedBox(height: 8),
                const Text('Do you still want to send this offer?', style: TextStyle(fontSize: 13)),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E293B), foregroundColor: Colors.white),
                child: const Text('Send Anyway'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
    }

    // All validations passed, send panel
    await _sendPanel();
  }

  /// Check stock sufficiency for each draft item (L733)
  Future<List<String>> _checkStockSufficiency() async {
    final warnings = <String>[];
    try {
      final stockResp = await _apiService.getNetStock();
      final stockData = stockResp.data;
      if (stockData == null) return warnings;
      final headers = (stockData['headers'] as List?)?.cast<String>() ?? [];
      final rows = (stockData['rows'] as List?) ?? [];

      for (final item in _currentDraftItems ?? []) {
        if (item['status']?.toString() == 'DECLINED') continue;
        final grade = item['grade']?.toString() ?? '';
        final type = item['type']?.toString() ?? '';
        final offeredKgs = (item['offeredKgs'] ?? 0.0).toDouble();
        if (offeredKgs <= 0 || grade.isEmpty) continue;

        // Find matching type row
        final typeRow = rows.firstWhere(
          (r) => (r['type']?.toString() ?? '').toLowerCase() == type.toLowerCase(),
          orElse: () => null,
        );
        if (typeRow == null) continue;

        // Find matching grade column
        final values = (typeRow['values'] as List?) ?? [];
        final gradeIdx = headers.indexWhere((h) => h.toLowerCase().contains(grade.toLowerCase()) || grade.toLowerCase().contains(h.toLowerCase()));
        if (gradeIdx < 0 || gradeIdx >= values.length) continue;

        final available = (values[gradeIdx] ?? 0).toDouble();
        if (offeredKgs > available) {
          warnings.add('$grade ($type): Offered ${offeredKgs.toStringAsFixed(0)}kg, Available ${available.toStringAsFixed(0)}kg');
        }
      }
    } catch (_) {
      // Non-blocking: if stock check fails, skip warning
    }
    return warnings;
  }

  // ============================================================================
  // TASK 12: SCROLL POSITION PRESERVATION (Matching PanelChat.js)
  // ============================================================================
  // matches PanelChat.js: renderMessages() - Lines 287-288, 328-330
  // 
  // Renders the message list with intelligent scroll position preservation.
  // 
  // Key behaviors:
  // 1. Before render: Checks if user is scrolled to bottom (within 50px threshold)
  // 2. Saves current scroll position if user has scrolled up
  // 3. After render: Auto-scrolls to bottom if user was at bottom, otherwise restores position
  // 4. Optimization: Uses signature checksum to prevent unnecessary re-renders
  // 
  // This ensures smooth UX - new messages auto-scroll if user is at bottom,
  // but preserves scroll position if user is reading older messages.

  Widget _renderMessages(List<dynamic> messages, Map<String, dynamic> requestMeta) {
    // Save scroll position state before rendering
    // matches PanelChat.js: const isScrolledToBottom = (this.messagesContainer.scrollHeight - this.messagesContainer.scrollTop) <= (this.messagesContainer.clientHeight + 50);
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      // 50px threshold: if within 50px of bottom, consider user "at bottom"
      _wasScrolledToBottom = (maxScroll - currentScroll) <= 50;
      if (!_wasScrolledToBottom) {
        _savedScrollPosition = currentScroll;
      }
    }

    // Checksum to prevent re-rendering identical data (stops refreshing/blinking)
    // matches PanelChat.js: const currentSignature = JSON.stringify({...})
    // This optimization prevents unnecessary rebuilds when data hasn't changed
    final currentSignature = jsonEncode({
      'msgCount': messages.length,
      'lastMsgId': messages.isNotEmpty ? messages.last['messageId'] : null,
      'status': requestMeta['status'],
      'items': requestMeta['currentItems'], // Check if edits happened
    });

    // BUG 16 fix: Use addPostFrameCallback instead of setState during build
    if (_lastRenderSignature != currentSignature) {
      _lastRenderSignature = currentSignature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }

    // Build message list with date separators
    // matches PanelChat.js: let lastDate = null; messages.forEach(msg => {...})
    String? lastDate;
    final List<Widget> messageWidgets = [];

    // FIX: If no messages but request has items, create a synthetic "initial request" panel
    // This ensures the client's request appears as a WhatsApp bubble in the chat
    final hasInitialRequest = requestMeta['currentItems'] != null && 
        (requestMeta['currentItems'] as List).isNotEmpty;
    
    if (messages.isEmpty && hasInitialRequest) {
      // Create synthetic initial request message
      // Uses panelSnapshot.items format expected by _buildPanelMessage
      final syntheticRequest = {
        'messageType': 'PANEL',
        'senderRole': 'client',
        'senderUsername': requestMeta['clientName'] ?? 'Client',
        'timestamp': requestMeta['createdAt'] ?? DateTime.now().toIso8601String(),
        'messageId': 'initial-request-${requestMeta['id'] ?? 'synthetic'}',
        'panelSnapshot': {
          'items': requestMeta['currentItems'],
          'panelVersion': 0,  // Initial request, before admin's first offer
          'panelType': 'CLIENT_REQUEST',
        },
        'note': requestMeta['notes'] ?? 'Initial Request',
      };
      final msgDate = _formatDate(syntheticRequest['timestamp']);
      messageWidgets.add(_buildDateSeparator(msgDate));
      messageWidgets.add(_createMessageBubble(syntheticRequest));
      lastDate = msgDate;
    } else if (messages.isEmpty) {
      // Truly empty - no items and no messages
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('💬', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            const Text(
              'No messages yet. Start the conversation!',
              style: TextStyle(color: AppTheme.muted),
            ),
          ],
        ),
      );
    }

    for (final msg in messages) {
      final msgDate = _formatDate(msg['timestamp']);
      if (msgDate != lastDate) {
        messageWidgets.add(_buildDateSeparator(msgDate));
        lastDate = msgDate;
      }
      messageWidgets.add(_createMessageBubble(msg));
    }

    // If Status is CONFIRMED and Admin, show Convert Button at bottom
    // matches PanelChat.js: if (requestMeta.status === 'CONFIRMED' && this.userRole === 'admin')
    final userRole = _getUserRole();
    if (requestMeta['status'] == 'CONFIRMED' && (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin')) {
      messageWidgets.add(_buildConvertActionBar());
    }

    // Task 12: Restore scroll position after rendering
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      
      if (_wasScrolledToBottom) {
        // Auto-scroll to bottom if user was at bottom
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else if (_savedScrollPosition != null) {
        // Restore previous scroll position
        _scrollController.jumpTo(_savedScrollPosition!);
      }
    });

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      itemCount: messageWidgets.length,
      itemBuilder: (context, index) => messageWidgets[index],
    );
  }

  // Parse dd/MM/yy order date to DateTime
  DateTime? _parseOrderDate(String dateStr) {
    if (dateStr.isEmpty) return null;
    if (dateStr.contains('/')) {
      final parts = dateStr.split('/');
      if (parts.length == 3) {
        final day = int.tryParse(parts[0]) ?? 1;
        final month = int.tryParse(parts[1]) ?? 1;
        var year = int.tryParse(parts[2]) ?? 0;
        if (year < 100) year += 2000;
        return DateTime(year, month, day);
      }
    }
    return DateTime.tryParse(dateStr);
  }

  // Helper to format date as "10 Feb 2026"
  String _formatDate(dynamic timestamp) {
    try {
      final date = DateTime.parse(timestamp.toString());
      return DateFormat('d MMM yyyy').format(date);
    } catch (e) {
      return '';
    }
  }

  // matches PanelChat.js: chat-date-separator
  Widget _buildDateSeparator(String dateStr) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.5),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withOpacity(0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          dateStr,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppTheme.muted,
          ),
        ),
      ),
    );
  }

  // matches PanelChat.js: convert-action-bar
  Widget _buildConvertActionBar() {
    return Container(
      padding: const EdgeInsets.all(15),
      alignment: Alignment.center,
      child: Column(
        children: [
          ElevatedButton(
            onPressed: () {
              // matches PanelChat.js: onclick="panelChat.openNewOrderPopup()"
              _openNewOrderPopup();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('📝 Convert to Order'),
          ),
          const SizedBox(height: 5),
          const Text(
            '(Opens Manual Entry Form)',
            style: TextStyle(fontSize: 12, color: AppTheme.muted),
          ),
        ],
      ),
    );
  }

  // matches PanelChat.js: createMessageBubble(msg)
  Widget _createMessageBubble(dynamic msg) {
    final userRole = _getUserRole();
    final senderRole = msg['senderRole']?.toString().toLowerCase() ?? '';
    
    // matches PanelChat.js: const isMe = (msg.senderRole.toLowerCase() === this.userRole.toLowerCase())...
    final isAdminSide = {'admin', 'ops', 'superadmin'};
    final isMe = (senderRole == userRole) ||
        (isAdminSide.contains(userRole) && isAdminSide.contains(senderRole));

    final messageType = msg['messageType'] ?? 'TEXT';
    final messageId = msg['messageId']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    // matches PanelChat.js: bubble.className = `message-bubble ${msg.messageType === 'SYSTEM' ? 'system' : (isMe ? 'sent' : 'received')}`;
    if (messageType == 'SYSTEM') {
      return _buildSystemMessage(msg);
    } else if (messageType == 'TEXT') {
      return _buildTextMessage(msg, isMe, messageId);
    } else if (messageType == 'PANEL') {
      return _buildPanelMessage(msg, isMe, messageId);
    } else if (messageType == 'ORDER_SUMMARY') {
      return _buildOrderSummaryMessage(msg, messageId);
    }
    
    return const SizedBox.shrink();
  }

  Widget _buildTextMessage(dynamic msg, bool isMe, String messageId) {
    // iMessage-style colors: green for sent, light grey for received
    const sentColor = Color(0xFF34C759);      // iMessage green
    const receivedColor = Color(0xFFE9E9EB);  // iMessage light grey
    const receivedBorderColor = Color(0xFFD1D1D6);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final bubbleColor = isMe ? sentColor : receivedColor;

        return Container(
          key: Key('msg-id-$messageId'),
          margin: EdgeInsets.only(
            left: isMe ? (isMobile ? 48 : 80) : 14,
            right: isMe ? 14 : (isMobile ? 48 : 80),
            bottom: 6,
          ),
          child: Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.78),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: isMe ? const Radius.circular(18) : const Radius.circular(4),
                      bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(18),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _escapeHtml(msg['message'] ?? ''),
                        style: TextStyle(
                          color: isMe ? Colors.white : const Color(0xFF1A1A1A),
                          fontSize: isMobile ? 15 : 16,
                          fontWeight: FontWeight.w400,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            isMe ? 'You' : (msg['senderUsername'] ?? ''),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: isMe ? Colors.white.withOpacity(0.6) : const Color(0xFF8E8E93),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _formatTime(msg['timestamp']),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: isMe ? Colors.white.withOpacity(0.6) : const Color(0xFF8E8E93),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // iMessage-style smooth curved bezier tail
                Positioned(
                  right: isMe ? -6 : null,
                  left: isMe ? null : -6,
                  bottom: 0,
                  child: CustomPaint(
                    size: const Size(10, 16),
                    painter: _MessageTailPainter(
                      color: bubbleColor,
                      isRight: isMe,
                      shadowOpacity: 0.06,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ============================================================================
  // TASK 10: CSS STYLING PARITY - System Message
  // ============================================================================
  // matches panelChat.css: .message-bubble.system .text-message - Lines 259-266

  Widget _buildSystemMessage(dynamic msg) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B).withOpacity(0.04),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFF1E293B).withOpacity(0.08)),
        ),
        child: Text(
          _escapeHtml(msg['message'] ?? '').toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w900,
            color: Color(0xFF64748B),
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  // BUG 14 fix: Flutter Text widget doesn't render HTML, so no escaping needed
  // The original escapeHtml was for web HTML rendering; Flutter handles text safely
  String _escapeHtml(String text) {
    return text;
  }

  String _formatTime(dynamic timestamp) {
    try {
      final date = DateTime.parse(timestamp.toString());
      return DateFormat('HH:mm').format(date);
    } catch (e) {
      return '';
    }
  }

  // ============================================================================
  // TASK 1: HELPER METHODS (Matching PanelChat.js)
  // ============================================================================

  // matches PanelChat.js: getBagboxMultiplier(value) - Lines 1258-1264
  double? _getBagboxMultiplier(String? value) {
    if (value == null || value.isEmpty) return null;
    final normalized = value.toLowerCase();
    if (normalized.contains('bag')) return 50.0;
    if (normalized.contains('box')) return 20.0;
    return null;
  }

  // matches PanelChat.js: getLatestPanelItems() - Lines 1315-1319
  List<dynamic> _getLatestPanelItems() {
    final panels = _messages.where((m) => m['messageType'] == 'PANEL').toList();
    if (panels.isEmpty) return [];
    final lastPanel = panels.last;
    return (lastPanel['panelSnapshot']?['items'] as List?) ?? [];
  }

  // matches PanelChat.js: hasReachedIterationCap() - Lines 1309-1313
  bool _hasReachedIterationCap() {
    final panelCount = _messages.where((m) => m['messageType'] == 'PANEL').length;
    return panelCount >= 4;
  }

  // matches PanelChat.js: canActOnPanel(msg) - Lines 492-500
  bool _canActOnPanel(dynamic msg) {
    if (_requestMeta == null) return false;
    final status = _requestMeta!['status']?.toString() ?? '';
    final userRole = _getUserRole();
    
    if (userRole == 'client') {
      return status == 'ADMIN_SENT' || status == 'CLIENT_DRAFT' || status == 'CONFIRMED';
    } else {
      return status == 'CLIENT_SENT' || status == 'OPEN' || 
             status == 'CLIENT_DRAFT' || status == 'ADMIN_DRAFT' || status == 'CONFIRMED';
    }
  }

  // matches PanelChat.js: getPanelMessages() - Lines 1305-1307
  List<dynamic> _getPanelMessages() {
    return _messages.where((m) => m['messageType'] == 'PANEL').toList();
  }

  // ============================================================================
  // TASK 2: PANEL MESSAGE RENDERING (Matching PanelChat.js)
  // ============================================================================
  // matches PanelChat.js: createMessageBubble() PANEL rendering - Lines 366-442

  Widget _buildPanelMessage(dynamic msg, bool isMe, String messageId) {
    final panel = msg['panelSnapshot'] ?? {};
    final items = (panel['items'] as List?) ?? [];
    final panelVersion = panel['panelVersion'] ?? 0;
    
    final panelMessages = _getPanelMessages();
    final isLatest = panelMessages.isNotEmpty && msg == panelMessages.last;
    final canAct = isLatest && _canActOnPanel(msg);
    
    final userRole = _getUserRole();
    final requestType = _requestMeta?['requestType']?.toString() ?? '';
    final showEnquiryCheckbox = userRole == 'client' && requestType == 'ENQUIRE_PRICE';
    
    // Stream 1B: Determine if we need the glowing border for 2hr admin reminder
    final bool showGlow = isLatest && _isAdminReminderNeeded() &&
        (_getUserRole() == 'admin' || _getUserRole() == 'ops');

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;

        return Container(
          key: Key('msg-id-$messageId'),
          margin: EdgeInsets.only(
            left: isMe ? (isMobile ? 20 : 60) : 10,
            right: isMe ? 10 : (isMobile ? 20 : 60),
            bottom: 16,
          ),
          child: Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(maxWidth: isMobile ? constraints.maxWidth * 0.95 : 550),
              child: Column(
                crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  // Stream 1B: Wrap with animated glow container if 2hr reminder active
                  _buildGlowWrapper(
                    showGlow: showGlow,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: isMe ? const Radius.circular(18) : const Radius.circular(4),
                      bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(18),
                    ),
                    child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: isMe ? const Radius.circular(18) : const Radius.circular(4),
                        bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(18),
                      ),
                      border: Border.all(
                        color: canAct
                          ? const Color(0xFF3B82F6).withOpacity(0.4)
                          : const Color(0xFFE2E8F0),
                        width: canAct ? 2 : 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(canAct ? 0.08 : 0.04),
                          blurRadius: canAct ? 20 : 10,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B).withOpacity(0.04),
                            border: Border(bottom: BorderSide(color: const Color(0xFFE2E8F0))),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3B82F6),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(color: const Color(0xFF3B82F6).withOpacity(0.5), blurRadius: 4, spreadRadius: 1),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'OFFER REVIEW',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12,
                                      color: const Color(0xFF1E293B),
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E293B).withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'v$panelVersion',
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF64748B)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        _buildPanelItemsTable(items, showEnquiryCheckbox, userRole),
                        _buildPanelTotals(items, panel),
                        if (canAct) _renderPanelActionsInBubble(msg, isLatest),
                      ],
                    ),
                  ),
                  ), // close _buildGlowWrapper
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isMe ? 'You' : (msg['senderUsername'] ?? ''),
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF94A3B8)),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatTime(msg['timestamp']),
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF94A3B8)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Build Panel Items as cards — single-line summary per item
  Widget _buildPanelItemsTable(List<dynamic> items, bool showEnquiryCheckbox, String? userRole) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: items.asMap().entries.map((entry) {
          final idx = entry.key;
          final item = entry.value;
          final isDeclined = item['status']?.toString() == 'DECLINED';

          final grade = item['grade']?.toString() ?? '-';
          final no = (item['offeredNo'] ?? item['requestedNo'] ?? 0);
          final bagbox = item['bagbox']?.toString() ?? '';
          final kgs = item['offeredKgs'] ?? item['requestedKgs'] ?? 0;
          final price = item['unitPrice'] ?? 0;
          final brand = item['brand']?.toString() ?? '';
          final notes = [
            item['clientNote'],
            item['adminNote'],
            item['notes'],
          ].where((n) => n != null && n.toString().trim().isNotEmpty)
           .toSet() // deduplicate in case clientNote == notes
           .join(' | ');

          // Build brand short code for badge (e.g. "Emperor Magenta Pink" → "EMP", "ESPL Premium" → "ESPL")
          String brandBadge = '';
          if (brand.isNotEmpty) {
            final parts = brand.split(' ');
            if (parts.length == 1) {
              brandBadge = brand.length <= 5 ? brand.toUpperCase() : brand.substring(0, 4).toUpperCase();
            } else {
              brandBadge = parts.map((p) => p.isNotEmpty ? p[0] : '').join().toUpperCase();
              if (brandBadge.length > 5) brandBadge = brandBadge.substring(0, 5);
            }
          }

          // Summary line: "Grade - No BagBox - Kgs kgs x ₹Price - Brand"
          final summaryParts = <String>[
            grade,
            '$no $bagbox',
            '$kgs kgs x ₹$price',
          ];
          if (brand.isNotEmpty) summaryParts.add(brand);
          final summaryText = summaryParts.join(' - ');

          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isDeclined ? const Color(0xFFF8F8F8) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDeclined ? const Color(0xFFE2E8F0) : const Color(0xFFE2E8F0),
              ),
            ),
            child: Row(
              children: [
                if (showEnquiryCheckbox) ...[
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _selectedEnquiryIndices.contains(idx),
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            _selectedEnquiryIndices.add(idx);
                          } else {
                            _selectedEnquiryIndices.remove(idx);
                          }
                        });
                      },
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summaryText,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: isDeclined ? const Color(0xFF94A3B8) : const Color(0xFF334155),
                          decoration: isDeclined ? TextDecoration.lineThrough : null,
                          height: 1.4,
                        ),
                      ),
                      if (notes.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            notes,
                            style: TextStyle(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: isDeclined ? const Color(0xFFCBD5E1) : const Color(0xFF94A3B8),
                              decoration: isDeclined ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (brandBadge.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isDeclined ? const Color(0xFFCBD5E1) : const Color(0xFF22C55E),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      brandBadge,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
                if (isDeclined) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.close, size: 18, color: const Color(0xFF94A3B8)),
                ],
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTableHeaderCell(String text, {double? width}) {
    return TableCell(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppTheme.muted,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  // Build Item Status Badge (matches PanelChat.js: panel-item-status)
  Widget _buildItemStatusBadge(String status) {
    Color bgColor;
    Color textColor;
    
    switch (status) {
      case 'REQUESTED':
        bgColor = const Color(0xFFE0E7FF).withOpacity(0.7);
        textColor = const Color(0xFF3730A3);
        break;
      case 'OFFERED':
        bgColor = const Color(0xFFDBEAFE).withOpacity(0.7);
        textColor = const Color(0xFF1E40AF);
        break;
      case 'DECLINED':
        bgColor = const Color(0xFFFEE2E2).withOpacity(0.7);
        textColor = const Color(0xFF991B1B);
        break;
      case 'COUNTERED':
        bgColor = const Color(0xFFFEF3C7).withOpacity(0.7);
        textColor = const Color(0xFF92400E);
        break;
      case 'ACCEPTED':
        bgColor = const Color(0xFFD1FAE5).withOpacity(0.7);
        textColor = const Color(0xFF065F46);
        break;
      case 'FINALIZED':
        bgColor = const Color(0xFFE5E7EB).withOpacity(0.7);
        textColor = const Color(0xFF374151);
        break;
      default:
        bgColor = Colors.grey.withOpacity(0.2);
        textColor = Colors.grey;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: textColor,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // Build Panel Totals (matches PanelChat.js: panel-message-totals)
  // matches panelChat.css: .panel-message-totals - Lines 523-543
  Widget _buildPanelTotals(List<dynamic> items, Map<String, dynamic> panel) {
    // Calculate total value
    double totalValue = 0.0;
    for (var item in items) {
      if (item['status']?.toString() != 'DECLINED') {
        final kgs = (item['offeredKgs'] ?? item['requestedKgs'] ?? 0.0).toDouble();
        final price = (item['unitPrice'] ?? 0.0).toDouble();
        totalValue += kgs * price;
      }
    }
    
    // Use panel.totals if available, otherwise calculate
    final displayTotal = panel['totals']?['offeredValue'] ?? totalValue;
    
    return ClipRRect(
      child: BackdropFilter(
        // matches panelChat.css: backdrop-filter: blur(8px) - Line 526
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          // matches panelChat.css: padding: 14px 20px - Line 524
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            // matches panelChat.css: background: rgba(255, 255, 255, 0.2) - Line 525
            color: Colors.white.withOpacity(0.2),
            border: Border(
              // matches panelChat.css: border-top: 1px solid rgba(255, 255, 255, 0.4) - Line 528
              top: BorderSide(
                color: Colors.white.withOpacity(0.4),
                width: 1,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // matches panelChat.css: .panel-total-label - Line 536
              Text(
                '${items.length} items',
                style: const TextStyle(
                  // matches panelChat.css: font-size: 13px - Line 532
                  fontSize: 13,
                  color: AppTheme.muted,
                ),
              ),
              // matches panelChat.css: .panel-total-value - Line 539-542
              Text(
                'Total: ₹${_formatCurrency(displayTotal)}',
                style: const TextStyle(
                  // matches panelChat.css: font-size: 15px - Line 542
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.title,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCurrency(dynamic value) {
    if (value == null) return '-';
    final numValue = (value is num) ? value : double.tryParse(value.toString()) ?? 0.0;
    return numValue.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  // ============================================================================
  // TASK 3: PANEL ACTIONS BUTTONS (Matching PanelChat.js)
  // ============================================================================
  // matches PanelChat.js: renderPanelActionsInBubble(msg, isLatest) - Lines 502-609

  Widget _renderPanelActionsInBubble(dynamic msg, bool isLatest) {
    if (!isLatest) return const SizedBox.shrink(); // matches: if (!isLatest) return '';

    if (_requestMeta == null) return const SizedBox.shrink();
    
    final status = _requestMeta!['status']?.toString() ?? 'OPEN';
    final iterationsLocked = _hasReachedIterationCap();
    final userRole = _getUserRole();
    final requestType = _requestMeta!['requestType']?.toString() ?? '';
    final messageId = msg['messageId']?.toString() ?? '';

    List<Widget> buttons = [];

    if (userRole == 'client') {
      if (requestType == 'ENQUIRE_PRICE') {
        // SPECIAL CASE: Enquiry Conversion
        // matches PanelChat.js: Lines 510-528
        if (status == 'ADMIN_SENT' || status == 'CLIENT_DRAFT') {
          if (status == 'ADMIN_SENT') {
            // BUG 27 fix: Handle both List (new) and String (legacy comma-separated) formats
            final rawLinked = _requestMeta!['linkedOrderIds'];
            final List? linkedOrderIds = rawLinked is List ? rawLinked : (rawLinked is String ? rawLinked.split(',').map((s) => s.trim()).toList() : null);
            final isConverted = linkedOrderIds != null &&
                linkedOrderIds.any((id) => id.toString().contains('CONVERTED_TO:'));
            
            buttons.add(
              _buildPanelActionButton(
                label: isConverted ? 'Already Converted' : 'Convert to Order Request',
                icon: '📝',
                isPrimary: true,
                onPressed: isConverted ? null : () => _convertEnquiryToOrder(messageId),
                isDisabled: isConverted,
              ),
            );
          }
        }
      } else if (status == 'ADMIN_SENT' || status == 'CLIENT_DRAFT') {
        // Stream 1B: Disable client actions when acceptance window expired (ADMIN_SENT only)
        final bool clientExpired = status == 'ADMIN_SENT' && _isAcceptanceExpired;

        // matches PanelChat.js: Lines 529-543
        buttons.add(
          _buildPanelActionButton(
            label: 'Cancel',
            icon: '❌',
            isDanger: true,
            onPressed: () => _cancelRequest(),
          ),
        );

        if (!iterationsLocked) {
          buttons.add(
            _buildPanelActionButton(
              label: clientExpired ? 'Expired' : 'Continue Bargaining',
              icon: status == 'CLIENT_DRAFT' ? '📝' : '💬',
              isSecondary: true,
              isDisabled: clientExpired,
              onPressed: clientExpired ? null : (status == 'CLIENT_DRAFT'
                  ? () {
                      // Focus draft note field (handled by draft editor)
                      _scrollToBottom();
                    }
                  : () => _startBargain()),
            ),
          );
        }

        buttons.add(
          _buildPanelActionButton(
            label: clientExpired ? 'Expired' : 'Confirm',
            icon: '✅',
            isPrimary: true,
            isDisabled: clientExpired,
            onPressed: clientExpired ? null : () => _confirmRequest(messageId),
          ),
        );
      } else if (status == 'CONFIRMED') {
        // Client side: Show nothing
        // matches PanelChat.js: Lines 563-567
        return const SizedBox.shrink();
      }
    } else if (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') {
      if (status == 'CLIENT_SENT' || status == 'OPEN') {
        // matches PanelChat.js: Lines 569-582
        buttons.add(
          _buildPanelActionButton(
            label: 'Cancel',
            icon: '❌',
            isDanger: true,
            onPressed: () => _cancelRequest(),
          ),
        );

        buttons.add(
          _buildPanelActionButton(
            label: status == 'OPEN' ? 'Draft Offer' : 'Counter Offer',
            icon: '📝',
            isSecondary: true,
            onPressed: () => _adminStartDraft(),
          ),
        );

        // BUG 9 fix: Only show Finalize from CLIENT_SENT, not from OPEN
        if (status == 'CLIENT_SENT') {
          buttons.add(
            _buildPanelActionButton(
              label: 'Finalize & Create Order',
              icon: '✅',
              isPrimary: true,
              onPressed: () => _confirmRequest(messageId),
            ),
          );
        }
      } else if (status == 'ADMIN_DRAFT') {
        // matches PanelChat.js: Lines 583-596
        buttons.add(
          _buildPanelActionButton(
            label: 'Cancel',
            icon: '❌',
            isDanger: true,
            onPressed: () => _cancelRequest(),
          ),
        );
        
        buttons.add(
          _buildPanelActionButton(
            label: 'Continue Drafting',
            icon: '📝',
            isSecondary: true,
            onPressed: () {
              // Focus draft note field (handled by draft editor)
              _scrollToBottom();
            },
          ),
        );
        
        buttons.add(
          _buildPanelActionButton(
            label: 'Finalize & Create Order',
            icon: '✅',
            isPrimary: true,
            onPressed: () => _confirmRequest(messageId),
          ),
        );
      } else if (status == 'ADMIN_SENT') {
        // Stream 1B: Admin sees reinitiate button when acceptance expired
        if (_isAcceptanceExpired) {
          buttons.add(
            _buildPanelActionButton(
              label: 'Reinitiate Negotiation',
              icon: '🔄',
              isPrimary: true,
              onPressed: () => _reinitiateNegotiation(),
            ),
          );
        }
      } else if (status == 'CONFIRMED') {
        // matches PanelChat.js: Lines 597-604
        buttons.add(
          _buildPanelActionButton(
            label: 'Complete Order',
            icon: '🚀',
            isPrimary: true,
            onPressed: () => _openNewOrderPopup(),
          ),
        );
      }
    }

    if (buttons.isEmpty) return const SizedBox.shrink();

    // matches PanelChat.js: panel-actions container
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.center,
        children: buttons,
      ),
    );
  }

  // ============================================================================
  // TASK 10: CSS STYLING PARITY - Panel Action Buttons
  // ============================================================================
  // matches panelChat.css: .panel-action-btn - Lines 576-626

  Widget _buildPanelActionButton({
    required String label,
    required String icon,
    required VoidCallback? onPressed,
    bool isPrimary = false,
    bool isSecondary = false,
    bool isDanger = false,
    bool isDisabled = false,
  }) {
    return _ButtonWithHover(
      label: label,
      icon: icon,
      onPressed: isDisabled ? null : onPressed,
      isPrimary: isPrimary,
      isSecondary: isSecondary,
      isDanger: isDanger,
      isDisabled: isDisabled,
    );
  }

  // ============================================================================
  // TASK 5: ACTION METHODS (PART 1) - Matching PanelChat.js
  // ============================================================================

  // matches PanelChat.js: async startBargain() - Lines 1095-1105
  Future<void> _startBargain() async {
    try {
      await _apiService.clientStartBargain(widget.requestId);
      if (!mounted) return;
      await _loadMessages();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start bargain: ${e.toString()}')),
      );
    }
  }

  // matches PanelChat.js: async adminStartDraft() - Lines 1107-1114
  Future<void> _adminStartDraft() async {
    try {
      await _apiService.adminStartDraft(widget.requestId);
      if (!mounted) return;
      await _loadMessages();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start draft: ${e.toString()}')),
      );
    }
  }

  // matches PanelChat.js: async sendPanel() - Lines 1284-1303
  Future<void> _sendPanel() async {
    if (_currentDraftItems == null || _currentDraftItems!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No items to send')),
      );
      return;
    }

    final userRole = _getUserRole();
    final panelSnapshot = {
      'items': _currentDraftItems,
      'stage': (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') ? 'ADMIN_SENT' : 'CLIENT_SENT',
      'basePanelVersion': _requestMeta?['panelVersion'],
    };

    final note = _draftNoteController.text.trim();

    try {
      if (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') {
        await _apiService.adminSendPanel(widget.requestId, panelSnapshot, note.isEmpty ? null : note);
      } else {
        await _apiService.clientSendPanel(widget.requestId, panelSnapshot, note.isEmpty ? null : note);
      }
      if (!mounted) return;

      setState(() {
        _currentDraftItems = null;
        _initialDraftState = null;
        _draftNoteController.clear();
      });

      await _loadMessages();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send offer: ${e.toString()}')),
      );
    }
  }

  Future<void> _cancelRequest() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Request?'),
        content: const Text('Are you sure you want to CANCEL this request? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final userRole = _getUserRole();
    final reason = (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin')
        ? 'Admin have rejected the request'
        : 'Client does not wants to proceed with the negotiation';

    try {
      if (userRole == 'admin' || userRole == 'ops' || userRole == 'superadmin') {
        await _apiService.adminCancelRequest(widget.requestId, reason);
      } else {
        await _apiService.cancelRequest(widget.requestId, reason);
      }
      if (!mounted) return;
      await _loadMessages();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to cancel: ${e.toString()}')),
      );
    }
  }

  // matches PanelChat.js: async confirmRequest(msgId) - Lines 1520-1568
  // 
  // Handles request confirmation for both client and admin roles.
  // 
  // Client Flow:
  // - Shows confirmation dialog
  // - Calls API to confirm request
  // - Status changes to CONFIRMED
  // - Admin can then finalize and create order
  // 
  // Admin Flow:
  // - Saves any pending draft edits first
  // - Confirms the request (status -> CONFIRMED)
  // - Automatically opens order conversion popup
  // - If already CONFIRMED, just opens popup (allows re-opening)
  // 
  // Note: This is a critical state transition that finalizes the negotiation.
  Future<void> _confirmRequest(String? messageId) async {
    final userRole = _getUserRole();
    
    // CLIENT: Direct confirmation from bubble
    // Client confirms the offer, locking in the agreed terms
    if (userRole == 'client') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Request?'),
          content: const Text('Are you sure you want to confirm these prices and terms? This will finalize the agreement.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      try {
        await _apiService.confirmRequest(widget.requestId);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request Confirmed! The Admin will now convert this to a formal order.')),
        );
        await _loadMessages();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to confirm: ${e.toString()}')),
        );
      }
      return;
    }

    // Admin/Ops confirmation logic
    final latestItems = _currentDraftItems?.isNotEmpty == true
        ? _currentDraftItems!
        : _getLatestPanelItems();

    // If already CONFIRMED or CONVERTED, just open popup
    final reqStatus = _requestMeta?['status'];
    if (reqStatus == 'CONFIRMED' || reqStatus == 'CONVERTED_TO_ORDER') {
      _openNewOrderPopup(latestItems);
      return;
    }

    try {
      if (latestItems.isNotEmpty) {
        await _apiService.adminSaveDraft(widget.requestId, {'items': latestItems});
      }
      await _apiService.adminConfirmRequest(widget.requestId);
      if (!mounted) return;

      _openNewOrderPopup(latestItems);
      await _loadMessages();
    } catch (e) {
      debugPrint('Confirm error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to confirm: ${e.toString()}')),
      );
    }
  }

  // matches PanelChat.js: async convertEnquiryToOrder(messageId) - Lines 629-713
  // 
  // Converts a Price Enquiry into a full Order Request.
  // 
  // This is a special flow for ENQUIRE_PRICE request types:
  // 1. Client selects items using checkboxes (Task 13)
  // 2. Creates a new REQUEST_ORDER with selected items
  // 3. Merges all notes (clientNote, adminNote, notes) into clientNote
  // 4. Includes price summary in initial text message
  // 5. Sets initialStatus='ADMIN_SENT' to auto-send the offer
  // 6. Sends confirmation message to original enquiry chat
  // 7. Navigates to the new order request
  // 
  // Key difference from regular order conversion:
  // - Only converts selected items (via checkboxes)
  // - Creates a NEW request instead of converting current one
  // - Preserves enquiry context in the new request's initial message
  Future<void> _convertEnquiryToOrder(String messageId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Convert Enquiry?'),
        content: const Text('This will create a new Order Request with the pricing from this enquiry. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Get items from the latest panel message (Admin's offer)
      final latestMsg = _messages.firstWhere(
        (m) => m['messageId']?.toString() == messageId,
        orElse: () => {},
      );

      if (latestMsg.isEmpty || latestMsg['panelSnapshot'] == null || 
          (latestMsg['panelSnapshot']?['items'] as List?)?.isEmpty == true) {
        throw Exception('Could not find offer data');
      }

      final sourceItems = (latestMsg['panelSnapshot']?['items'] as List?) ?? [];

      // Get selected items from checkboxes (if enquiry)
      List<dynamic> itemsToConvert = [];
      if (_selectedEnquiryIndices.isNotEmpty) {
        // Filter items based on selected indices
        itemsToConvert = sourceItems.asMap().entries
            .where((entry) => _selectedEnquiryIndices.contains(entry.key))
            .map((entry) => entry.value)
            .toList();
      } else {
        // Default: All items
        itemsToConvert = sourceItems;
      }

      // Consolidate notes: merge all per-item notes into clientNote for the new request
      // matches PanelChat.js: Lines 658-671
      final itemsVal = itemsToConvert.map((i) {
        final item = Map<String, dynamic>.from(i);
        final notes = [
          item['clientNote'],
          item['adminNote'],
          item['notes'],
        ].where((n) => n != null && n.toString().trim().isNotEmpty).map((n) => n.toString()).join(' | ');
        
        return {
          'grade': item['grade'],
          'type': item['type'],
          'bagbox': item['bagbox'],
          'kgs': item['offeredKgs'] ?? item['requestedKgs'],
          'no': item['offeredNo'] ?? item['requestedNo'],
          'offeredKgs': item['offeredKgs'] ?? item['requestedKgs'],
          'offeredNo': item['offeredNo'] ?? item['requestedNo'],
          'unitPrice': item['unitPrice'] ?? 0,
          'brand': item['brand'] ?? '',
          'adminNote': '', // Start fresh for the new negotiation
          'clientNote': notes.isEmpty ? '' : notes,
        };
      }).toList();

      // Find any global notes from the Enquiry chat (usually the first text/system message)
      final firstMsg = _messages.firstWhere(
        (m) => m['messageType'] == 'TEXT' || m['messageType'] == 'SYSTEM',
        orElse: () => {},
      );
      final enquiryGlobalNote = firstMsg['message']?.toString() ?? '';

      // Construct a summary text to ensure Price and Enquiry context is communicated
      final priceSummary = sourceItems.map((i) => '${i['grade']}: ₹${i['unitPrice'] ?? 0}').join(', ');
      String initialText = 'Converted from Price Enquiry #${widget.requestId}. Agreed Prices: $priceSummary';
      if (enquiryGlobalNote.isNotEmpty) {
        initialText += '\n\nOriginal Enquiry Note: $enquiryGlobalNote';
      }

      // Create request with initialStatus='ADMIN_SENT' to auto-send the offer
      // matches PanelChat.js: Lines 684-685
      final response = await _apiService.createClientRequest({
        'requestType': 'REQUEST_ORDER',
        'items': itemsVal,
        'initialText': initialText,
        'initialStatus': 'ADMIN_SENT',
        'sourceRequestId': widget.requestId,
      });

      if (response.data['success'] == true && response.data['requestId'] != null) {
        final newRequestId = response.data['requestId'].toString();
        
        // Notify current chat about the items selected for conversion
        final selectedItemsText = itemsToConvert.map((i) => 
          '• ${i['grade']} (${i['offeredKgs'] ?? i['requestedKgs']}kg @ ₹${i['unitPrice'] ?? 0})'
        ).join('\n');
        final confirmationMsg = '✅ **Converted to Order Request**\n\nThe following suborders have been moved to a new order request (#$newRequestId):\n$selectedItemsText';

        await _apiService.sendNegotiationMessage(widget.requestId, confirmationMsg);

        // Brief delay to allow the user to see the confirmation message
        await Future.delayed(const Duration(milliseconds: 1500));
        
        // Navigate to new request
        // In Flutter, we'd navigate to the new negotiation screen
        // For now, show success and reload
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Order Request #$newRequestId created successfully!'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 3),
          ),
        );
        
        await _loadMessages();
      } else {
        throw Exception(response.data['error']?.toString() ?? 'Failed to create request');
      }
    } catch (e) {
      debugPrint('Convert enquiry error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to convert: ${e.toString()}')),
      );
    }
  }

  // Task 9: Order Conversion Popup
  // matches PanelChat.js: Lines 1359-1434
  // ============================================================================
  // TASK 9: ORDER CONVERSION POPUP (Matching PanelChat.js)
  // ============================================================================
  // matches PanelChat.js: openNewOrderPopup() - Lines 1359-1434
  // 
  // Opens the NewOrder screen as a full-screen modal with pre-filled data.
  // 
  // Data Preparation:
  // - Filters out DECLINED items
  // - Derives bag/box count from kgs if not provided
  // - Consolidates all notes (clientNote, adminNote, notes) into single notes field
  // - Formats data for NewOrder screen structure
  // 
  // Navigation:
  // - Uses fullscreenDialog: true for modal presentation
  // - Passes prefillData with requestId, client, orderDate, and items
  // - Reloads messages after order creation to show ORDER_SUMMARY message
  // 
  // This is the final step in the negotiation flow - converting agreed terms into an order.

  Future<void> _openNewOrderPopup([List<dynamic>? items]) async {
    // Fallback to latest items if not provided
    // matches PanelChat.js: if (!items || !items.length) { items = ... }
    // Priority: provided items > latest panel items > current draft items
    List<dynamic> sourceItems = items ?? _getLatestPanelItems();
    
    if (sourceItems.isEmpty) {
      sourceItems = _currentDraftItems ?? [];
    }
    
    if (sourceItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No items available to convert.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    // Filter out declined items and format for NewOrder screen
    // matches PanelChat.js: filter(item => item.status !== 'DECLINED')
    final payloadItems = sourceItems
        .where((item) => item['status']?.toString() != 'DECLINED')
        .map((item) {
          // Calculate bagbox multiplier
          final multiplier = _getBagboxMultiplier(item['bagbox']?.toString());
          
          // Derive 'no' (bags/boxes count) if not provided
          // matches PanelChat.js: Lines 1377-1380
          final derivedNo = (item['offeredNo'] != null && (item['offeredNo'] as num) > 0)
              ? (item['offeredNo'] as num).toDouble()
              : (multiplier != null && multiplier > 0
                  ? ((item['offeredKgs'] ?? item['requestedKgs'] ?? 0) / multiplier)
                  : 0.0);
          
          // Consolidate notes
          // matches PanelChat.js: Lines 1388
          final notes = [
            item['clientNote'],
            item['adminNote'],
            item['notes'],
          ].where((n) => n != null && n.toString().trim().isNotEmpty)
           .map((n) => n.toString())
           .join(' | ');
          
          return {
            'grade': item['grade'] ?? '',
            'bagbox': item['bagbox'] ?? '',
            'no': derivedNo,
            'kgs': item['offeredKgs'] ?? item['requestedKgs'] ?? 0,
            'price': item['unitPrice'] ?? 0,
            'brand': item['brand'] ?? '',
            'notes': notes,
          };
        })
        .where((item) => ((item['kgs'] as num?) ?? 0) > 0 || ((item['no'] as num?) ?? 0) > 0)
        .toList();
    
    if (payloadItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No valid items to convert.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    // Prepare prefill data for NewOrder screen
    // matches PanelChat.js: payload object - Lines 1398-1403
    final prefillData = {
      'requestId': widget.requestId,
      'client': _requestMeta?['clientName']?.toString() ?? '',
      'orderDate': DateTime.now().toIso8601String().split('T')[0], // YYYY-MM-DD format
      'items': payloadItems,
    };
    
    // Navigate to NewOrder screen with full-screen modal
    // matches PanelChat.js: full-screen modal dialog - Lines 1410-1434
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true, // Full-screen modal
        builder: (context) => NewOrderScreen(prefillData: prefillData),
      ),
    );
    
    // Handle order creation success callback
    // matches PanelChat.js: message listener for 'order-created' - Lines 1326-1334
    if (result == true) {
      // Order created successfully
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Order Created Successfully!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
      
      // Reload messages to reflect the new order
      await _loadMessages();
    }
  }

  // ============================================================================
  // TASK 8: ORDER SUMMARY MESSAGE RENDERING (Matching PanelChat.js)
  // ============================================================================
  // matches PanelChat.js: createMessageBubble() ORDER_SUMMARY rendering - Lines 447-485

  Widget _buildOrderSummaryMessage(dynamic msg, String messageId) {
    // Backend maps payload to panelSnapshot
    final orders = (msg['panelSnapshot']?['orders'] as List?) ?? [];
    if (orders.isEmpty) {
      return const SizedBox.shrink();
    }

    final firstOrder = orders[0] as Map<String, dynamic>? ?? {};

    // Format Date: DD/MM/YY
    // matches PanelChat.js: Lines 452-460
    String dateStr = 'Today';
    try {
      final orderDate = firstOrder['orderDate'] ?? msg['timestamp'];
      if (orderDate != null) {
        final raw = orderDate.toString();
        // orderDate is already dd/MM/yy from backend
        if (raw.contains('/')) {
          dateStr = raw;
        } else {
          // Fallback for ISO timestamps
          final date = DateTime.parse(raw);
          final day = date.day.toString().padLeft(2, '0');
          final month = date.month.toString().padLeft(2, '0');
          final year = date.year.toString().substring(2);
          dateStr = '$day/$month/$year';
        }
      }
    } catch (e) {
      dateStr = 'Today';
    }

    final clientName = firstOrder['client']?.toString() ?? 
        _requestMeta?['clientName']?.toString() ?? 
        'Client';

    return Container(
      key: Key('msg-id-$messageId'),
      margin: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.95),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Success Header with Date/Client
            // matches PanelChat.js: Lines 467-471
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E), // success-color
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    '✅',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$dateStr - ${clientName.toUpperCase()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Cards Body
            // matches PanelChat.js: Lines 473-483
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                border: Border.all(
                  color: const Color(0xFFDDDDDD),
                  width: 1,
                ),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Column(
                children: orders.map<Widget>((order) {
                  final o = order as Map<String, dynamic>;
                  return _buildOrderCard(o);
                }).toList(),
              ),
            ),
            // Message Metadata
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    msg['senderUsername']?.toString() ?? '',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.muted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatTime(msg['timestamp']),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build individual order card
  // matches PanelChat.js: Lines 476-481
  Widget _buildOrderCard(Map<String, dynamic> order) {
    final lot = order['lot']?.toString() ?? 'New';
    final grade = order['grade']?.toString() ?? '-';
    final no = order['no']?.toString() ?? '0';
    final bagbox = order['bagbox']?.toString() ?? '';
    final kgs = order['kgs']?.toString() ?? '0';
    final price = order['price']?.toString() ?? '0';
    final brand = order['brand']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: const Color(0xFFE2E8F0),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$lot: $grade - $no $bagbox - $kgs kgs x ₹$price${brand.isNotEmpty ? ' - $brand' : ''}',
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF334155),
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Pending Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Pending',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

}


// Helper widget for buttons with hover effects matching CSS
// matches panelChat.css: .panel-action-btn - Lines 576-626
class _ButtonWithHover extends StatefulWidget {
  final String label;
  final String icon;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final bool isSecondary;
  final bool isDanger;
  final bool isDisabled;

  const _ButtonWithHover({
    required this.label,
    required this.icon,
    this.onPressed,
    this.isPrimary = false,
    this.isSecondary = false,
    this.isDanger = false,
    this.isDisabled = false,
  });

  @override
  State<_ButtonWithHover> createState() => _ButtonWithHoverState();
}

class _ButtonWithHoverState extends State<_ButtonWithHover> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor = Colors.white.withOpacity(0.8); // Default for secondary
    Color textColor;
    Gradient? gradient;
    
    if (widget.isDisabled) {
      backgroundColor = Colors.grey.withOpacity(0.3);
      textColor = Colors.grey;
    } else if (widget.isPrimary) {
      // matches panelChat.css: .panel-action-btn.primary - Lines 599-602
      gradient = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        // matches panelChat.css: linear-gradient(135deg, #3b82f6, #2563eb) - Line 600
        colors: [Color(0xFF5D6E7E), Color(0xFF2563EB)],
      );
      textColor = Colors.white;
    } else if (widget.isDanger) {
      // matches panelChat.css: .panel-action-btn.danger - Lines 610-613
      gradient = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        // matches panelChat.css: linear-gradient(135deg, #ef4444, #dc2626) - Line 611
        colors: [Color(0xFFEF4444), Color(0xFFDC2626)],
      );
      textColor = Colors.white;
    } else {
      // matches panelChat.css: .panel-action-btn.secondary - Lines 604-608
      backgroundColor = Colors.white.withOpacity(0.8);
      textColor = const Color(0xFF4B5563);
    }

    Widget buttonContent = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.icon, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 6),
        Text(
          widget.label,
          style: TextStyle(
            // matches panelChat.css: font-size: 12px, font-weight: 600 - Lines 580-581
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
      ],
    );

    // matches panelChat.css: box-shadow: 0 4px 6px rgba(0, 0, 0, 0.05) - Line 587
    // matches panelChat.css: .panel-action-btn:hover - box-shadow: 0 8px 15px rgba(0, 0, 0, 0.1) - Line 592
    final baseShadow = BoxShadow(
      color: Colors.black.withOpacity(0.05),
      blurRadius: 6,
      offset: const Offset(0, 4),
    );
    final hoverShadow = BoxShadow(
      color: Colors.black.withOpacity(0.1),
      blurRadius: 15,
      offset: const Offset(0, 8),
    );

    // matches panelChat.css: .panel-action-btn:hover - transform: translateY(-2px) - Line 591
    // matches panelChat.css: .panel-action-btn:active - transform: translateY(0) - Line 596
    final transformOffset = _isHovered && !_isPressed ? -2.0 : 0.0;
    final boxShadows = _isHovered && !widget.isDisabled
        ? [hoverShadow]
        : [baseShadow];

    // matches panelChat.css: padding: 10px 18px - Line 577
    final padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10);

    if (gradient != null) {
      return Transform.translate(
        offset: Offset(0, transformOffset),
        child: Container(
          decoration: BoxDecoration(
            gradient: gradient,
            // matches panelChat.css: border-radius: 999px - Line 579
            borderRadius: BorderRadius.circular(999),
            boxShadow: widget.isDisabled ? [] : boxShadows,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onPressed,
              onTapDown: widget.isDisabled ? null : (_) => setState(() => _isPressed = true),
              onTapUp: widget.isDisabled ? null : (_) => setState(() => _isPressed = false),
              onTapCancel: widget.isDisabled ? null : () => setState(() => _isPressed = false),
              onHover: widget.isDisabled ? null : (hovered) => setState(() => _isHovered = hovered),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: padding,
                child: Opacity(
                  opacity: widget.isDisabled ? 0.6 : 1.0,
                  child: ColorFiltered(
                    colorFilter: widget.isDisabled
                        ? const ColorFilter.mode(Colors.grey, BlendMode.saturation)
                        : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                    child: buttonContent,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      return Transform.translate(
        offset: Offset(0, transformOffset),
        child: Container(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(999),
            border: widget.isSecondary ? Border.all(
              color: const Color(0xFF94A3B8).withOpacity(0.2),
              width: 1,
            ) : null,
            boxShadow: widget.isDisabled ? [] : boxShadows,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onPressed,
              onTapDown: widget.isDisabled ? null : (_) => setState(() => _isPressed = true),
              onTapUp: widget.isDisabled ? null : (_) => setState(() => _isPressed = false),
              onTapCancel: widget.isDisabled ? null : () => setState(() => _isPressed = false),
              onHover: widget.isDisabled ? null : (hovered) => setState(() => _isHovered = hovered),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: padding,
                child: Opacity(
                  opacity: widget.isDisabled ? 0.6 : 1.0,
                  child: ColorFiltered(
                    colorFilter: widget.isDisabled
                        ? const ColorFilter.mode(Colors.grey, BlendMode.saturation)
                        : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                    child: buttonContent,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
  }
}


// Helper widget for table header cells
class _TableHeaderCell extends StatelessWidget {
  final String text;
  final double? width;

  const _TableHeaderCell(this.text, {this.width});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: SizedBox(
        width: width,
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF64748B),
          ),
        ),
      ),
    );
  }
}

class _MobilePanelWidget extends StatelessWidget {
  final Map<String, dynamic> panel;
  final bool isMe;
  final String role;
  final String status;
  final VoidCallback onBargain;
  final VoidCallback onConfirm;

  const _MobilePanelWidget({
    required this.panel,
    required this.isMe,
    required this.role,
    required this.status,
    required this.onBargain,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final items = panel['items'] as List? ?? [];
    final panelVersion = panel['panelVersion'] ?? 0;
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFF5D6E7E).withOpacity(0.85) : Colors.white.withOpacity(0.7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isMe ? Colors.white.withOpacity(0.3) : Colors.white.withOpacity(0.5), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '📋 PANEL v$panelVersion', 
                    style: TextStyle(
                      fontWeight: FontWeight.w900, 
                      fontSize: 11, 
                      color: isMe ? Colors.white : const Color(0xFF475569),
                      letterSpacing: 0.5
                    )
                  ),
                  if (isMe)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(6)),
                      child: const Text('SENT', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _PanelTable(
                items: items,
                isMe: isMe,
                isConfirmed: status == 'CONFIRMED' || status == 'CONVERTED_TO_ORDER',
              ),
              if (!isMe && status != 'CONFIRMED' && status != 'CANCELLED' && status != 'CONVERTED_TO_ORDER') ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (role == 'client' && panelVersion < 4)
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            onBargain();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF4A5568),
                            elevation: 0,
                            visualDensity: VisualDensity.compact,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Color(0xFFE2E8F0))),
                          ),
                          child: const Text('Bargain', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    if (role == 'client' && panelVersion < 4) const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(colors: [Color(0xFF5D6E7E), Color(0xFF2563EB)]),
                        ),
                        child: ElevatedButton(
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            onConfirm();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            shadowColor: Colors.transparent,
                            elevation: 0,
                            visualDensity: VisualDensity.compact,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          child: Text(role == 'client' ? 'Confirm' : 'Complete Order', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelTable extends StatelessWidget {
  final List<dynamic> items;
  final bool isMe;
  final bool isConfirmed;

  const _PanelTable({
    required this.items,
    required this.isMe,
    this.isConfirmed = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Table Header
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            color: isMe ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              _headerCell('Grade', flex: 3),
              _headerCell('Qty', flex: 2),
              _headerCell('Price', flex: 2, isLast: true),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // Table Rows
        ...items.map((item) {
          final isDeclined = item['isDeclined'] == true || (item['unitPrice'] == 0 && item['offeredKgs'] == 0);
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: isMe ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.02))),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    item['grade'] ?? '-',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isMe ? Colors.white : (isDeclined ? Colors.grey : const Color(0xFF4A5568)),
                      decoration: isDeclined ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    isDeclined ? '-' : '${item['offeredKgs']}kg',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isMe ? Colors.white.withOpacity(0.9) : (isDeclined ? Colors.grey : const Color(0xFF475569)),
                      decoration: isDeclined ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    isDeclined ? '×' : '₹${item['unitPrice']}',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: isMe ? Colors.white : (isDeclined ? Colors.grey : const Color(0xFF2563EB)),
                      decoration: isDeclined ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 8),
        // Grand Total Row
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: isMe ? Colors.white.withOpacity(0.15) : Colors.black.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Text(
                  'GRAND TOTAL',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: isMe ? Colors.white : const Color(0xFF4A5568),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '₹${_calculateTableTotal().toStringAsFixed(0)}',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: isMe ? Colors.white : const Color(0xFF2563EB),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  double _calculateTableTotal() {
    double total = 0;
    for (final item in items) {
      final isDeclined = item['isDeclined'] == true || (item['unitPrice'] == 0 && item['offeredKgs'] == 0);
      if (!isDeclined) {
        total += (double.tryParse(item['offeredKgs']?.toString() ?? '0') ?? 0) * 
                 (double.tryParse(item['unitPrice']?.toString() ?? '0') ?? 0);
      }
    }
    return total;
  }

  Widget _headerCell(String label, {int flex = 1, bool isLast = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        label.toUpperCase(),
        textAlign: isLast ? TextAlign.end : TextAlign.start,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
          color: isMe ? Colors.white.withOpacity(0.6) : const Color(0xFF94A3B8),
        ),
      ),
    );
  }
}
