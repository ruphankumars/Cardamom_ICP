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
import '../services/attendance_service.dart';
import '../services/auth_provider.dart';
import '../theme/app_theme.dart';

class FaceAttendanceScreen extends StatefulWidget {
  final String mode; // 'enroll' or 'rollcall'
  const FaceAttendanceScreen({Key? key, this.mode = 'rollcall'}) : super(key: key);

  @override
  State<FaceAttendanceScreen> createState() => _FaceAttendanceScreenState();
}

class _FaceAttendanceScreenState extends State<FaceAttendanceScreen>
    with TickerProviderStateMixin {
  CameraController? _cameraController;
  CameraDescription? _cameraDescription;

  // Basic face detector for real-time stream (fast, bounding box + angles)
  // Use fast mode for real-time stream — accuracy is compensated by
  // multi-frame consensus (3 consecutive matches required).
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableContours: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  // Face Mesh detector for detailed 468-point landmark extraction (Android only)
  FaceMeshDetector? _faceMeshDetector;
  FaceMeshDetector get faceMeshDetector =>
      _faceMeshDetector ??= FaceMeshDetector(option: FaceMeshDetectorOptions.faceMesh);

  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  bool _hasPopped = false; // Guard against double Navigator.pop
  List<Face> _detectedFaces = [];
  Map<String, dynamic>? _matchedWorker;
  String _statusMessage = 'Initializing camera...';
  List<Map<String, dynamic>> _enrolledFaces = [];
  List<Map<String, dynamic>> _attendanceResults = [];
  final Set<String> _markingInProgress = {}; // Debounce attendance marking
  int _frameCount = 0; // Frame throttle — process every 3rd frame

  // Multi-frame consensus: require N consecutive matches to same worker
  String? _consecutiveMatchId;
  int _consecutiveCount = 0;
  static const int _requiredConsecutiveMatches = 3;

  // Liveness state
  String _livenessStatus = '';

  // Enrollment: store latest landmarks from live stream
  // (iOS contour data only works with stream-based InputImage.fromBytes, not fromFilePath)
  Map<String, double> _latestStreamLandmarks = {};
  bool _hasValidStreamFace = false;

  // Enrollment UI animations (Apple Face ID style)
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _scanController;
  late Animation<double> _scanAnimation;
  double _enrollProgress = 0.0; // 0.0 = no face, 0.4 = detected, 1.0 = ready

  @override
  void initState() {
    super.initState();

    // Breathing pulse on circle
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // LiDAR scan sweep rotation
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
    _scanAnimation = Tween<double>(begin: 0.0, end: 2 * pi).animate(
      CurvedAnimation(parent: _scanController, curve: Curves.linear),
    );

    _initCamera();
    if (widget.mode == 'rollcall') _loadEnrolledFaces();
  }

  Future<void> _initCamera() async {
    try {
      // Brief delay to let previous screen's camera fully release (e.g. liveness screen).
      // On iOS the native AVCaptureSession needs time to tear down before a new one starts.
      if (Platform.isIOS) {
        await Future.delayed(const Duration(milliseconds: 800));
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _statusMessage = 'No camera available on this device.');
        return;
      }
      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraDescription = frontCamera;
      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() {
        _isCameraInitialized = true;
        _statusMessage = widget.mode == 'enroll'
            ? 'Position face in the frame and tap Capture'
            : 'Scanning for faces...';
      });

      // Start stream for all modes — real-time face detection is needed
      // for user feedback. On iOS enrollment, stream landmarks are captured
      // in _latestStreamLandmarks and used directly when user taps Capture
      // (avoids InputImage.fromFilePath rotation issues on iOS front camera).
      _startFaceDetection();
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Camera error: $e');
    }
  }

  Future<void> _loadEnrolledFaces() async {
    try {
      final api = ApiService();
      final response = await api.getAllFaceData();
      if (response.data is List) {
        _enrolledFaces = List<Map<String, dynamic>>.from(response.data);
        if (_enrolledFaces.isEmpty && mounted) {
          setState(() => _statusMessage = 'No enrolled faces found. Enroll workers first.');
        }
      }
    } catch (e) {
      debugPrint('Failed to load face data: $e');
      if (mounted) {
        setState(() => _statusMessage = 'Failed to load face data. Check network.');
      }
    }
  }

  void _startFaceDetection() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isProcessing || !mounted) return;

      // Frame throttle: process every 3rd frame to reduce CPU load ~66%
      _frameCount++;
      if (_frameCount % 3 != 0) return;

      _isProcessing = true;

      try {
        final inputImage = _convertCameraImage(image);
        if (inputImage == null) {
          _isProcessing = false;
          return;
        }

        // Use basic face detector for fast stream processing
        final faces = await _faceDetector.processImage(inputImage);

        if (!mounted) { _isProcessing = false; return; }

        setState(() {
          _detectedFaces = faces;
          if (faces.isEmpty) {
            if (widget.mode == 'enroll') {
              _statusMessage = 'Position your face in the circle';
              _hasValidStreamFace = false;
              _enrollProgress = 0.0;
            } else {
              _statusMessage = _enrolledFaces.isEmpty
                  ? 'No enrolled faces found. Enroll workers first.'
                  : 'No face detected. Look at the camera.';
            }
            _matchedWorker = null;
          }
        });

        // For enrollment: extract & store contour landmarks from live stream.
        // iOS contour data only available with InputImage.fromBytes, not
        // fromFilePath, so we must capture landmarks here in the stream.
        if (widget.mode == 'enroll' && faces.isNotEmpty) {
          debugPrint('[Enroll] Stream face detected, headAngleY=${faces.first.headEulerAngleY?.toStringAsFixed(1)}, headAngleZ=${faces.first.headEulerAngleZ?.toStringAsFixed(1)}');
          final streamLandmarks = _extractContourLandmarks(faces.first);
          debugPrint('[Enroll] Extracted ${streamLandmarks.length} landmarks: ${streamLandmarks.keys.toList()}');
          if (mounted) {
            setState(() {
              _latestStreamLandmarks = streamLandmarks;
              _hasValidStreamFace = streamLandmarks.length >= 6;
              if (_hasValidStreamFace) {
                _statusMessage = 'Face captured';
                _enrollProgress = 1.0;
              } else {
                _statusMessage = 'Hold still...';
                _enrollProgress = 0.4;
              }
            });
          }
        }

        // Extract landmarks and match against enrolled faces
        if (faces.isNotEmpty && _enrolledFaces.isNotEmpty) {
          Map<String, double> landmarks;

          if (Platform.isIOS) {
            // iOS: Use contour-based extraction (mesh not supported)
            landmarks = _extractContourLandmarks(faces.first);
          } else {
            // Android: Use 468-point mesh
            final meshes = await faceMeshDetector.processImage(inputImage);
            if (!mounted) { _isProcessing = false; return; }
            if (meshes.isNotEmpty) {
              landmarks = _extractMeshLandmarks(meshes.first);
            } else {
              landmarks = _extractContourLandmarks(faces.first);
            }
          }

          if (landmarks.isNotEmpty) {
            final match = _findBestMatch(landmarks);
            if (match != null && mounted) {
              final matchId = match['workerId']?.toString() ?? '';

              // Multi-frame consensus: require N consecutive matches
              if (_consecutiveMatchId == matchId) {
                _consecutiveCount++;
              } else {
                _consecutiveMatchId = matchId;
                _consecutiveCount = 1;
              }

              final score = match['matchScore'] as double? ?? 0;
              setState(() {
                _matchedWorker = match;
                _statusMessage = _consecutiveCount >= _requiredConsecutiveMatches
                    ? 'Matched: ${match['workerName']}'
                    : 'Verifying... ${match['workerName']} (${_consecutiveCount}/$_requiredConsecutiveMatches)';
              });

              // Only mark attendance after N consecutive matches to same person
              if (_consecutiveCount >= _requiredConsecutiveMatches) {
                _markAttendance(match);
              }
            } else if (mounted) {
              // Reset consensus on no-match
              _consecutiveMatchId = null;
              _consecutiveCount = 0;
              setState(() {
                _matchedWorker = null;
                _statusMessage = 'Face detected but no match found.';
              });
            }
          }
        }
      } catch (e) {
        debugPrint('Face detection error: $e');
      }

      _isProcessing = false;
    });
  }

  InputImage? _convertCameraImage(CameraImage image) {
    try {
      final allBytes = _WriteBuffer();
      for (final plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      // Platform-aware format and rotation
      final InputImageFormat format;
      final InputImageRotation rotation;

      if (Platform.isIOS) {
        format = InputImageFormat.bgra8888;
        // iOS front camera sensorOrientation is typically 270
        final sensorOrientation = _cameraDescription?.sensorOrientation ?? 0;
        rotation = InputImageRotationValue.fromRawValue(sensorOrientation)
            ?? InputImageRotation.rotation0deg;
      } else {
        format = InputImageFormat.nv21;
        rotation = InputImageRotation.rotation0deg;
      }

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );
    } catch (e) {
      return null;
    }
  }

  /// Extract rich landmarks from 468-point Face Mesh
  /// Uses key facial geometry points for robust identification
  Map<String, double> _extractMeshLandmarks(FaceMesh mesh) {
    final landmarks = <String, double>{};
    final points = mesh.points;

    if (points.length < 468) return landmarks;

    // Key Face Mesh indices (Google MediaPipe canonical face mesh)
    // Eyes
    const leftEyeInner = 133;
    const leftEyeOuter = 33;
    const rightEyeInner = 362;
    const rightEyeOuter = 263;
    const leftEyeTop = 159;
    const leftEyeBottom = 145;
    const rightEyeTop = 386;
    const rightEyeBottom = 374;

    // Eyebrows
    const leftBrowInner = 107;
    const leftBrowOuter = 70;
    const rightBrowInner = 336;
    const rightBrowOuter = 300;

    // Nose
    const noseTip = 1;
    const noseBottom = 2;
    const noseLeftAlar = 129;
    const noseRightAlar = 358;
    const noseBridge = 6;

    // Lips / Mouth
    const upperLipTop = 13;
    const lowerLipBottom = 14;
    const mouthLeft = 61;
    const mouthRight = 291;

    // Jaw / Face outline
    const chin = 152;
    const leftCheek = 234;
    const rightCheek = 454;
    const foreheadCenter = 10;

    // Helper: distance between two mesh points
    double dist(int i, int j) {
      final p1 = points[i];
      final p2 = points[j];
      return sqrt(pow(p1.x - p2.x, 2) + pow(p1.y - p2.y, 2));
    }

    // Baseline: inter-eye distance for normalization
    final leftEyeCenter = Point<double>(
      (points[leftEyeInner].x + points[leftEyeOuter].x) / 2,
      (points[leftEyeInner].y + points[leftEyeOuter].y) / 2,
    );
    final rightEyeCenter = Point<double>(
      (points[rightEyeInner].x + points[rightEyeOuter].x) / 2,
      (points[rightEyeInner].y + points[rightEyeOuter].y) / 2,
    );
    final eyeDist = sqrt(
      pow(rightEyeCenter.x - leftEyeCenter.x, 2) +
      pow(rightEyeCenter.y - leftEyeCenter.y, 2),
    );

    if (eyeDist == 0) return landmarks;

    // === RATIO-BASED LANDMARKS (scale-invariant, 20+ dimensions) ===

    // 1. Eye geometry
    landmarks['leftEyeWidth'] = dist(leftEyeInner, leftEyeOuter) / eyeDist;
    landmarks['rightEyeWidth'] = dist(rightEyeInner, rightEyeOuter) / eyeDist;
    landmarks['leftEyeHeight'] = dist(leftEyeTop, leftEyeBottom) / eyeDist;
    landmarks['rightEyeHeight'] = dist(rightEyeTop, rightEyeBottom) / eyeDist;

    // 2. Eyebrow geometry
    landmarks['leftBrowWidth'] = dist(leftBrowInner, leftBrowOuter) / eyeDist;
    landmarks['rightBrowWidth'] = dist(rightBrowInner, rightBrowOuter) / eyeDist;
    landmarks['leftBrowToEye'] = dist(leftBrowInner, leftEyeTop) / eyeDist;
    landmarks['rightBrowToEye'] = dist(rightBrowInner, rightEyeTop) / eyeDist;

    // 3. Nose geometry
    landmarks['noseLength'] = dist(noseBridge, noseTip) / eyeDist;
    landmarks['noseWidth'] = dist(noseLeftAlar, noseRightAlar) / eyeDist;
    landmarks['noseTipToLeftEye'] = dist(noseTip, leftEyeInner) / eyeDist;
    landmarks['noseTipToRightEye'] = dist(noseTip, rightEyeInner) / eyeDist;

    // 4. Mouth geometry
    landmarks['mouthWidth'] = dist(mouthLeft, mouthRight) / eyeDist;
    landmarks['mouthHeight'] = dist(upperLipTop, lowerLipBottom) / eyeDist;
    landmarks['noseToMouth'] = dist(noseBottom, upperLipTop) / eyeDist;

    // 5. Face proportions
    landmarks['faceWidth'] = dist(leftCheek, rightCheek) / eyeDist;
    landmarks['faceHeight'] = dist(foreheadCenter, chin) / eyeDist;
    landmarks['chinToMouth'] = dist(chin, lowerLipBottom) / eyeDist;
    landmarks['foreheadToNose'] = dist(foreheadCenter, noseBridge) / eyeDist;
    landmarks['foreheadToBrow'] = dist(foreheadCenter, leftBrowInner) / eyeDist;

    // 6. Symmetry ratios (left vs right)
    landmarks['eyeWidthRatio'] = landmarks['leftEyeWidth']! /
        (landmarks['rightEyeWidth']! == 0 ? 1 : landmarks['rightEyeWidth']!);
    landmarks['browWidthRatio'] = landmarks['leftBrowWidth']! /
        (landmarks['rightBrowWidth']! == 0 ? 1 : landmarks['rightBrowWidth']!);

    // 7. Cross-feature ratios
    landmarks['noseToFaceWidth'] = landmarks['noseWidth']! /
        (landmarks['faceWidth']! == 0 ? 1 : landmarks['faceWidth']!);
    landmarks['mouthToFaceWidth'] = landmarks['mouthWidth']! /
        (landmarks['faceWidth']! == 0 ? 1 : landmarks['faceWidth']!);

    // Sanitize: remove any NaN or Infinity values
    landmarks.removeWhere((_, v) => v.isNaN || v.isInfinite);

    return landmarks;
  }

  /// Extract landmarks using FaceLandmarkType points (guaranteed to work on
  /// all platforms and all InputImage types, including fromFilePath on iOS).
  /// Produces 10-15 ratio-based measurements using the 10 FaceLandmark points.
  Map<String, double> _extractFaceLandmarkRatios(Face face) {
    final lm = <String, double>{};

    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    final noseBase = face.landmarks[FaceLandmarkType.noseBase];
    final leftMouth = face.landmarks[FaceLandmarkType.leftMouth];
    final rightMouth = face.landmarks[FaceLandmarkType.rightMouth];
    final bottomMouth = face.landmarks[FaceLandmarkType.bottomMouth];
    final leftCheek = face.landmarks[FaceLandmarkType.leftCheek];
    final rightCheek = face.landmarks[FaceLandmarkType.rightCheek];
    final leftEar = face.landmarks[FaceLandmarkType.leftEar];
    final rightEar = face.landmarks[FaceLandmarkType.rightEar];

    if (leftEye == null || rightEye == null) return lm;

    double dist(Point<int> a, Point<int> b) =>
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

    final eyeDist = dist(leftEye.position, rightEye.position);
    if (eyeDist == 0) return lm;

    // Nose → eye distances (same keys as contour method for cross-matching)
    if (noseBase != null) {
      lm['noseTipToLeftEye'] = dist(noseBase.position, leftEye.position) / eyeDist;
      lm['noseTipToRightEye'] = dist(noseBase.position, rightEye.position) / eyeDist;
    }

    // Mouth geometry
    if (leftMouth != null && rightMouth != null) {
      lm['mouthWidth'] = dist(leftMouth.position, rightMouth.position) / eyeDist;
    }
    if (bottomMouth != null && noseBase != null) {
      lm['noseToMouth'] = dist(noseBase.position, bottomMouth.position) / eyeDist;
    }

    // Face width (cheek-to-cheek)
    if (leftCheek != null && rightCheek != null) {
      lm['faceWidth'] = dist(leftCheek.position, rightCheek.position) / eyeDist;
    }

    // Ear-to-eye (skull width proxy)
    if (leftEar != null) {
      lm['leftEarToEye'] = dist(leftEar.position, leftEye.position) / eyeDist;
    }
    if (rightEar != null) {
      lm['rightEarToEye'] = dist(rightEar.position, rightEye.position) / eyeDist;
    }

    // Eye-to-mouth distances
    if (leftMouth != null) {
      lm['leftEyeToMouth'] = dist(leftEye.position, leftMouth.position) / eyeDist;
    }
    if (rightMouth != null) {
      lm['rightEyeToMouth'] = dist(rightEye.position, rightMouth.position) / eyeDist;
    }

    // Chin / bottom mouth to eyes
    if (bottomMouth != null) {
      lm['leftEyeToChin'] = dist(leftEye.position, bottomMouth.position) / eyeDist;
      lm['rightEyeToChin'] = dist(rightEye.position, bottomMouth.position) / eyeDist;
    }

    // Nose to cheek
    if (noseBase != null && leftCheek != null) {
      lm['noseToLeftCheek'] = dist(noseBase.position, leftCheek.position) / eyeDist;
    }
    if (noseBase != null && rightCheek != null) {
      lm['noseToRightCheek'] = dist(noseBase.position, rightCheek.position) / eyeDist;
    }

    // Cross-feature ratios (matching keys with contour method)
    if (lm.containsKey('mouthWidth') && lm.containsKey('faceWidth')) {
      lm['mouthToFaceWidth'] = lm['mouthWidth']! /
          (lm['faceWidth']! == 0 ? 1 : lm['faceWidth']!);
    }

    lm.removeWhere((_, v) => v.isNaN || v.isInfinite);
    return lm;
  }

  /// Extract rich landmarks from FaceDetector contours (iOS-compatible).
  /// Falls back to [_extractFaceLandmarkRatios] if contours are unavailable.
  Map<String, double> _extractContourLandmarks(Face face) {
    final landmarks = <String, double>{};

    final leftEyeContour = face.contours[FaceContourType.leftEye];
    final rightEyeContour = face.contours[FaceContourType.rightEye];
    final leftBrowTop = face.contours[FaceContourType.leftEyebrowTop];
    final rightBrowTop = face.contours[FaceContourType.rightEyebrowTop];
    final noseBridge = face.contours[FaceContourType.noseBridge];
    final noseBottom = face.contours[FaceContourType.noseBottom];
    final upperLipTop = face.contours[FaceContourType.upperLipTop];
    final lowerLipBottom = face.contours[FaceContourType.lowerLipBottom];
    final faceContour = face.contours[FaceContourType.face];

    // If eye contours are null, fall back to basic FaceLandmark points
    if (leftEyeContour == null || rightEyeContour == null) {
      return _extractFaceLandmarkRatios(face);
    }

    final leftEyePts = leftEyeContour.points;
    final rightEyePts = rightEyeContour.points;

    if (leftEyePts.isEmpty || rightEyePts.isEmpty) return landmarks;

    // Helper: distance between two Points
    double dist(Point<int> a, Point<int> b) {
      return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));
    }

    // Helper: bounding extremes of a contour
    Point<int> leftmost(List<Point<int>> pts) =>
        pts.reduce((a, b) => a.x < b.x ? a : b);
    Point<int> rightmost(List<Point<int>> pts) =>
        pts.reduce((a, b) => a.x > b.x ? a : b);
    Point<int> topmost(List<Point<int>> pts) =>
        pts.reduce((a, b) => a.y < b.y ? a : b);
    Point<int> bottommost(List<Point<int>> pts) =>
        pts.reduce((a, b) => a.y > b.y ? a : b);
    Point<double> center(List<Point<int>> pts) {
      final sx = pts.fold<int>(0, (s, p) => s + p.x);
      final sy = pts.fold<int>(0, (s, p) => s + p.y);
      return Point<double>(sx / pts.length, sy / pts.length);
    }

    // Baseline: inter-eye distance (center of each eye contour)
    final leftEyeCenter = center(leftEyePts);
    final rightEyeCenter = center(rightEyePts);
    final eyeDist = sqrt(
      pow(rightEyeCenter.x - leftEyeCenter.x, 2) +
      pow(rightEyeCenter.y - leftEyeCenter.y, 2),
    );
    if (eyeDist == 0) return landmarks;

    // 1. Eye geometry
    final leftEyeW = dist(leftmost(leftEyePts), rightmost(leftEyePts));
    final leftEyeH = dist(topmost(leftEyePts), bottommost(leftEyePts));
    final rightEyeW = dist(leftmost(rightEyePts), rightmost(rightEyePts));
    final rightEyeH = dist(topmost(rightEyePts), bottommost(rightEyePts));
    landmarks['leftEyeWidth'] = leftEyeW / eyeDist;
    landmarks['rightEyeWidth'] = rightEyeW / eyeDist;
    landmarks['leftEyeHeight'] = leftEyeH / eyeDist;
    landmarks['rightEyeHeight'] = rightEyeH / eyeDist;

    // 2. Eyebrow geometry
    if (leftBrowTop != null && leftBrowTop.points.length >= 2) {
      final lbPts = leftBrowTop.points;
      landmarks['leftBrowWidth'] = dist(lbPts.first, lbPts.last) / eyeDist;
      landmarks['leftBrowToEye'] = dist(lbPts.first, topmost(leftEyePts)) / eyeDist;
    }
    if (rightBrowTop != null && rightBrowTop.points.length >= 2) {
      final rbPts = rightBrowTop.points;
      landmarks['rightBrowWidth'] = dist(rbPts.first, rbPts.last) / eyeDist;
      landmarks['rightBrowToEye'] = dist(rbPts.first, topmost(rightEyePts)) / eyeDist;
    }

    // 3. Nose geometry
    if (noseBridge != null && noseBridge.points.length >= 2 &&
        noseBottom != null && noseBottom.points.length >= 2) {
      final bridgeTop = noseBridge.points.first;
      final noseTip = noseBottom.points[noseBottom.points.length ~/ 2]; // center point
      final noseLeft = noseBottom.points.first;
      final noseRight = noseBottom.points.last;

      landmarks['noseLength'] = dist(bridgeTop, noseTip) / eyeDist;
      landmarks['noseWidth'] = dist(noseLeft, noseRight) / eyeDist;

      // Nose tip to each eye inner
      final leftEyeInner = rightmost(leftEyePts); // inner = rightmost for left eye
      final rightEyeInner = leftmost(rightEyePts); // inner = leftmost for right eye
      landmarks['noseTipToLeftEye'] = dist(noseTip, leftEyeInner) / eyeDist;
      landmarks['noseTipToRightEye'] = dist(noseTip, rightEyeInner) / eyeDist;
    }

    // 4. Mouth geometry
    if (upperLipTop != null && upperLipTop.points.length >= 2 &&
        lowerLipBottom != null && lowerLipBottom.points.length >= 2) {
      final mouthL = leftmost(upperLipTop.points);
      final mouthR = rightmost(upperLipTop.points);
      final lipTop = topmost(upperLipTop.points);
      final lipBottom = bottommost(lowerLipBottom.points);

      landmarks['mouthWidth'] = dist(mouthL, mouthR) / eyeDist;
      landmarks['mouthHeight'] = dist(lipTop, lipBottom) / eyeDist;

      // Nose to mouth
      if (noseBottom != null && noseBottom.points.isNotEmpty) {
        landmarks['noseToMouth'] = dist(
          noseBottom.points[noseBottom.points.length ~/ 2],
          lipTop,
        ) / eyeDist;
      }
    }

    // 5. Face proportions
    if (faceContour != null && faceContour.points.length >= 10) {
      final facePts = faceContour.points;
      final faceL = leftmost(facePts);
      final faceR = rightmost(facePts);
      final faceT = topmost(facePts);
      final faceB = bottommost(facePts); // chin
      landmarks['faceWidth'] = dist(faceL, faceR) / eyeDist;
      landmarks['faceHeight'] = dist(faceT, faceB) / eyeDist;

      // Chin to mouth
      if (lowerLipBottom != null && lowerLipBottom.points.isNotEmpty) {
        landmarks['chinToMouth'] = dist(faceB, bottommost(lowerLipBottom.points)) / eyeDist;
      }

      // Forehead (top of face) to nose
      if (noseBridge != null && noseBridge.points.isNotEmpty) {
        landmarks['foreheadToNose'] = dist(faceT, noseBridge.points.first) / eyeDist;
      }

      // Forehead to brow
      if (leftBrowTop != null && leftBrowTop.points.isNotEmpty) {
        landmarks['foreheadToBrow'] = dist(faceT, leftBrowTop.points.first) / eyeDist;
      }
    }

    // 6. Symmetry ratios
    if (landmarks.containsKey('leftEyeWidth') && landmarks.containsKey('rightEyeWidth')) {
      landmarks['eyeWidthRatio'] = landmarks['leftEyeWidth']! /
          (landmarks['rightEyeWidth']! == 0 ? 1 : landmarks['rightEyeWidth']!);
    }
    if (landmarks.containsKey('leftBrowWidth') && landmarks.containsKey('rightBrowWidth')) {
      landmarks['browWidthRatio'] = landmarks['leftBrowWidth']! /
          (landmarks['rightBrowWidth']! == 0 ? 1 : landmarks['rightBrowWidth']!);
    }

    // 7. Cross-feature ratios
    if (landmarks.containsKey('noseWidth') && landmarks.containsKey('faceWidth')) {
      landmarks['noseToFaceWidth'] = landmarks['noseWidth']! /
          (landmarks['faceWidth']! == 0 ? 1 : landmarks['faceWidth']!);
    }
    if (landmarks.containsKey('mouthWidth') && landmarks.containsKey('faceWidth')) {
      landmarks['mouthToFaceWidth'] = landmarks['mouthWidth']! /
          (landmarks['faceWidth']! == 0 ? 1 : landmarks['faceWidth']!);
    }

    // Sanitize
    landmarks.removeWhere((_, v) => v.isNaN || v.isInfinite);

    return landmarks;
  }

  /// Enhanced matching using 20+ landmarks with backward compatibility
  Map<String, dynamic>? _findBestMatch(Map<String, double> landmarks) {
    if (_enrolledFaces.isEmpty) return null;

    double bestScore = 0;
    Map<String, dynamic>? bestMatch;

    // Determine data richness of current scan
    final isMeshScan = landmarks.containsKey('leftEyeWidth');
    final isLandmarkScan = landmarks.containsKey('noseTipToLeftEye');

    // Keys produced by _extractFaceLandmarkRatios (shared with contour method)
    const basicLandmarkKeys = [
      'noseTipToLeftEye', 'noseTipToRightEye', 'mouthWidth', 'noseToMouth',
      'faceWidth', 'leftEarToEye', 'rightEarToEye', 'leftEyeToMouth',
      'rightEyeToMouth', 'leftEyeToChin', 'rightEyeToChin',
      'noseToLeftCheek', 'noseToRightCheek', 'mouthToFaceWidth',
    ];

    for (final enrolled in _enrolledFaces) {
      final storedLandmarks = Map<String, double>.from(
        (enrolled['faceData'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
        ) ?? {},
      );

      // Strip eyeDistance from older enrolled data (raw pixel value, not useful)
      storedLandmarks.remove('eyeDistance');
      if (storedLandmarks.isEmpty) continue;

      final isStoredMesh = storedLandmarks.containsKey('leftEyeWidth');
      final isStoredLandmark = storedLandmarks.containsKey('noseTipToLeftEye');

      // Choose comparison keys based on data available
      List<String> compareKeys;
      double threshold;
      String matchMethod;

      if (isMeshScan && isStoredMesh) {
        // Both have full contour/mesh data (20+ dimensions)
        compareKeys = [
          'leftEyeWidth', 'rightEyeWidth', 'leftEyeHeight', 'rightEyeHeight',
          'leftBrowWidth', 'rightBrowWidth', 'leftBrowToEye', 'rightBrowToEye',
          'noseLength', 'noseWidth', 'noseTipToLeftEye', 'noseTipToRightEye',
          'mouthWidth', 'mouthHeight', 'noseToMouth',
          'faceWidth', 'faceHeight', 'chinToMouth', 'foreheadToNose', 'foreheadToBrow',
          'eyeWidthRatio', 'browWidthRatio', 'noseToFaceWidth', 'mouthToFaceWidth',
        ];
        threshold = 0.95;
        matchMethod = 'mesh_468';
      } else if ((isMeshScan || isLandmarkScan) && (isStoredMesh || isStoredLandmark)) {
        // At least one side has modern data — use overlapping keys dynamically
        final overlapping = basicLandmarkKeys
            .where((k) => landmarks.containsKey(k) && storedLandmarks.containsKey(k))
            .toList();
        // Also add contour keys that both might share
        for (final k in ['mouthWidth', 'noseToMouth', 'faceWidth', 'mouthToFaceWidth',
            'noseTipToLeftEye', 'noseTipToRightEye']) {
          if (!overlapping.contains(k) &&
              landmarks.containsKey(k) && storedLandmarks.containsKey(k)) {
            overlapping.add(k);
          }
        }
        if (overlapping.length < 3) continue; // Not enough data to compare
        compareKeys = overlapping;
        threshold = 0.92;
        matchMethod = 'landmark_basic';
      } else {
        // Legacy: fallback to basic landmark comparison
        compareKeys = ['noseTipToLeftEye', 'noseTipToRightEye', 'mouthWidth', 'noseToMouth', 'faceWidth', 'mouthToFaceWidth'];
        threshold = 0.90;
        matchMethod = 'legacy_basic';
      }

      // Mean Relative Error — measures actual geometric differences.
      // Cosine similarity returns ~0.99 for ALL faces on positive vectors,
      // making it useless. MRE yields ~0.93-0.97 for same person and
      // ~0.75-0.85 for different people, making thresholds effective.
      double totalRelErr = 0;
      int matchedKeys = 0;

      for (final key in compareKeys) {
        final a = landmarks[key];
        final b = storedLandmarks[key];
        if (a == null || b == null || a == 0 || b == 0) continue;
        final mean = (a + b) / 2.0;
        if (mean > 0) {
          totalRelErr += (a - b).abs() / mean;
          matchedKeys++;
        }
      }

      final isMeshBoth = isMeshScan && isStoredMesh;
      final minKeys = isMeshBoth ? 8 : 3;
      if (matchedKeys < minKeys) continue;

      final similarity = 1.0 - (totalRelErr / matchedKeys);

      if (similarity > bestScore && similarity >= threshold) {
        bestScore = similarity;
        bestMatch = {
          ...enrolled,
          'matchScore': similarity,
          'matchPercent': '${(similarity * 100).toStringAsFixed(1)}%',
          'matchMethod': matchMethod,
        };
      }
    }

    return bestMatch;
  }

  Future<void> _markAttendance(Map<String, dynamic> worker) async {
    final workerId = worker['workerId'] as String;

    // Debounce: skip if already marking this worker
    if (_markingInProgress.contains(workerId)) return;

    // Allow same worker to scan twice (entry + exit), but not more than twice
    final existingScans = _attendanceResults.where((r) => r['workerId'] == workerId).length;
    if (existingScans >= 2) return; // Already has entry + exit

    // If already scanned once (entry), require a cooldown before exit scan (minimum 1 minute)
    if (existingScans == 1) {
      final firstScan = _attendanceResults.where((r) => r['workerId'] == workerId).firstOrNull;
      if (firstScan != null) {
        final firstTime = DateTime.tryParse(firstScan['time'] ?? '');
        if (firstTime != null && DateTime.now().difference(firstTime).inMinutes < 1) {
          return; // Too soon for exit scan
        }
      }
    }

    _markingInProgress.add(workerId);
    try {
      final service = Provider.of<AttendanceService>(context, listen: false);
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final scanTime = DateTime.now();

      final markedBy = auth.username ?? 'manager';

      final response = await service.registerFaceScan(
        workerId: workerId,
        workerName: worker['workerName'],
        scanTime: scanTime,
        markedBy: markedBy,
      );

      if (!mounted) return;

      // Determine what the sync result was
      String syncStateText = existingScans == 0 ? 'Entry Recorded' : 'Exit Recorded';
      if (response['offline'] == true) {
         syncStateText = 'Saved Offline';
      } else if (response['attendance'] != null) {
         final att = response['attendance'];
         if (att['checkOutTime'] != null) {
            syncStateText = 'Exit Recorded';
         }
      }

      setState(() {
        _attendanceResults.add({
          'workerId': workerId,
          'workerName': worker['workerName'],
          'matchPercent': worker['matchPercent'],
          'matchMethod': worker['matchMethod'] ?? 'unknown',
          'syncStateText': syncStateText,
          'time': scanTime.toIso8601String(),
        });
      });
    } catch (e) {
      debugPrint('Failed to mark attendance: $e');
    } finally {
      _markingInProgress.remove(workerId);
    }
  }

  /// Safely pop with enrollment result, guarded against double-pop.
  void _popWithResult(Map<String, dynamic> result) {
    if (_hasPopped || !mounted) return;
    _hasPopped = true;
    Navigator.pop(context, result);
  }

  /// Validate that a face is suitable for enrollment:
  /// - Head pose is roughly frontal (not tilted/rotated too far)
  /// - Face bounding box is large enough for reliable extraction
  String? _validateFaceForEnrollment(Face face) {
    // Head rotation check (Y = left/right turn, Z = tilt)
    final angleY = face.headEulerAngleY ?? 0;
    final angleZ = face.headEulerAngleZ ?? 0;
    if (angleY.abs() > 25) {
      return 'Turn your head to face the camera directly.';
    }
    if (angleZ.abs() > 15) {
      return 'Keep your head straight (not tilted).';
    }

    // Face size check (bounding box should be reasonably large)
    final box = face.boundingBox;
    if (box.width < 80 || box.height < 80) {
      return 'Move closer to the camera.';
    }

    return null; // Face is valid
  }

  Future<void> _captureForEnrollment() async {
    if (_hasPopped) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      if (mounted) {
        setState(() => _statusMessage = 'Camera not ready. Wait a moment.');
      }
      return;
    }

    // ------------------------------------------------------------------
    // iOS: use stream-captured landmarks (InputImage.fromBytes in the
    // stream handles rotation correctly; fromFilePath often fails on
    // the iOS front camera due to EXIF rotation issues).
    // ------------------------------------------------------------------
    if (Platform.isIOS) {
      if (!_hasValidStreamFace || _latestStreamLandmarks.isEmpty) {
        setState(() {
          _statusMessage = 'No face detected. Look at the camera and try again.';
          _isProcessing = false;
        });
        return;
      }

      setState(() {
        _isProcessing = true;
        _statusMessage = 'Processing...';
      });

      final landmarks = Map<String, double>.from(_latestStreamLandmarks);
      final enrollMethod = landmarks.containsKey('leftEyeWidth')
          ? 'contour_ios'
          : landmarks.isNotEmpty
              ? 'landmark_ios'
              : 'failed';

      // Need at least 6 meaningful dimensions for reliable matching
      final usefulKeys = landmarks.length - (landmarks.containsKey('eyeDistance') ? 1 : 0);
      if (usefulKeys < 6) {
        setState(() {
          _statusMessage = 'Could not extract enough face data ($usefulKeys points). Try again.';
          _isProcessing = false;
        });
        return;
      }

      // Strip eyeDistance — raw pixel value varies with camera distance/resolution
      landmarks.remove('eyeDistance');

      _popWithResult({
        'landmarks': landmarks,
        'enrollMethod': enrollMethod,
      });
      return;
    }

    // ------------------------------------------------------------------
    // Android: use still-image 468-point mesh extraction (works from file).
    // ------------------------------------------------------------------
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Processing face mesh...';
    });

    try {
      // Stop stream before taking picture
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      if (!mounted || _hasPopped) return;

      final image = await _cameraController!.takePicture();
      if (!mounted || _hasPopped) return;

      final inputImage = InputImage.fromFilePath(image.path);
      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted || _hasPopped) return;

      if (faces.isEmpty) {
        setState(() {
          _statusMessage = 'No face detected. Try again.';
          _isProcessing = false;
        });
        if (mounted) _startFaceDetection();
        return;
      }

      if (faces.length > 1) {
        setState(() {
          _statusMessage = 'Multiple faces detected. Only one face allowed.';
          _isProcessing = false;
        });
        if (mounted) _startFaceDetection();
        return;
      }

      final face = faces.first;

      // Validate head pose and face size
      final validationError = _validateFaceForEnrollment(face);
      if (validationError != null) {
        setState(() {
          _statusMessage = validationError;
          _isProcessing = false;
        });
        if (mounted) _startFaceDetection();
        return;
      }

      Map<String, double> landmarks;
      String enrollMethod;

      final meshes = await faceMeshDetector.processImage(inputImage);
      if (!mounted || _hasPopped) return;

      if (meshes.isNotEmpty) {
        landmarks = _extractMeshLandmarks(meshes.first);
        enrollMethod = 'mesh_468';
      } else {
        landmarks = _extractContourLandmarks(face);
        enrollMethod = landmarks.containsKey('leftEyeWidth')
            ? 'contour_fallback'
            : 'legacy_basic';
      }

      // Strip eyeDistance — raw pixel value varies with camera distance/resolution
      landmarks.remove('eyeDistance');

      _popWithResult({
        'landmarks': landmarks,
        'imagePath': image.path,
        'enrollMethod': enrollMethod,
      });
    } catch (e) {
      if (!mounted || _hasPopped) return;
      setState(() {
        _statusMessage = 'Capture failed: $e';
        _isProcessing = false;
      });
      if (mounted) _startFaceDetection();
    }
  }

  Future<void> _safeDispose() async {
    try {
      if (_cameraController?.value.isStreamingImages ?? false) {
        await _cameraController!.stopImageStream();
      }
    } catch (_) {}
    _cameraController?.dispose();
    _faceDetector.close();
    _faceMeshDetector?.close();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scanController.dispose();
    _safeDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == 'enroll') return _buildEnrollmentUI(context);
    return _buildRollCallUI(context);
  }

  // ──────────────────────────────────────────────────────────────────
  // ENROLLMENT MODE — Apple Face ID / LiDAR-inspired UI
  // ──────────────────────────────────────────────────────────────────
  Widget _buildEnrollmentUI(BuildContext context) {
    final mq = MediaQuery.of(context);
    const ovalRadiusX = 150.0;  // horizontal (narrower)
    const ovalRadiusY = 200.0;  // vertical (taller) — matches human face shape
    // Position oval center slightly above vertical center
    final circleY = mq.size.height * 0.38;

    final stateColor = _hasValidStreamFace
        ? const Color(0xFF22C55E)
        : _detectedFaces.isNotEmpty
            ? const Color(0xFFF59E0B)
            : Colors.white.withOpacity(0.4);

    return Scaffold(
      backgroundColor: Colors.black,
      body: _isCameraInitialized && _cameraController != null
          ? Stack(
              children: [
                // Full-screen camera preview (aspect-ratio preserved, covers screen)
                Positioned.fill(
                  child: ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _cameraController!.value.previewSize?.height ?? 1,
                        height: _cameraController!.value.previewSize?.width ?? 1,
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                  ),
                ),

                // LiDAR overlay painter (dark mask + circle + dots + progress ring)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_pulseAnimation, _scanAnimation]),
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _FaceScanOverlayPainter(
                          centerY: circleY,
                          radiusX: ovalRadiusX,
                          radiusY: ovalRadiusY,
                          stateColor: stateColor,
                          progress: _enrollProgress,
                          pulseScale: _pulseAnimation.value,
                          scanAngle: _scanAnimation.value,
                          hasFace: _detectedFaces.isNotEmpty,
                          isReady: _hasValidStreamFace,
                        ),
                      );
                    },
                  ),
                ),

                // Top bar: back button + title
                Positioned(
                  top: mq.padding.top + 8,
                  left: 4,
                  right: 16,
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_ios_new,
                            color: Colors.white, size: 20),
                      ),
                      Text(
                        'Enroll Face',
                        style: GoogleFonts.manrope(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),

                // Status instruction text (below circle)
                Positioned(
                  top: circleY + ovalRadiusY + 32,
                  left: 32,
                  right: 32,
                  child: Column(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          _isProcessing ? 'Processing...' : _statusMessage,
                          key: ValueKey(_isProcessing ? 'proc' : _statusMessage),
                          textAlign: TextAlign.center,
                          style: GoogleFonts.manrope(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _hasValidStreamFace
                            ? 'Tap the button below to confirm'
                            : 'Look directly at the camera',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),

                // Capture button (bottom)
                Positioned(
                  bottom: mq.padding.bottom + 40,
                  left: 40,
                  right: 40,
                  child: AnimatedScale(
                    scale: _hasValidStreamFace ? 1.0 : 0.92,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: (_isProcessing || !_hasValidStreamFace)
                            ? null
                            : _captureForEnrollment,
                        icon: Icon(
                          _hasValidStreamFace ? Icons.check_rounded : Icons.camera_alt_rounded,
                          size: 22,
                        ),
                        label: Text(
                          _isProcessing
                              ? 'Processing...'
                              : _hasValidStreamFace
                                  ? 'Capture'
                                  : 'Waiting for face...',
                          style: GoogleFonts.manrope(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _hasValidStreamFace
                              ? Colors.white
                              : Colors.white.withOpacity(0.15),
                          foregroundColor: _hasValidStreamFace
                              ? const Color(0xFF111111)
                              : Colors.white38,
                          disabledBackgroundColor: Colors.white.withOpacity(0.15),
                          disabledForegroundColor: Colors.white38,
                          elevation: 0,
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator(color: Colors.white)),
    );
  }

  // ──────────────────────────────────────────────────────────────────
  // ROLL-CALL MODE — original UI (unchanged)
  // ──────────────────────────────────────────────────────────────────
  Widget _buildRollCallUI(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          'Face Roll Call',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (_attendanceResults.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_attendanceResults.length} marked',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: _isCameraInitialized && _cameraController != null
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      CameraPreview(_cameraController!),
                      Container(
                        width: 250,
                        height: 320,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _matchedWorker != null
                                ? const Color(0xFF22C55E)
                                : _detectedFaces.isNotEmpty
                                    ? const Color(0xFFF59E0B)
                                    : Colors.white.withOpacity(0.5),
                            width: 3,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Platform.isIOS ? Icons.face_retouching_natural : Icons.grid_on,
                                color: Colors.cyanAccent,
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                Platform.isIOS ? 'LANDMARK' : '468-MESH',
                                style: const TextStyle(
                                  color: Colors.cyanAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_matchedWorker != null)
                        Positioned(
                          bottom: 20,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF22C55E),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.check_circle, color: Colors.white, size: 18),
                                const SizedBox(width: 6),
                                Text(
                                  '${_matchedWorker!['workerName']} (${_matchedWorker!['matchPercent']})',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  )
                : const Center(child: CircularProgressIndicator(color: Colors.white)),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF1E293B),
            child: Column(
              children: [
                Text(_statusMessage,
                    style: const TextStyle(color: Colors.white70, fontSize: 14)),
                if (_livenessStatus.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_livenessStatus,
                        style: const TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                  ),
                const SizedBox(height: 12),
                if (_attendanceResults.isNotEmpty) ...[
                  const Divider(color: Colors.white24),
                  SizedBox(
                    height: 100,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _attendanceResults.length,
                      itemBuilder: (ctx, i) {
                        final result = _attendanceResults[i];
                        return Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF22C55E).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: const Color(0xFF22C55E).withOpacity(0.3)),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.person, color: Color(0xFF22C55E), size: 28),
                              const SizedBox(height: 4),
                              Text(result['workerName'] ?? '',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600)),
                              Text(result['syncStateText'] ?? '',
                                  style: const TextStyle(
                                      color: Colors.cyanAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700)),
                              Text(result['matchPercent'] ?? '',
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.6),
                                      fontSize: 10)),
                              if (result['matchMethod'] == 'mesh_468')
                                Icon(Icons.grid_on, color: Colors.cyanAccent, size: 10),
                            ],
                          ),
                        );
                      },
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

// ════════════════════════════════════════════════════════════════════
// LiDAR-style face scan overlay painter
// ════════════════════════════════════════════════════════════════════
class _FaceScanOverlayPainter extends CustomPainter {
  final double centerY;
  final double radiusX;   // horizontal half-width
  final double radiusY;   // vertical half-height
  final Color stateColor;
  final double progress;   // 0.0 → 1.0
  final double pulseScale; // 1.0 → 1.04
  final double scanAngle;  // 0 → 2pi
  final bool hasFace;
  final bool isReady;

  _FaceScanOverlayPainter({
    required this.centerY,
    required this.radiusX,
    required this.radiusY,
    required this.stateColor,
    required this.progress,
    required this.pulseScale,
    required this.scanAngle,
    required this.hasFace,
    required this.isReady,
  });

  Rect _ovalRect(Offset center, double rx, double ry) =>
      Rect.fromCenter(center: center, width: rx * 2, height: ry * 2);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, centerY);
    final rx = radiusX * pulseScale;
    final ry = radiusY * pulseScale;
    final oval = _ovalRect(center, rx, ry);

    // ── 1. Dark overlay with oval cutout ──
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.black.withOpacity(0.65),
    );
    canvas.drawOval(
      _ovalRect(center, rx + 2, ry + 2),
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();

    // ── 2. Oval border with glow ──
    canvas.drawOval(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = stateColor.withOpacity(0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    canvas.drawOval(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = stateColor,
    );

    // ── 3. Progress ring (outer oval) ──
    if (progress > 0) {
      final ringOval = _ovalRect(center, rx + 14, ry + 14);
      canvas.drawArc(
        ringOval,
        -pi / 2,
        2 * pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = Colors.white.withOpacity(0.08)
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawArc(
        ringOval,
        -pi / 2,
        2 * pi * progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = stateColor
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── 4. LiDAR dot grid (concentric oval rings) ──
    final dotColor = stateColor;
    const rings = 5;
    const dotsPerRing = [8, 14, 20, 26, 32];

    for (int ring = 0; ring < rings; ring++) {
      final t = ring / (rings - 1);
      final ringRx = (rx * 0.2) + (rx * 0.75) * t;
      final ringRy = (ry * 0.2) + (ry * 0.75) * t;
      final count = dotsPerRing[ring];

      for (int d = 0; d < count; d++) {
        final baseAngle = (2 * pi * d) / count;
        final angleDiff = (baseAngle - scanAngle).abs() % (2 * pi);
        final proximity = angleDiff < 0.6 ? (1.0 - angleDiff / 0.6) : 0.0;

        final baseOpacity = hasFace ? 0.25 : 0.1;
        final scanBoost = hasFace && !isReady ? proximity * 0.55 : 0.0;
        final readyBoost = isReady ? 0.35 : 0.0;
        final opacity = (baseOpacity + scanBoost + readyBoost).clamp(0.0, 1.0);

        final jitter = sin(scanAngle * 2 + baseAngle * 3 + ring) * 1.5;
        final dx = center.dx + (ringRx + jitter) * cos(baseAngle);
        final dy = center.dy + (ringRy + jitter) * sin(baseAngle);

        canvas.drawCircle(
          Offset(dx, dy),
          isReady ? 2.0 : 1.5,
          Paint()..color = dotColor.withOpacity(opacity),
        );
      }
    }

    // ── 5. Scan sweep (only when detecting, not ready) ──
    if (hasFace && !isReady) {
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: scanAngle - 0.4,
          endAngle: scanAngle,
          colors: [
            stateColor.withOpacity(0.0),
            stateColor.withOpacity(0.18),
          ],
        ).createShader(oval);

      canvas.save();
      canvas.clipPath(Path()..addOval(_ovalRect(center, rx - 2, ry - 2)));
      canvas.drawOval(oval, sweepPaint);
      canvas.restore();
    }

    // ── 6. Ready glow ──
    if (isReady) {
      canvas.drawOval(
        _ovalRect(center, rx * 0.15, ry * 0.15),
        Paint()
          ..color = const Color(0xFF22C55E).withOpacity(0.12)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FaceScanOverlayPainter old) =>
      old.stateColor != stateColor ||
      old.progress != progress ||
      old.pulseScale != pulseScale ||
      old.scanAngle != scanAngle ||
      old.hasFace != hasFace ||
      old.isReady != isReady;
}

/// Helper class for writing byte data from camera image planes
class _WriteBuffer {
  final List<int> _data = [];
  void putUint8List(Uint8List list) => _data.addAll(list);
  ByteData done() => ByteData.sublistView(Uint8List.fromList(_data));
}
