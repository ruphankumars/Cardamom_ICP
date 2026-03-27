// File generated manually for Firebase configuration.
// Firebase project: cardamom-manager

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web platform is not configured for Firebase.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return ios; // Use same config for macOS dev
      case TargetPlatform.android:
        throw UnsupportedError('Android platform is not configured for Firebase.');
      default:
        throw UnsupportedError('${defaultTargetPlatform.name} is not supported.');
    }
  }

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDOGGW1h1X5qQaAT08qlKpsoN_InwAtFXA',
    appId: '1:129068112896:ios:4029fd62d916ab6b7f4ce5',
    messagingSenderId: '129068112896',
    projectId: 'cardamom-manager',
    storageBucket: 'cardamom-manager.firebasestorage.app',
    iosBundleId: 'com.sygt.cardamom',
  );
}
