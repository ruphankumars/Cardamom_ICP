import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Estimates average brightness of a camera frame (0-255).
/// Samples every 16th pixel for speed (~0.4% of frame data).
double estimateFrameBrightness(CameraImage image) {
  final Uint8List bytes = image.planes[0].bytes;

  if (Platform.isIOS) {
    // BGRA format: B=0, G=1, R=2, A=3 per pixel
    int sum = 0;
    int count = 0;
    for (int i = 0; i < bytes.length - 3; i += 64) {
      final b = bytes[i];
      final g = bytes[i + 1];
      final r = bytes[i + 2];
      sum += (r * 299 + g * 587 + b * 114) ~/ 1000;
      count++;
    }
    return count > 0 ? sum / count : 128.0;
  } else {
    // NV21: first plane is Y (luminance) channel
    int sum = 0;
    int count = 0;
    for (int i = 0; i < bytes.length; i += 16) {
      sum += bytes[i];
      count++;
    }
    return count > 0 ? sum / count : 128.0;
  }
}

/// Whether the frame is considered low light.
bool isLowLight(double brightness, {double threshold = 70.0}) {
  return brightness < threshold;
}

/// Whether the frame is too dark to attempt face detection.
bool isTooDark(double brightness, {double threshold = 30.0}) {
  return brightness < threshold;
}

/// Apply exposure optimization after camera initialization.
Future<void> optimizeCameraExposure(CameraController controller) async {
  try {
    await controller.setExposureMode(ExposureMode.auto);
    final maxOffset = await controller.getMaxExposureOffset();
    final minOffset = await controller.getMinExposureOffset();
    // Moderate positive bias — brightens without blowing out bright scenes
    final boostOffset = maxOffset * 0.33;
    if (boostOffset > minOffset) {
      await controller.setExposureOffset(boostOffset);
    }
  } catch (e) {
    debugPrint('[CameraLowLight] Exposure optimization failed: $e');
  }
}

/// Boost exposure to maximum for very dark conditions.
Future<void> maxExposureBoost(CameraController controller) async {
  try {
    final maxOffset = await controller.getMaxExposureOffset();
    await controller.setExposureOffset(maxOffset);
  } catch (e) {
    debugPrint('[CameraLowLight] Max exposure boost failed: $e');
  }
}

/// Enable torch if available. Returns true if torch was enabled.
Future<bool> enableTorchIfAvailable(CameraController controller) async {
  try {
    await controller.setFlashMode(FlashMode.torch);
    return true;
  } catch (e) {
    debugPrint('[CameraLowLight] Torch not available: $e');
    return false;
  }
}

/// Disable torch.
Future<void> disableTorch(CameraController controller) async {
  try {
    await controller.setFlashMode(FlashMode.off);
  } catch (e) {
    debugPrint('[CameraLowLight] Torch disable failed: $e');
  }
}
