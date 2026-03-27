import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

// ═══════════════════════════════════════════════════════════════════════════
// iPhone Face ID-style Continuous Rotation Enrollment
//
// The user simply rotates their head in a slow circle. No step-by-step
// instructions. A ring of tick marks fills green as new head angles are
// captured. Landmarks are sampled at regular angular intervals and the
// element-wise median produces the final robust enrollment data.
// ═══════════════════════════════════════════════════════════════════════════

// Number of tick marks around the ring (5° each)
const _kTickCount = 72;
// Minimum head displacement from center to count as "rotated"
const _kMinDisplacement = 8.0;
// How many ticks must be green to complete (≈80%)
const _kTicksRequired = 50;
// Angular bins for landmark capture (every 30°)
const _kCaptureBins = 12;

class FaceEnrollScreen extends StatefulWidget {
  final String? enrollLabel;
  const FaceEnrollScreen({super.key, this.enrollLabel});

  @override
  State<FaceEnrollScreen> createState() => _FaceEnrollScreenState();
}

class _FaceEnrollScreenState extends State<FaceEnrollScreen>
    with TickerProviderStateMixin {

  // ── Camera ────────────────────────────────────────────────────────────
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

  // ── Continuous rotation state ─────────────────────────────────────────
  // Which tick marks (0–71) have been visited
  final List<bool> _visitedTicks = List.filled(_kTickCount, false);
  int _visitedCount = 0;
  // Landmark captures keyed by 30° bin index (0–11)
  final Map<int, Map<String, double>> _binCaptures = {};
  // Center face captured separately
  Map<String, double>? _centerCapture;
  bool _centerDone = false;

  bool _faceInView = false;
  bool _isComplete = false;
  bool _hasPopped = false;
  String _statusText = 'Initializing camera...';

  // ── Animation ─────────────────────────────────────────────────────────
  late AnimationController _pulseCtrl;

  // ── Lifecycle ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initCamera());
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _disposeCamera();
    super.dispose();
  }

  Future<void> _disposeCamera() async {
    try {
      if (_cam?.value.isStreamingImages ?? false) await _cam!.stopImageStream();
    } catch (_) {}
    _cam?.dispose();
    _faceDetector.close();
    _meshDetector?.close();
  }

  // ─────────────────────────────────────────────────────────────────────
  // Camera
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      if (Platform.isIOS) await Future.delayed(const Duration(milliseconds: 600));
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _statusText = 'No camera available');
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _camDesc = front;
      _cam = CameraController(front, ResolutionPreset.medium, enableAudio: false);
      await _cam!.initialize();
      if (!mounted) return;
      setState(() {
        _camReady = true;
        _statusText = 'Position your face in the circle';
      });
      _startFaceStream();
    } catch (e) {
      if (mounted) setState(() => _statusText = 'Camera error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Face detection stream — continuous rotation tracking
  // ─────────────────────────────────────────────────────────────────────

  void _startFaceStream() {
    if (_cam == null || !_cam!.value.isInitialized) return;

    _cam!.startImageStream((CameraImage image) async {
      if (_isProcessing || !mounted || _hasPopped || _isComplete) return;
      _isProcessing = true;

      try {
        final input = _toInputImage(image);
        if (input == null) { _isProcessing = false; return; }

        final faces = await _faceDetector.processImage(input);
        if (!mounted) { _isProcessing = false; return; }

        if (faces.isEmpty) {
          if (_faceInView) {
            setState(() {
              _faceInView = false;
              _statusText = 'Position your face in the circle';
            });
          }
          _isProcessing = false;
          return;
        }

        final face = faces.first;
        final box = face.boundingBox;
        if (box.width < 80 || box.height < 80) {
          setState(() { _faceInView = true; _statusText = 'Move closer'; });
          _isProcessing = false;
          return;
        }

        final yaw = face.headEulerAngleY ?? 0.0;
        final pitch = face.headEulerAngleX ?? 0.0;
        final displacement = sqrt(yaw * yaw + pitch * pitch);

        setState(() => _faceInView = true);

        // ── Phase 1: Capture center face ──
        if (!_centerDone) {
          if (displacement < 8) {
            final lm = await _extractLandmarks(face, input);
            if (lm != null && lm.length >= 6) {
              _centerCapture = lm;
              _centerDone = true;
              HapticFeedback.lightImpact();
              setState(() => _statusText = 'Now slowly move your head\nin a circle');
            } else {
              setState(() => _statusText = 'Look straight at the camera');
            }
          } else {
            setState(() => _statusText = 'Look straight at the camera');
          }
          _isProcessing = false;
          return;
        }

        // ── Phase 2: Continuous rotation ──
        if (displacement >= _kMinDisplacement) {
          // Map (yaw, pitch) → angle on the ring (0–2π)
          // Normalize so yaw and pitch contribute equally
          final normYaw = yaw / 30.0;
          final normPitch = pitch / 20.0;
          final poseAngle = atan2(normPitch, normYaw); // -π to π
          final poseDeg = (poseAngle * 180 / pi + 360) % 360; // 0–360

          // Mark visited ticks
          final tickIdx = (poseDeg / 360 * _kTickCount).floor() % _kTickCount;
          // Mark this tick and neighbors (±2) for smoother filling
          bool anyNew = false;
          for (int d = -2; d <= 2; d++) {
            final idx = (tickIdx + d + _kTickCount) % _kTickCount;
            if (!_visitedTicks[idx]) {
              _visitedTicks[idx] = true;
              _visitedCount++;
              anyNew = true;
            }
          }

          // Capture landmarks at 30° bin intervals
          final binIdx = (poseDeg / 360 * _kCaptureBins).floor() % _kCaptureBins;
          if (!_binCaptures.containsKey(binIdx)) {
            final lm = await _extractLandmarks(face, input);
            if (lm != null && lm.length >= 6) {
              _binCaptures[binIdx] = lm;
              HapticFeedback.selectionClick();
            }
          }

          if (anyNew) {
            setState(() => _statusText = 'Move your head slowly\nto complete the circle');

            if (_visitedCount >= _kTicksRequired && _binCaptures.length >= 4) {
              _completeEnrollment();
            }
          }
        } else {
          setState(() => _statusText = 'Move your head slowly\nto complete the circle');
        }
      } catch (e) {
        debugPrint('[FaceEnroll] Stream error: $e');
      }

      _isProcessing = false;
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // Extract landmarks from current face
  // ─────────────────────────────────────────────────────────────────────

  Future<Map<String, double>?> _extractLandmarks(Face face, InputImage input) async {
    Map<String, double> landmarks;
    if (Platform.isIOS) {
      landmarks = _contourLandmarks(face);
    } else {
      final meshes = await meshDetector.processImage(input);
      if (!mounted) return null;
      landmarks = meshes.isNotEmpty
          ? _meshLandmarks(meshes.first)
          : _contourLandmarks(face);
    }
    landmarks.remove('eyeDistance');
    if (landmarks.length < 6) return null;
    return landmarks;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Completion
  // ─────────────────────────────────────────────────────────────────────

  void _completeEnrollment() {
    if (_hasPopped) return;

    try { _cam?.stopImageStream(); } catch (_) {}

    // Merge center + all bin captures, compute median
    final allCaptures = <Map<String, double>>[];
    if (_centerCapture != null) allCaptures.add(_centerCapture!);
    allCaptures.addAll(_binCaptures.values);

    final merged = _computeMedian(allCaptures);
    if (merged.isEmpty) {
      setState(() => _statusText = 'Enrollment failed — try again');
      return;
    }

    final enrollMethod = merged.containsKey('leftEyeWidth')
        ? (Platform.isIOS ? 'contour_ios' : 'mesh_468')
        : 'landmark_basic';

    HapticFeedback.heavyImpact();

    setState(() {
      _isComplete = true;
      // Mark all ticks as visited for the full green ring effect
      for (int i = 0; i < _kTickCount; i++) _visitedTicks[i] = true;
      _visitedCount = _kTickCount;
      _statusText = 'Face enrolled!';
    });

    Future.delayed(const Duration(milliseconds: 900), () {
      if (!_hasPopped && mounted) {
        _hasPopped = true;
        Navigator.pop(context, {
          'landmarks': merged,
          'enrollMethod': 'multi_angle_$enrollMethod',
        });
      }
    });
  }

  Map<String, double> _computeMedian(List<Map<String, double>> captures) {
    final result = <String, double>{};
    final allKeys = <String>{};
    for (final m in captures) allKeys.addAll(m.keys);

    final minCount = (captures.length / 2).ceil();
    for (final key in allKeys) {
      final values = captures
          .where((m) => m.containsKey(key) && m[key] != null)
          .map((m) => m[key]!)
          .where((v) => !v.isNaN && !v.isInfinite)
          .toList();
      if (values.length >= minCount) {
        values.sort();
        result[key] = values[values.length ~/ 2];
      }
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Landmark extraction (unchanged)
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
  // Camera → InputImage
  // ─────────────────────────────────────────────────────────────────────

  InputImage? _toInputImage(CameraImage img) {
    try {
      final buf = <int>[];
      for (final plane in img.planes) buf.addAll(plane.bytes);
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
  // BUILD — Apple Face ID style: circle + tick marks
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenW = mq.size.width;
    final screenH = mq.size.height;
    final circleSize = screenW * 0.72;
    final circleCx = screenW / 2;
    final circleCy = screenH * 0.36;
    final progress = _visitedCount / _kTickCount;

    final Color primaryColor;
    if (_isComplete) {
      primaryColor = const Color(0xFF00E676);
    } else if (_faceInView && _centerDone) {
      primaryColor = const Color(0xFF00E676);
    } else if (_faceInView) {
      primaryColor = const Color(0xFF00BCD4);
    } else {
      primaryColor = Colors.white38;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera preview ──
          if (_camReady && _cam != null)
            Positioned.fill(
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

          // ── Dark circular mask ──
          Positioned.fill(
            child: CustomPaint(
              painter: _CircleMaskPainter(
                center: Offset(circleCx, circleCy),
                diameter: circleSize,
              ),
            ),
          ),

          // ── Tick marks ring ──
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (_, _) => CustomPaint(
                painter: _TickRingPainter(
                  center: Offset(circleCx, circleCy),
                  diameter: circleSize,
                  visitedTicks: _visitedTicks,
                  pulseValue: _pulseCtrl.value,
                  faceDetected: _faceInView,
                  centerDone: _centerDone,
                  isComplete: _isComplete,
                ),
              ),
            ),
          ),

          // ── Completion checkmark ──
          if (_isComplete)
            Positioned(
              left: 0, right: 0,
              top: circleCy - 30,
              child: const Center(
                child: Icon(Icons.check_circle_rounded,
                    color: Color(0xFF00E676), size: 64),
              ),
            ),

          // ── Back button ──
          Positioned(
            top: mq.padding.top + 8,
            left: 4,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_ios_new,
                  color: Colors.white54, size: 20),
            ),
          ),

          // ── ENROLL badge ──
          Positioned(
            top: mq.padding.top + 12,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: primaryColor.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.face, color: primaryColor, size: 14),
                  const SizedBox(width: 5),
                  Text('ENROLL', style: GoogleFonts.jetBrainsMono(
                    color: primaryColor, fontSize: 11,
                    fontWeight: FontWeight.w700, letterSpacing: 1.5,
                  )),
                ],
              ),
            ),
          ),

          // ── Bottom section ──
          Positioned(
            bottom: mq.padding.bottom + 40,
            left: 24, right: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Worker name
                if (widget.enrollLabel != null) ...[
                  Text(widget.enrollLabel!, style: GoogleFonts.outfit(
                    color: Colors.white, fontSize: 22,
                    fontWeight: FontWeight.w700,
                  )),
                  const SizedBox(height: 12),
                ],

                // Status text
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    _statusText,
                    key: ValueKey(_statusText),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      color: _isComplete
                          ? const Color(0xFF00E676)
                          : Colors.white.withValues(alpha: 0.85),
                      fontSize: _isComplete ? 24 : 18,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ),

                if (!_isComplete && _centerDone) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${(progress * 100).toInt()}%',
                    style: GoogleFonts.jetBrainsMono(
                      color: const Color(0xFF00E676).withValues(alpha: 0.6),
                      fontSize: 14, fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Circle mask — dark overlay with circular cutout
// ═══════════════════════════════════════════════════════════════════════════

class _CircleMaskPainter extends CustomPainter {
  final Offset center;
  final double diameter;

  _CircleMaskPainter({required this.center, required this.diameter});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCenter(center: center, width: diameter, height: diameter))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.82));
  }

  @override
  bool shouldRepaint(covariant _CircleMaskPainter old) => false;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tick ring — Apple Face ID style tick marks around the circle
// ═══════════════════════════════════════════════════════════════════════════

class _TickRingPainter extends CustomPainter {
  final Offset center;
  final double diameter;
  final List<bool> visitedTicks;
  final double pulseValue;
  final bool faceDetected;
  final bool centerDone;
  final bool isComplete;

  _TickRingPainter({
    required this.center,
    required this.diameter,
    required this.visitedTicks,
    required this.pulseValue,
    required this.faceDetected,
    required this.centerDone,
    required this.isComplete,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final radius = diameter / 2;
    final tickCount = visitedTicks.length;

    // Draw each tick mark
    for (int i = 0; i < tickCount; i++) {
      final angle = -pi / 2 + (2 * pi * i / tickCount); // Start from top
      final visited = visitedTicks[i];

      // Tick dimensions (like iPhone: small rectangles radiating outward)
      final innerR = radius + 4;
      final outerR = radius + 18;

      final x1 = center.dx + cos(angle) * innerR;
      final y1 = center.dy + sin(angle) * innerR;
      final x2 = center.dx + cos(angle) * outerR;
      final y2 = center.dy + sin(angle) * outerR;

      final paint = Paint()
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;

      if (visited) {
        // Green tick
        paint.color = const Color(0xFF00E676).withValues(
          alpha: isComplete ? 0.95 : 0.85,
        );
      } else if (centerDone) {
        // Unvisited but ready — dim white
        paint.color = Colors.white.withValues(alpha: 0.18);
      } else {
        // Before center capture — very dim
        paint.color = Colors.white.withValues(alpha: 0.08);
      }

      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
    }

    // Circle border (subtle)
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = faceDetected
          ? Colors.white.withValues(alpha: 0.2 + pulseValue * 0.1)
          : Colors.white.withValues(alpha: 0.1);

    canvas.drawCircle(center, radius, borderPaint);

    // Glow effect when face is detected
    if (faceDetected && centerDone && !isComplete) {
      canvas.drawCircle(
        center, radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = const Color(0xFF00E676).withValues(alpha: 0.08 + pulseValue * 0.04)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }

    // Bright green glow on completion
    if (isComplete) {
      canvas.drawCircle(
        center, radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..color = const Color(0xFF00E676).withValues(alpha: 0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TickRingPainter old) => true;
}
