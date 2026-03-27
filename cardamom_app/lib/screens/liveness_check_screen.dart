import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/liveness_detection_service.dart';

/// Screen that performs liveness verification before face enrollment.
/// Returns LivenessResult through Navigator.pop().
class LivenessCheckScreen extends StatefulWidget {
  const LivenessCheckScreen({super.key});

  @override
  State<LivenessCheckScreen> createState() => _LivenessCheckScreenState();
}

class _LivenessCheckScreenState extends State<LivenessCheckScreen>
    with TickerProviderStateMixin {
  CameraController? _cameraController;
  CameraDescription? _cameraDescription;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;

  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  final LivenessDetectionService _livenessService = LivenessDetectionService();

  String _instruction = 'Initializing...';
  double _progress = 0;
  Color _frameColor = Colors.white.withValues(alpha: 0.5);
  bool _showSuccess = false;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initCamera();
    _setupLivenessCallbacks();
  }

  void _setupLivenessCallbacks() {
    _livenessService.onChallengeUpdate = (message) {
      if (mounted) {
        setState(() {
          _instruction = message;
          _frameColor = const Color(0xFFF59E0B); // Amber = challenge active
        });
      }
    };

    _livenessService.onChallengeComplete = () {
      if (mounted) {
        setState(() {
          _progress = _livenessService.progress;
          _frameColor = const Color(0xFF22C55E); // Green flash
        });
        // Reset frame color after flash
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _livenessService.isActive) {
            setState(() => _frameColor = const Color(0xFFF59E0B));
          }
        });
      }
    };

    _livenessService.onLivenessComplete = (result) {
      if (mounted) {
        if (result.isLive) {
          setState(() {
            _showSuccess = true;
            _instruction = 'Liveness verified!';
            _frameColor = const Color(0xFF22C55E);
            _progress = 1.0;
          });
          // Release camera BEFORE popping so the next screen can acquire it
          Future.delayed(const Duration(milliseconds: 1200), () async {
            await _safeDispose();
            if (mounted) Navigator.pop(context, result);
          });
        } else {
          setState(() {
            _instruction = result.message;
            _frameColor = Colors.redAccent;
          });
          Future.delayed(const Duration(seconds: 2), () async {
            await _safeDispose();
            if (mounted) Navigator.pop(context, result);
          });
        }
      }
    };
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _instruction = 'No camera available on this device.');
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
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _instruction = 'Position your face in the frame...';
        });

        // Start processing first, then start liveness session after delay
        // so the timer doesn't tick while stream is not yet active
        _startProcessing();
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            _livenessService.startSession();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _instruction = 'Camera error: $e');
      }
    }
  }

  void _startProcessing() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isProcessing || !_livenessService.isActive) return;
      _isProcessing = true;

      try {
        final inputImage = _convertCameraImage(image);
        if (inputImage == null) {
          _isProcessing = false;
          return;
        }

        final faces = await _faceDetector.processImage(inputImage);

        if (faces.isNotEmpty) {
          // Restore challenge instruction when face re-detected
          if (mounted && _livenessService.isActive) {
            final challengeText = _livenessService.currentInstruction;
            if (challengeText.isNotEmpty && _instruction.contains('No face')) {
              setState(() => _instruction = challengeText);
            }
          }
          _livenessService.processFace(faces.first);
        } else if (mounted && _livenessService.isActive) {
          // Show "no face" but keep it temporary — challenge instruction restores on next detection
          setState(() => _instruction = 'No face detected — look at camera');
        }
      } catch (e) {
        debugPrint('Liveness processing error: $e');
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

  bool _disposed = false;

  Future<void> _safeDispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      if (_cameraController?.value.isStreamingImages ?? false) {
        await _cameraController!.stopImageStream();
      }
    } catch (_) {}
    _cameraController?.dispose();
    _cameraController = null;
    _faceDetector.close();
    _livenessService.dispose();
  }

  @override
  void dispose() {
    _safeDispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          'Liveness Check',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () async {
            _livenessService.cancel();
            await _safeDispose();
            if (mounted) Navigator.pop(context, null);
          },
        ),
      ),
      body: Column(
        children: [
          // Progress bar
          LinearProgressIndicator(
            value: _progress,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(
              _progress >= 1.0 ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
            ),
            minHeight: 4,
          ),
          // Camera preview
          Expanded(
            child: _isCameraInitialized && _cameraController != null
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      CameraPreview(_cameraController!),
                      // Animated face frame
                      AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Transform.scale(
                            scale: _showSuccess ? 1.0 : _pulseAnimation.value,
                            child: Container(
                              width: 250,
                              height: 320,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: _frameColor,
                                  width: 3,
                                ),
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                          );
                        },
                      ),
                      // Shield icon for liveness
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
                              Icon(Icons.verified_user,
                                  color: _showSuccess ? const Color(0xFF22C55E) : Colors.orangeAccent,
                                  size: 14),
                              const SizedBox(width: 4),
                              Text(
                                'LIVENESS',
                                style: TextStyle(
                                  color: _showSuccess ? const Color(0xFF22C55E) : Colors.orangeAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Success overlay
                      if (_showSuccess)
                        Container(
                          width: 250,
                          height: 320,
                          decoration: BoxDecoration(
                            color: const Color(0xFF22C55E).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Center(
                            child: Icon(Icons.check_circle,
                                color: Color(0xFF22C55E), size: 80),
                          ),
                        ),
                    ],
                  )
                : const Center(child: CircularProgressIndicator(color: Colors.white)),
          ),
          // Instruction panel
          Container(
            padding: const EdgeInsets.all(20),
            color: const Color(0xFF1E293B),
            child: Column(
              children: [
                // Challenge instruction
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    _instruction,
                    key: ValueKey(_instruction),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.manrope(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Complete the challenges to verify you are a real person',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                ),
                const SizedBox(height: 12),
                // Challenge progress dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    2, // _requiredChallenges
                    (i) => Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < (_progress * 2).floor()
                            ? const Color(0xFF22C55E)
                            : Colors.white24,
                        border: Border.all(
                          color: i < (_progress * 2).floor()
                              ? const Color(0xFF22C55E)
                              : Colors.white38,
                        ),
                      ),
                      child: i < (_progress * 2).floor()
                          ? const Icon(Icons.check, size: 8, color: Colors.white)
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WriteBuffer {
  final List<int> _data = [];
  void putUint8List(Uint8List list) => _data.addAll(list);
  ByteData done() => ByteData.sublistView(Uint8List.fromList(_data));
}
