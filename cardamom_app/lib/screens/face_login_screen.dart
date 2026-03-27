import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../utils/camera_low_light.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Sentient Web Network — Face Login Screen
//
// A futuristic face-login screen with an animated particle network that
// morphs into a face wireframe when a face is detected. On match the
// network flashes green and the app navigates to the dashboard instantly.
// ═══════════════════════════════════════════════════════════════════════════

// ---------------------------------------------------------------------------
// State enum
// ---------------------------------------------------------------------------

enum _LoginPhase { initializing, scanning, detected, matched, failed }

// ---------------------------------------------------------------------------
// Particle
// ---------------------------------------------------------------------------

class _Particle {
  double x, y;     // current position (screen pixels)
  double vx, vy;   // velocity
  double baseX, baseY; // idle anchor (for gentle drift)
  int? templateIdx; // non-null → this particle is part of the face template
  double lerpT;     // 0 → idle position, 1 → target position

  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    this.templateIdx,
  })  : baseX = x,
        baseY = y,
        lerpT = 0.0;
}

// ---------------------------------------------------------------------------
// Face template data (normalized offsets from face center, range -1..1)
// ---------------------------------------------------------------------------

const _kTemplatePts = 34; // must match _kFacePoints.length

const _kFacePoints = <Offset>[
  // Forehead (0-2)
  Offset(0.00, -0.88),  Offset(-0.35, -0.78), Offset(0.35, -0.78),
  // Left eyebrow (3-5)
  Offset(-0.46, -0.52), Offset(-0.32, -0.58), Offset(-0.16, -0.50),
  // Right eyebrow (6-8)
  Offset(0.16, -0.50),  Offset(0.32, -0.58),  Offset(0.46, -0.52),
  // Left eye (9-10)
  Offset(-0.36, -0.34), Offset(-0.19, -0.34),
  // Right eye (11-12)
  Offset(0.19, -0.34),  Offset(0.36, -0.34),
  // Nose (13-16)
  Offset(0.00, -0.26),  Offset(0.00, -0.06),
  Offset(-0.12, 0.00),  Offset(0.12, 0.00),
  // Upper lip (17-19)
  Offset(-0.20, 0.14),  Offset(0.00, 0.11), Offset(0.20, 0.14),
  // Lower lip (20-22)
  Offset(-0.15, 0.24),  Offset(0.00, 0.27), Offset(0.15, 0.24),
  // Jaw (23-33)
  Offset(-0.56, -0.36), Offset(-0.62, -0.12), Offset(-0.56, 0.14),
  Offset(-0.42, 0.38),  Offset(-0.22, 0.54),  Offset(0.00, 0.60),
  Offset(0.22, 0.54),   Offset(0.42, 0.38),   Offset(0.56, 0.14),
  Offset(0.62, -0.12),  Offset(0.56, -0.36),
];

const _kFaceWire = <List<int>>[
  // Jaw
  [23,24],[24,25],[25,26],[26,27],[27,28],[28,29],[29,30],[30,31],[31,32],[32,33],
  // Eyebrows
  [3,4],[4,5],[6,7],[7,8],
  // Eyes
  [9,10],[11,12],
  // Nose
  [13,14],[14,15],[14,16],[15,16],
  // Upper lip
  [17,18],[18,19],
  // Lower lip
  [20,21],[21,22],
  // Lip corners
  [17,20],[19,22],
  // Brow → eye
  [3,9],[5,10],[6,11],[8,12],
  // Nose → eyes
  [13,10],[13,11],
  // Forehead → brows
  [0,4],[0,7],[1,3],[2,8],
  // Jaw → forehead
  [23,1],[33,2],
  // Chin → lip
  [28,21],
];

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class FaceLoginScreen extends StatefulWidget {
  const FaceLoginScreen({super.key});

  @override
  State<FaceLoginScreen> createState() => _FaceLoginScreenState();
}

class _FaceLoginScreenState extends State<FaceLoginScreen>
    with TickerProviderStateMixin {

  // ── Camera ──────────────────────────────────────────────────────────────
  CameraController? _cam;
  CameraDescription? _camDesc;
  bool _camReady = false;

  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableContours: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );
  FaceMeshDetector? _meshDetector;
  FaceMeshDetector get meshDetector =>
      _meshDetector ??= FaceMeshDetector(option: FaceMeshDetectorOptions.faceMesh);

  bool _isProcessing = false;

  // ── Face matching ──────────────────────────────────────────────────────
  List<Map<String, dynamic>> _enrolledUsers = [];
  bool _isLoginInProgress = false;
  bool _hasNavigated = false;
  int _consecutiveMatches = 0;
  int _loginAttempts = 0;
  static const _kMaxLoginAttempts = 6;
  bool _inCooldown = false;

  // ── Particle system ────────────────────────────────────────────────────
  late AnimationController _animCtrl;
  final List<_Particle> _particles = [];
  static const _kTotal = 70;
  final _rng = Random();

  // ── Face tracking (screen-normalised 0-1 coordinates) ─────────────────
  double _trackedFaceCX = 0.5;
  double _trackedFaceCY = 0.4;
  double _trackedFaceSize = 0.34;
  bool _hasFacePosition = false;

  // ── Low-light detection ──────────────────────────────────────────────
  bool _isLowLight = false;
  bool _torchEnabled = false;
  int _lowLightFrameCount = 0;

  // ── State ──────────────────────────────────────────────────────────────
  _LoginPhase _phase = _LoginPhase.initializing;
  String _status = 'Initializing...';
  String? _matchedName;

  // ── Lifecycle ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 100), // long, we repeat
    )..repeat();
    _animCtrl.addListener(_tick);

    // Particles are initialised after first frame so we have screen size.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initParticles(MediaQuery.of(context).size);
      _initCamera();
      _loadEnrolledUsers();
    });
  }

  @override
  void dispose() {
    _animCtrl.removeListener(_tick);
    _animCtrl.dispose();
    _disposeCamera();
    super.dispose();
  }

  Future<void> _disposeCamera() async {
    if (_torchEnabled && _cam != null) {
      try { await disableTorch(_cam!); } catch (_) {}
    }
    try {
      if (_cam?.value.isStreamingImages ?? false) {
        await _cam!.stopImageStream();
      }
    } catch (_) {}
    _cam?.dispose();
    _faceDetector.close();
    _meshDetector?.close();
  }

  // ─────────────────────────────────────────────────────────────────────
  // Particle initialisation
  // ─────────────────────────────────────────────────────────────────────

  void _initParticles(Size sz) {
    _particles.clear();
    for (int i = 0; i < _kTotal; i++) {
      final isTemplate = i < _kTemplatePts;
      _particles.add(_Particle(
        x: _rng.nextDouble() * sz.width,
        y: _rng.nextDouble() * sz.height,
        vx: (_rng.nextDouble() - 0.5) * 1.2,
        vy: (_rng.nextDouble() - 0.5) * 1.2,
        templateIdx: isTemplate ? i : null,
      ));
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Face position tracking (camera coords → screen coords)
  // ─────────────────────────────────────────────────────────────────────

  void _updateFacePosition(Rect bbox, int imgW, int imgH) {
    final sz = MediaQuery.of(context).size;
    final rawCx = bbox.center.dx;
    final rawCy = bbox.center.dy;

    // ML Kit returns coordinates in the original image frame.
    // CameraPreview handles rotation internally.
    // For front camera: we just need to normalise + mirror horizontally.

    double normX, normY;

    if (Platform.isIOS) {
      // iOS front camera: sensor orientation 270°.
      // ML Kit applies rotation to the bounding box already when we pass
      // the correct InputImageRotation, so the coordinates are in the
      // "display" space (portrait). We just normalise and mirror X.
      //
      // After rotation: effective width = imgH, effective height = imgW
      // BUT ML Kit coords are already rotated, so use imgW/imgH as-is.
      normX = rawCx / imgW;   // left→right 0→1
      normY = rawCy / imgH;   // top→bottom 0→1
      // Front camera mirror: flip X
      normX = 1.0 - normX;
    } else {
      // Android front camera: ML Kit coords are in the raw image space.
      // CameraImage is landscape, preview is portrait.
      // The face detector with rotation0deg returns unrotated coordinates.
      // We need to rotate 90° CW: (x,y) → (H-y, x) then mirror for front cam.
      //
      // After 90° CW rotation: normX = (imgH - rawCy) / imgH, normY = rawCx / imgW
      // Then front camera mirror: normX = 1 - normX = rawCy / imgH
      normX = rawCy / imgH.toDouble();
      normY = rawCx / imgW.toDouble();
    }

    // --- Account for BoxFit.cover scaling/cropping ---
    // Camera preview is placed in a FittedBox with BoxFit.cover.
    // The preview's native aspect may differ from the screen's aspect.
    final previewW = _cam?.value.previewSize?.height ?? imgH.toDouble();
    final previewH = _cam?.value.previewSize?.width ?? imgW.toDouble();

    final scaleX = sz.width / previewW;
    final scaleY = sz.height / previewH;
    final scale = max(scaleX, scaleY);
    final renderedW = previewW * scale;
    final renderedH = previewH * scale;
    final offsetX = (renderedW - sz.width) / 2;
    final offsetY = (renderedH - sz.height) / 2;

    final screenX = (normX * renderedW - offsetX) / sz.width;
    final screenY = (normY * renderedH - offsetY) / sz.height;

    // Face size: use max bbox dimension mapped through the same scale
    final bboxMaxDim = max(bbox.width, bbox.height);
    final faceSizeNorm = (bboxMaxDim / max(imgW, imgH)) * scale *
        max(previewW, previewH) / sz.width * 0.55;

    // --- Exponential moving average for smoothness ---
    const alpha = 0.35;
    if (!_hasFacePosition) {
      // First detection: snap immediately
      _trackedFaceCX = screenX;
      _trackedFaceCY = screenY;
      _trackedFaceSize = faceSizeNorm;
      _hasFacePosition = true;
    } else {
      _trackedFaceCX = _trackedFaceCX * (1 - alpha) + screenX * alpha;
      _trackedFaceCY = _trackedFaceCY * (1 - alpha) + screenY * alpha;
      _trackedFaceSize = _trackedFaceSize * (1 - alpha) + faceSizeNorm * alpha;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Particle tick (called every animation frame ~60 fps)
  // ─────────────────────────────────────────────────────────────────────

  void _tick() {
    if (!mounted || _particles.isEmpty) return;
    final sz = MediaQuery.of(context).size;
    final faceActive = _phase == _LoginPhase.detected ||
                       _phase == _LoginPhase.matched;

    // Face template centre & radius — track actual face position
    final cx = _hasFacePosition ? _trackedFaceCX * sz.width : sz.width / 2;
    final cy = _hasFacePosition ? _trackedFaceCY * sz.height : sz.height * 0.40;
    final faceR = _hasFacePosition
        ? _trackedFaceSize * sz.width
        : sz.width * 0.34;

    for (final p in _particles) {
      if (faceActive && p.templateIdx != null) {
        // Lerp toward face template position
        final tpl = _kFacePoints[p.templateIdx!];
        final tx = cx + tpl.dx * faceR;
        final ty = cy + tpl.dy * faceR;
        p.lerpT = (p.lerpT + 0.06).clamp(0.0, 1.0);
        p.x = p.x + (tx - p.x) * p.lerpT * 0.12;
        p.y = p.y + (ty - p.y) * p.lerpT * 0.12;
      } else {
        // Fade lerp back to idle
        p.lerpT = (p.lerpT - 0.02).clamp(0.0, 1.0);

        // Gentle drift
        p.x += p.vx;
        p.y += p.vy;

        // Bounce off edges with margin
        if (p.x < 0 || p.x > sz.width) p.vx *= -1;
        if (p.y < 0 || p.y > sz.height) p.vy *= -1;
        p.x = p.x.clamp(0, sz.width);
        p.y = p.y.clamp(0, sz.height);

        // Slight random jitter
        p.vx += (_rng.nextDouble() - 0.5) * 0.08;
        p.vy += (_rng.nextDouble() - 0.5) * 0.08;
        p.vx = p.vx.clamp(-1.5, 1.5);
        p.vy = p.vy.clamp(-1.5, 1.5);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Camera
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      if (Platform.isIOS) {
        await Future.delayed(const Duration(milliseconds: 600));
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _status = 'No camera available.');
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _camDesc = front;
      _cam = CameraController(front, ResolutionPreset.medium, enableAudio: false);
      await _cam!.initialize();
      await optimizeCameraExposure(_cam!);
      if (!mounted) return;
      setState(() {
        _camReady = true;
        _phase = _LoginPhase.scanning;
        _status = 'Position your face';
      });
      _startFaceStream();
    } catch (e) {
      if (mounted) setState(() => _status = 'Camera error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Enrolled user data (fetched once)
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _loadEnrolledUsers() async {
    try {
      final resp = await ApiService().getAllUserFaceData();
      if (resp.data is List) {
        _enrolledUsers = List<Map<String, dynamic>>.from(resp.data);
      }
      if (_enrolledUsers.isEmpty && mounted) {
        setState(() => _status = 'No enrolled faces. Use password login.');
      }
    } catch (e) {
      debugPrint('[FaceLogin] Failed to load enrolled data: $e');
      if (mounted) setState(() => _status = 'Network error. Check connection.');
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Face detection stream
  // ─────────────────────────────────────────────────────────────────────

  void _startFaceStream() {
    if (_cam == null || !_cam!.value.isInitialized) return;

    _cam!.startImageStream((CameraImage image) async {
      if (_isProcessing || !mounted || _hasNavigated) return;
      _isProcessing = true;

      try {
        // Low-light detection
        final brightness = estimateFrameBrightness(image);
        if (isTooDark(brightness)) {
          _lowLightFrameCount++;
          if (_lowLightFrameCount > 5 && !_isLowLight && mounted) {
            setState(() => _isLowLight = true);
          }
          _isProcessing = false;
          return;
        }
        if (isLowLight(brightness)) {
          _lowLightFrameCount++;
          if (_lowLightFrameCount > 10 && !_isLowLight && mounted) {
            setState(() => _isLowLight = true);
          }
        } else {
          if (_lowLightFrameCount > 0) _lowLightFrameCount = 0;
          if (_isLowLight && mounted) setState(() => _isLowLight = false);
        }

        final input = _toInputImage(image);
        if (input == null) { _isProcessing = false; return; }

        final faces = await _faceDetector.processImage(input);
        if (!mounted) { _isProcessing = false; return; }

        if (faces.isEmpty) {
          _consecutiveMatches = 0;
          _hasFacePosition = false;
          if (_phase != _LoginPhase.scanning && _phase != _LoginPhase.initializing) {
            setState(() {
              _phase = _LoginPhase.scanning;
              _status = 'Position your face';
              _matchedName = null;
            });
          }
          _isProcessing = false;
          return;
        }

        // Track face position on screen
        _updateFacePosition(
          faces.first.boundingBox,
          image.width,
          image.height,
        );

        // Extract landmarks
        Map<String, double> landmarks;
        if (Platform.isIOS) {
          landmarks = _contourLandmarks(faces.first);
        } else {
          final meshes = await meshDetector.processImage(input);
          if (!mounted) { _isProcessing = false; return; }
          landmarks = meshes.isNotEmpty
              ? _meshLandmarks(meshes.first)
              : _contourLandmarks(faces.first);
        }

        if (landmarks.isEmpty) {
          _isProcessing = false;
          return;
        }

        // Update phase to detected (particles morph)
        if (_phase == _LoginPhase.scanning) {
          setState(() {
            _phase = _LoginPhase.detected;
            _status = 'Scanning...';
          });
        }

        // Local match attempt
        final match = _matchLocally(landmarks);

        if (match != null) {
          _consecutiveMatches++;

          // Require 3 consecutive frames for confidence
          if (_consecutiveMatches >= 3 &&
              !_isLoginInProgress &&
              !_inCooldown &&
              _loginAttempts < _kMaxLoginAttempts) {
            final username = match['username'] ?? '';
            final displayName = (match['fullName'] as String?)?.isNotEmpty == true
                ? match['fullName'] as String
                : username;
            _performLogin(landmarks, username, displayName);
          }
        } else {
          _consecutiveMatches = 0;
          if (_phase == _LoginPhase.detected && mounted) {
            setState(() => _status = 'Scanning...');
          }
        }
      } catch (e) {
        debugPrint('[FaceLogin] Stream error: $e');
      }

      _isProcessing = false;
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // Login
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _performLogin(Map<String, double> landmarks, String username, String displayName) async {
    if (_isLoginInProgress || _hasNavigated || !mounted || _inCooldown) return;
    _isLoginInProgress = true;
    _loginAttempts++;

    setState(() {
      _phase = _LoginPhase.matched;
      _status = 'Verifying...';
      _matchedName = displayName;
    });

    try {
      final auth = context.read<AuthProvider>();
      final success = await auth.loginWithFace(landmarks, matchedUsername: username);
      if (!mounted) return;

      if (success) {
        _hasNavigated = true;
        setState(() => _status = 'Welcome');
        final route = auth.mustChangePassword
            ? '/change_password'
            : (auth.role == 'client' ? '/client_dashboard' : '/admin_dashboard');

        Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
      } else {
        _inCooldown = true;
        final remaining = _kMaxLoginAttempts - _loginAttempts;
        setState(() {
          _phase = _LoginPhase.failed;
          _status = remaining > 0
              ? '${auth.lastError ?? 'Verification failed'}. ${remaining} attempts left.'
              : 'Too many attempts. Use password login.';
        });

        // Cooldown before allowing retry (or stay failed if max reached)
        if (remaining > 0) {
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted && !_hasNavigated) {
              _inCooldown = false;
              _consecutiveMatches = 0;
              setState(() {
                _phase = _LoginPhase.scanning;
                _status = 'Position your face';
              });
            }
          });
        }
        // If no attempts left, stay on failed screen — user must go back
      }
    } catch (e) {
      _inCooldown = true;
      if (mounted) {
        setState(() {
          _phase = _LoginPhase.failed;
          _status = 'Login error. Try again.';
        });
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted && !_hasNavigated) {
            _inCooldown = false;
            _consecutiveMatches = 0;
            setState(() {
              _phase = _LoginPhase.scanning;
              _status = 'Position your face';
            });
          }
        });
      }
    } finally {
      _isLoginInProgress = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Local face matching (reuses auth_provider algorithm)
  // ─────────────────────────────────────────────────────────────────────

  Map<String, dynamic>? _matchLocally(Map<String, double> landmarks) {
    if (_enrolledUsers.isEmpty) return null;

    double bestScore = 0;
    double secondBestScore = 0;
    String secondBestName = '';
    Map<String, dynamic>? bestMatch;
    final isMesh = landmarks.containsKey('leftEyeWidth');

    for (final enrolled in _enrolledUsers) {
      final storedData = enrolled['faceData'];
      if (storedData == null || storedData is! Map) continue;

      final stored = <String, double>{};
      for (final e in storedData.entries) {
        final v = e.value;
        if (v is num) stored[e.key.toString()] = v.toDouble();
      }
      if (stored.isEmpty) continue;

      final isStoredMesh = stored.containsKey('leftEyeWidth');

      List<String> keys;
      double threshold;

      if (isMesh && isStoredMesh) {
        keys = const [
          'leftEyeWidth','rightEyeWidth','leftEyeHeight','rightEyeHeight',
          'leftBrowWidth','rightBrowWidth','leftBrowToEye','rightBrowToEye',
          'noseLength','noseWidth','noseTipToLeftEye','noseTipToRightEye',
          'mouthWidth','mouthHeight','noseToMouth',
          'faceWidth','faceHeight','chinToMouth','foreheadToNose','foreheadToBrow',
          'eyeWidthRatio','browWidthRatio','noseToFaceWidth','mouthToFaceWidth',
        ];
        threshold = 0.95;
      } else {
        keys = const [
          'noseTipToLeftEye','noseTipToRightEye','mouthWidth','noseToMouth','faceWidth','mouthToFaceWidth',
        ];
        threshold = 0.88;
      }

      // Mean Relative Error — measures actual geometric differences.
      // Unlike cosine similarity (which returns ~0.99 for ALL faces on
      // positive vectors), MRE yields ~0.93-0.97 for same person and
      // ~0.75-0.85 for different people, making thresholds effective.
      double totalRelErr = 0;
      int matched = 0;
      for (final k in keys) {
        final a = landmarks[k];
        final b = stored[k];
        if (a == null || b == null || a == 0 || b == 0) continue;
        final mean = (a + b) / 2.0;
        if (mean > 0) {
          totalRelErr += (a - b).abs() / mean;
          matched++;
        }
      }
      // Need at least 8 common keys for mesh, 3 for contour
      final minKeys = (isMesh && isStoredMesh) ? 8 : 3;
      if (matched < minKeys) continue;

      final sim = 1.0 - (totalRelErr / matched);
      debugPrint('[FaceMatch] ${enrolled['username']}: ${(sim * 100).toStringAsFixed(1)}% (keys: $matched/${keys.length}, thr: ${(threshold * 100).toStringAsFixed(0)}%)');
      if (sim >= threshold) {
        if (sim > bestScore) {
          secondBestScore = bestScore;
          secondBestName = bestMatch != null ? (bestMatch!['username'] ?? 'unknown') : '';
          bestScore = sim;
          bestMatch = enrolled;
        } else if (sim > secondBestScore) {
          secondBestScore = sim;
          secondBestName = enrolled['username'] ?? 'unknown';
        }
      }
    }

    // Minimum margin check: best must beat second-best by at least 0.02
    if (bestMatch != null) {
      final margin = bestScore - secondBestScore;
      debugPrint('[FaceMatch] Best: ${bestMatch!['username']} ${(bestScore * 100).toStringAsFixed(1)}%');
      debugPrint('[FaceMatch] 2nd:  $secondBestName ${(secondBestScore * 100).toStringAsFixed(1)}%');
      debugPrint('[FaceMatch] Margin: ${(margin * 100).toStringAsFixed(2)}%');
      if (secondBestScore > 0 && margin < 0.02) {
        debugPrint('[FaceMatch] REJECTED — margin ${(margin * 100).toStringAsFixed(2)}% < 2.00% minimum');
        return null;
      }
      debugPrint('[FaceMatch] ACCEPTED — ${bestMatch!['username']}');
    }
    return bestMatch;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Landmark extraction (copied from face_attendance_screen.dart)
  // ─────────────────────────────────────────────────────────────────────

  Map<String, double> _meshLandmarks(FaceMesh mesh) {
    final lm = <String, double>{};
    final pts = mesh.points;
    if (pts.length < 468) return lm;

    double d(int i, int j) {
      final a = pts[i], b = pts[j];
      return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));
    }

    final lc = Point<double>(
      (pts[133].x + pts[33].x) / 2, (pts[133].y + pts[33].y) / 2);
    final rc = Point<double>(
      (pts[362].x + pts[263].x) / 2, (pts[362].y + pts[263].y) / 2);
    final ed = sqrt(pow(rc.x - lc.x, 2) + pow(rc.y - lc.y, 2));
    if (ed == 0) return lm;

    lm['leftEyeWidth']     = d(133, 33) / ed;
    lm['rightEyeWidth']    = d(362, 263) / ed;
    lm['leftEyeHeight']    = d(159, 145) / ed;
    lm['rightEyeHeight']   = d(386, 374) / ed;
    lm['leftBrowWidth']    = d(107, 70) / ed;
    lm['rightBrowWidth']   = d(336, 300) / ed;
    lm['leftBrowToEye']    = d(107, 159) / ed;
    lm['rightBrowToEye']   = d(336, 386) / ed;
    lm['noseLength']       = d(6, 1) / ed;
    lm['noseWidth']        = d(129, 358) / ed;
    lm['noseTipToLeftEye'] = d(1, 133) / ed;
    lm['noseTipToRightEye']= d(1, 362) / ed;
    lm['mouthWidth']       = d(61, 291) / ed;
    lm['mouthHeight']      = d(13, 14) / ed;
    lm['noseToMouth']      = d(2, 13) / ed;
    lm['faceWidth']        = d(234, 454) / ed;
    lm['faceHeight']       = d(10, 152) / ed;
    lm['chinToMouth']      = d(152, 14) / ed;
    lm['foreheadToNose']   = d(10, 6) / ed;
    lm['foreheadToBrow']   = d(10, 107) / ed;
    lm['eyeWidthRatio']    = lm['leftEyeWidth']! /
        (lm['rightEyeWidth']! == 0 ? 1 : lm['rightEyeWidth']!);
    lm['browWidthRatio']   = lm['leftBrowWidth']! /
        (lm['rightBrowWidth']! == 0 ? 1 : lm['rightBrowWidth']!);
    lm['noseToFaceWidth']  = lm['noseWidth']! /
        (lm['faceWidth']! == 0 ? 1 : lm['faceWidth']!);
    lm['mouthToFaceWidth'] = lm['mouthWidth']! /
        (lm['faceWidth']! == 0 ? 1 : lm['faceWidth']!);

    lm.removeWhere((_, v) => v.isNaN || v.isInfinite);
    return lm;
  }

  Map<String, double> _contourLandmarks(Face face) {
    final lm = <String, double>{};

    final le = face.contours[FaceContourType.leftEye];
    final re = face.contours[FaceContourType.rightEye];
    if (le == null || re == null) return _basicLandmarks(face);

    final lp = le.points, rp = re.points;
    if (lp.isEmpty || rp.isEmpty) return lm;

    double dist(Point<int> a, Point<int> b) =>
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

    Point<int> leftmost(List<Point<int>> s) => s.reduce((a, b) => a.x < b.x ? a : b);
    Point<int> rightmost(List<Point<int>> s) => s.reduce((a, b) => a.x > b.x ? a : b);
    Point<int> topmost(List<Point<int>> s) => s.reduce((a, b) => a.y < b.y ? a : b);
    Point<int> bottommost(List<Point<int>> s) => s.reduce((a, b) => a.y > b.y ? a : b);
    Point<double> center(List<Point<int>> s) {
      final sx = s.fold<int>(0, (v, p) => v + p.x);
      final sy = s.fold<int>(0, (v, p) => v + p.y);
      return Point<double>(sx / s.length, sy / s.length);
    }

    final lcenter = center(lp);
    final rcenter = center(rp);
    final ed = sqrt(pow(rcenter.x - lcenter.x, 2) + pow(rcenter.y - lcenter.y, 2));
    if (ed == 0) return lm;

    lm['leftEyeWidth']  = dist(leftmost(lp), rightmost(lp)) / ed;
    lm['rightEyeWidth'] = dist(leftmost(rp), rightmost(rp)) / ed;
    lm['leftEyeHeight'] = dist(topmost(lp), bottommost(lp)) / ed;
    lm['rightEyeHeight']= dist(topmost(rp), bottommost(rp)) / ed;

    final lbt = face.contours[FaceContourType.leftEyebrowTop];
    final rbt = face.contours[FaceContourType.rightEyebrowTop];
    if (lbt != null && lbt.points.length >= 2) {
      lm['leftBrowWidth']  = dist(lbt.points.first, lbt.points.last) / ed;
      lm['leftBrowToEye']  = dist(lbt.points.first, topmost(lp)) / ed;
    }
    if (rbt != null && rbt.points.length >= 2) {
      lm['rightBrowWidth'] = dist(rbt.points.first, rbt.points.last) / ed;
      lm['rightBrowToEye'] = dist(rbt.points.first, topmost(rp)) / ed;
    }

    final nb = face.contours[FaceContourType.noseBridge];
    final nbm = face.contours[FaceContourType.noseBottom];
    if (nb != null && nb.points.length >= 2 && nbm != null && nbm.points.length >= 2) {
      final tip = nbm.points[nbm.points.length ~/ 2];
      lm['noseLength'] = dist(nb.points.first, tip) / ed;
      lm['noseWidth']  = dist(nbm.points.first, nbm.points.last) / ed;
      lm['noseTipToLeftEye']  = dist(tip, rightmost(lp)) / ed;
      lm['noseTipToRightEye'] = dist(tip, leftmost(rp)) / ed;
    }

    final ult = face.contours[FaceContourType.upperLipTop];
    final llb = face.contours[FaceContourType.lowerLipBottom];
    if (ult != null && ult.points.length >= 2 && llb != null && llb.points.length >= 2) {
      lm['mouthWidth']  = dist(leftmost(ult.points), rightmost(ult.points)) / ed;
      lm['mouthHeight'] = dist(topmost(ult.points), bottommost(llb.points)) / ed;
      if (nbm != null && nbm.points.isNotEmpty) {
        lm['noseToMouth'] = dist(nbm.points[nbm.points.length ~/ 2], topmost(ult.points)) / ed;
      }
    }

    final fc = face.contours[FaceContourType.face];
    if (fc != null && fc.points.length >= 10) {
      final fp = fc.points;
      lm['faceWidth']  = dist(leftmost(fp), rightmost(fp)) / ed;
      lm['faceHeight'] = dist(topmost(fp), bottommost(fp)) / ed;
      if (llb != null && llb.points.isNotEmpty) {
        lm['chinToMouth'] = dist(bottommost(fp), bottommost(llb.points)) / ed;
      }
      if (nb != null && nb.points.isNotEmpty) {
        lm['foreheadToNose'] = dist(topmost(fp), nb.points.first) / ed;
      }
      if (lbt != null && lbt.points.isNotEmpty) {
        lm['foreheadToBrow'] = dist(topmost(fp), lbt.points.first) / ed;
      }
    }

    if (lm.containsKey('leftEyeWidth') && lm.containsKey('rightEyeWidth')) {
      lm['eyeWidthRatio'] = lm['leftEyeWidth']! /
          (lm['rightEyeWidth']! == 0 ? 1 : lm['rightEyeWidth']!);
    }
    if (lm.containsKey('leftBrowWidth') && lm.containsKey('rightBrowWidth')) {
      lm['browWidthRatio'] = lm['leftBrowWidth']! /
          (lm['rightBrowWidth']! == 0 ? 1 : lm['rightBrowWidth']!);
    }
    if (lm.containsKey('noseWidth') && lm.containsKey('faceWidth')) {
      lm['noseToFaceWidth'] = lm['noseWidth']! /
          (lm['faceWidth']! == 0 ? 1 : lm['faceWidth']!);
    }
    if (lm.containsKey('mouthWidth') && lm.containsKey('faceWidth')) {
      lm['mouthToFaceWidth'] = lm['mouthWidth']! /
          (lm['faceWidth']! == 0 ? 1 : lm['faceWidth']!);
    }

    lm.removeWhere((_, v) => v.isNaN || v.isInfinite);
    return lm;
  }

  Map<String, double> _basicLandmarks(Face face) {
    final lm = <String, double>{};
    final le = face.landmarks[FaceLandmarkType.leftEye];
    final re = face.landmarks[FaceLandmarkType.rightEye];
    if (le == null || re == null) return lm;

    double d(Point<int> a, Point<int> b) =>
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

    final ed = d(le.position, re.position);
    if (ed == 0) return lm;

    final nb = face.landmarks[FaceLandmarkType.noseBase];
    if (nb != null) {
      lm['noseTipToLeftEye']  = d(nb.position, le.position) / ed;
      lm['noseTipToRightEye'] = d(nb.position, re.position) / ed;
    }
    final lm2 = face.landmarks[FaceLandmarkType.leftMouth];
    final rm = face.landmarks[FaceLandmarkType.rightMouth];
    if (lm2 != null && rm != null) {
      lm['mouthWidth'] = d(lm2.position, rm.position) / ed;
    }
    final bm = face.landmarks[FaceLandmarkType.bottomMouth];
    if (bm != null && nb != null) {
      lm['noseToMouth'] = d(nb.position, bm.position) / ed;
    }
    final lc = face.landmarks[FaceLandmarkType.leftCheek];
    final rc = face.landmarks[FaceLandmarkType.rightCheek];
    if (lc != null && rc != null) {
      lm['faceWidth'] = d(lc.position, rc.position) / ed;
    }
    if (lm.containsKey('mouthWidth') && lm.containsKey('faceWidth')) {
      lm['mouthToFaceWidth'] = lm['mouthWidth']! /
          (lm['faceWidth']! == 0 ? 1 : lm['faceWidth']!);
    }

    lm.removeWhere((_, v) => v.isNaN || v.isInfinite);
    return lm;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Camera image → InputImage
  // ─────────────────────────────────────────────────────────────────────

  InputImage? _toInputImage(CameraImage img) {
    try {
      final buf = <int>[];
      for (final plane in img.planes) {
        buf.addAll(plane.bytes);
      }
      final bytes = Uint8List.fromList(buf);

      final InputImageFormat fmt;
      final InputImageRotation rot;
      if (Platform.isIOS) {
        fmt = InputImageFormat.bgra8888;
        final so = _camDesc?.sensorOrientation ?? 0;
        rot = InputImageRotationValue.fromRawValue(so) ??
            InputImageRotation.rotation0deg;
      } else {
        fmt = InputImageFormat.nv21;
        rot = InputImageRotation.rotation0deg;
      }

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(img.width.toDouble(), img.height.toDouble()),
          rotation: rot,
          format: fmt,
          bytesPerRow: img.planes.first.bytesPerRow,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    // Phase-based colour
    final Color netColor;
    switch (_phase) {
      case _LoginPhase.matched:
        netColor = const Color(0xFF00E676); // green
        break;
      case _LoginPhase.failed:
        netColor = const Color(0xFFEF4444); // red
        break;
      case _LoginPhase.detected:
        netColor = const Color(0xFF00E5FF); // bright cyan
        break;
      default:
        netColor = const Color(0xFF0097A7); // muted teal
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera preview (very dim) ──
          if (_camReady && _cam != null)
            Positioned.fill(
              child: Opacity(
                opacity: 0.15,
                child: ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _cam!.value.previewSize?.height ?? 1,
                      height: _cam!.value.previewSize?.width ?? 1,
                      child: CameraPreview(_cam!),
                    ),
                  ),
                ),
              ),
            ),

          // ── Particle network canvas ──
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _animCtrl,
              builder: (_, __) {
                return CustomPaint(
                  painter: _NetworkPainter(
                    particles: _particles,
                    color: netColor,
                    phase: _phase,
                    connectionDist: mq.size.width * 0.22,
                  ),
                );
              },
            ),
          ),

          // ── Top bar ──
          Positioned(
            top: mq.padding.top + 8,
            left: 4,
            right: 16,
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: Colors.white54, size: 20),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: netColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: netColor.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sensors, color: netColor, size: 14),
                      const SizedBox(width: 5),
                      Text(
                        _phase == _LoginPhase.matched ? 'VERIFIED' : 'FACE ID',
                        style: GoogleFonts.jetBrainsMono(
                          color: netColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Bottom status area ──
          Positioned(
            bottom: mq.padding.bottom + 40,
            left: 32,
            right: 32,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Status icon
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: _phase == _LoginPhase.matched
                      ? Icon(Icons.check_circle_outline, key: const ValueKey('ok'),
                          color: netColor, size: 48)
                      : _phase == _LoginPhase.failed
                          ? Icon(Icons.error_outline, key: const ValueKey('fail'),
                              color: netColor, size: 48)
                          : Icon(Icons.face_retouching_natural,
                              key: const ValueKey('scan'),
                              color: netColor.withOpacity(0.6), size: 48),
                ),
                const SizedBox(height: 16),

                // Matched name
                if (_matchedName != null && _phase == _LoginPhase.matched) ...[
                  Text(
                    _matchedName!,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],

                // Status text
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    _status,
                    key: ValueKey(_status),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.jetBrainsMono(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Scanning indicator
                if (_phase == _LoginPhase.scanning || _phase == _LoginPhase.detected)
                  SizedBox(
                    width: 120,
                    child: LinearProgressIndicator(
                      value: _phase == _LoginPhase.detected ? null : null,
                      backgroundColor: Colors.white.withOpacity(0.08),
                      color: netColor.withOpacity(0.5),
                      minHeight: 2,
                    ),
                  ),
              ],
            ),
          ),

          // ── Low-light warning banner ──
          if (_isLowLight)
            Positioned(
              bottom: 100,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.wb_sunny_outlined, color: Colors.black87, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Low light detected',
                        style: TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    GestureDetector(
                      onTap: () async {
                        if (_torchEnabled) {
                          await disableTorch(_cam!);
                          if (mounted) setState(() => _torchEnabled = false);
                        } else {
                          final ok = await enableTorchIfAvailable(_cam!);
                          if (ok) await maxExposureBoost(_cam!);
                          if (mounted) setState(() => _torchEnabled = ok);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _torchEnabled ? Colors.black26 : Colors.white24,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _torchEnabled ? 'Flash OFF' : 'Flash ON',
                          style: const TextStyle(color: Colors.black87, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Network Painter
// ═══════════════════════════════════════════════════════════════════════════

class _NetworkPainter extends CustomPainter {
  final List<_Particle> particles;
  final Color color;
  final _LoginPhase phase;
  final double connectionDist;

  _NetworkPainter({
    required this.particles,
    required this.color,
    required this.phase,
    required this.connectionDist,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (particles.isEmpty) return;

    final faceActive = phase == _LoginPhase.detected || phase == _LoginPhase.matched;
    final isMatched = phase == _LoginPhase.matched;

    // ── 1. Network connections (proximity-based) ──
    final linePaint = Paint()..strokeWidth = 0.6;

    for (int i = 0; i < particles.length; i++) {
      for (int j = i + 1; j < particles.length; j++) {
        final a = particles[i], b = particles[j];
        final dx = a.x - b.x, dy = a.y - b.y;
        final d = sqrt(dx * dx + dy * dy);

        if (d < connectionDist) {
          final opacity = (1.0 - d / connectionDist) * (faceActive ? 0.25 : 0.15);
          linePaint.color = color.withOpacity(opacity);
          canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), linePaint);
        }
      }
    }

    // ── 2. Face wireframe (explicit connections) ──
    if (faceActive && particles.length >= _kTemplatePts) {
      final wirePaint = Paint()
        ..strokeWidth = isMatched ? 2.0 : 1.2
        ..strokeCap = StrokeCap.round;

      // Glow layer
      final glowPaint = Paint()
        ..strokeWidth = isMatched ? 6.0 : 3.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

      for (final pair in _kFaceWire) {
        final a = particles[pair[0]], b = particles[pair[1]];
        final avgLerp = (a.lerpT + b.lerpT) / 2;
        final wireOpacity = avgLerp * (isMatched ? 0.9 : 0.6);

        if (wireOpacity > 0.05) {
          glowPaint.color = color.withOpacity(wireOpacity * 0.3);
          canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), glowPaint);

          wirePaint.color = color.withOpacity(wireOpacity);
          canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), wirePaint);
        }
      }
    }

    // ── 3. Particles (dots) ──
    for (final p in particles) {
      final isTemplate = p.templateIdx != null;
      final baseOpacity = faceActive && isTemplate
          ? 0.4 + p.lerpT * 0.6
          : 0.3;
      final radius = faceActive && isTemplate && p.lerpT > 0.5
          ? (isMatched ? 3.5 : 2.5)
          : 1.8;

      // Glow for high-lerp template particles
      if (isTemplate && p.lerpT > 0.3) {
        canvas.drawCircle(
          Offset(p.x, p.y),
          radius + 4,
          Paint()
            ..color = color.withOpacity(p.lerpT * 0.15)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }

      canvas.drawCircle(
        Offset(p.x, p.y),
        radius,
        Paint()..color = color.withOpacity(baseOpacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NetworkPainter old) => true; // repainted by ticker
}
