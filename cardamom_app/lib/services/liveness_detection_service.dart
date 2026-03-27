import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Liveness challenge types
enum LivenessChallenge {
  blink,
  turnLeft,
  turnRight,
  smile,
  nod,
}

/// Result of a liveness detection session
class LivenessResult {
  final bool isLive;
  final double confidenceScore;
  final List<LivenessChallenge> completedChallenges;
  final String message;

  LivenessResult({
    required this.isLive,
    required this.confidenceScore,
    required this.completedChallenges,
    required this.message,
  });
}

/// Service that verifies a real person is in front of the camera
/// by issuing random challenges (blink, turn head, smile, nod).
class LivenessDetectionService {
  // Thresholds
  static const double _blinkThreshold = 0.3; // Eye open prob below this = blink
  static const double _smileThreshold = 0.7; // Smile prob above this = smile
  static const double _turnAngleThreshold = 18.0; // Head Y angle for left/right turn
  static const double _nodAngleThreshold = 12.0; // Head X angle for nod
  static const int _requiredChallenges = 2; // Number of challenges to pass
  static const Duration _challengeTimeout = Duration(seconds: 30);

  // State
  final List<LivenessChallenge> _pendingChallenges = [];
  final List<LivenessChallenge> _completedChallenges = [];
  LivenessChallenge? _currentChallenge;
  bool _isActive = false;
  Timer? _timeoutTimer;

  // Blink detection state
  bool _eyesWereClosed = false;

  // Nod detection state
  bool _headWasDown = false;

  // Callbacks
  VoidCallback? onChallengeComplete;
  void Function(String message)? onChallengeUpdate;
  void Function(LivenessResult result)? onLivenessComplete;

  /// Start a liveness detection session with random challenges
  void startSession() {
    _isActive = true;
    _completedChallenges.clear();
    _eyesWereClosed = false;
    _headWasDown = false;

    // Pick random challenges
    final allChallenges = List<LivenessChallenge>.from(LivenessChallenge.values)..shuffle();
    _pendingChallenges.clear();
    _pendingChallenges.addAll(allChallenges.take(_requiredChallenges));

    _nextChallenge();

    // Set overall timeout
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_challengeTimeout, () {
      if (_isActive) {
        _isActive = false;
        onLivenessComplete?.call(LivenessResult(
          isLive: false,
          confidenceScore: _completedChallenges.length / _requiredChallenges,
          completedChallenges: List.from(_completedChallenges),
          message: 'Liveness check timed out. Please try again.',
        ));
      }
    });
  }

  void _nextChallenge() {
    if (_pendingChallenges.isEmpty) {
      // All challenges completed
      _isActive = false;
      _timeoutTimer?.cancel();
      onLivenessComplete?.call(LivenessResult(
        isLive: true,
        confidenceScore: 1.0,
        completedChallenges: List.from(_completedChallenges),
        message: 'Liveness verified successfully!',
      ));
      return;
    }

    _currentChallenge = _pendingChallenges.removeAt(0);
    _eyesWereClosed = false;
    _headWasDown = false;

    onChallengeUpdate?.call(_getChallengeInstruction(_currentChallenge!));
  }

  String _getChallengeInstruction(LivenessChallenge challenge) {
    switch (challenge) {
      case LivenessChallenge.blink:
        return 'Please blink your eyes';
      case LivenessChallenge.turnLeft:
        return 'Turn your head to the left';
      case LivenessChallenge.turnRight:
        return 'Turn your head to the right';
      case LivenessChallenge.smile:
        return 'Please smile';
      case LivenessChallenge.nod:
        return 'Nod your head (look down then up)';
    }
  }

  /// Process a detected face frame to check liveness challenges
  void processFace(Face face) {
    if (!_isActive || _currentChallenge == null) return;

    bool challengePassed = false;

    switch (_currentChallenge!) {
      case LivenessChallenge.blink:
        challengePassed = _checkBlink(face);
        break;
      case LivenessChallenge.turnLeft:
        challengePassed = _checkTurnLeft(face);
        break;
      case LivenessChallenge.turnRight:
        challengePassed = _checkTurnRight(face);
        break;
      case LivenessChallenge.smile:
        challengePassed = _checkSmile(face);
        break;
      case LivenessChallenge.nod:
        challengePassed = _checkNod(face);
        break;
    }

    if (challengePassed) {
      _completedChallenges.add(_currentChallenge!);
      onChallengeComplete?.call();
      _nextChallenge();
    }
  }

  bool _checkBlink(Face face) {
    final leftEyeOpen = face.leftEyeOpenProbability ?? 1.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 1.0;

    if (leftEyeOpen < _blinkThreshold && rightEyeOpen < _blinkThreshold) {
      _eyesWereClosed = true;
    }

    // Blink = eyes were closed then opened again
    if (_eyesWereClosed && leftEyeOpen > 0.7 && rightEyeOpen > 0.7) {
      return true;
    }

    return false;
  }

  bool _checkTurnLeft(Face face) {
    final yAngle = face.headEulerAngleY ?? 0;
    // MLKit front camera: positive Y = user turned their face to their left
    // Note: camera preview is mirrored, so user sees their mirror image
    // We detect based on raw angle regardless of mirror display
    return yAngle > _turnAngleThreshold;
  }

  bool _checkTurnRight(Face face) {
    final yAngle = face.headEulerAngleY ?? 0;
    // MLKit front camera: negative Y = user turned their face to their right
    return yAngle < -_turnAngleThreshold;
  }

  bool _checkSmile(Face face) {
    final smilingProb = face.smilingProbability ?? 0;
    return smilingProb > _smileThreshold;
  }

  bool _checkNod(Face face) {
    final xAngle = face.headEulerAngleX ?? 0;

    // Head tilted down
    if (xAngle < -_nodAngleThreshold) {
      _headWasDown = true;
    }

    // Head returned up after being down = nod
    if (_headWasDown && xAngle > 5) {
      return true;
    }

    return false;
  }

  /// Get current challenge instruction text
  String get currentInstruction {
    if (_currentChallenge == null) return '';
    return _getChallengeInstruction(_currentChallenge!);
  }

  /// Get progress (0.0 to 1.0)
  double get progress => _completedChallenges.length / _requiredChallenges;

  /// Whether a session is active
  bool get isActive => _isActive;

  /// Cancel the current session
  void cancel() {
    _isActive = false;
    _timeoutTimer?.cancel();
    _pendingChallenges.clear();
  }

  /// Dispose resources
  void dispose() {
    cancel();
  }
}
