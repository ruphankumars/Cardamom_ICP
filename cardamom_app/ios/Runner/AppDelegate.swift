import Flutter
import UIKit
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate {

  // Hold a strong reference so the controller isn't deallocated
  var documentController: UIDocumentInteractionController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register for remote notifications (required for APNs + FCM on iOS)
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    application.registerForRemoteNotifications()

    // Set up the WhatsApp share method channel
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.sygt.cardamom/whatsapp",
                                       binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "shareToWhatsApp" {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "filePath is required", details: nil))
          return
        }
        self?.shareToWhatsApp(filePath: filePath, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // Set up badge clearing method channel
    let badgeChannel = FlutterMethodChannel(name: "com.sygt.cardamom/badge",
                                             binaryMessenger: controller.binaryMessenger)
    badgeChannel.setMethodCallHandler { (call, result) in
      if call.method == "clearBadge" {
        UIApplication.shared.applicationIconBadgeNumber = 0
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // Set up the native OCR method channel (Apple Vision framework)
    let ocrChannel = FlutterMethodChannel(name: "com.sygt.cardamom/native_ocr",
                                           binaryMessenger: controller.binaryMessenger)

    ocrChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "recognizeFromPath":
        guard let args = call.arguments as? [String: Any],
              let imagePath = args["imagePath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "imagePath is required", details: nil))
          return
        }
        NativeOCR.recognizeText(fromImagePath: imagePath) { ocrResult in
          result(ocrResult)
        }

      case "recognizeFromBytes":
        guard let args = call.arguments as? [String: Any],
              let imageBytes = args["imageBytes"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "INVALID_ARGS", message: "imageBytes is required", details: nil))
          return
        }
        NativeOCR.recognizeText(fromBytes: imageBytes) { ocrResult in
          result(ocrResult)
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func shareToWhatsApp(filePath: String, result: @escaping FlutterResult) {
    let fileURL = URL(fileURLWithPath: filePath)

    // Check if file exists
    guard FileManager.default.fileExists(atPath: filePath) else {
      result(FlutterError(code: "FILE_NOT_FOUND", message: "File not found at path", details: nil))
      return
    }

    // Rename to .wai extension for WhatsApp to pick it up
    let whatsAppPath = fileURL.deletingPathExtension().appendingPathExtension("wai")
    try? FileManager.default.removeItem(at: whatsAppPath)
    try? FileManager.default.copyItem(at: fileURL, to: whatsAppPath)

    DispatchQueue.main.async { [weak self] in
      self?.documentController = UIDocumentInteractionController(url: whatsAppPath)
      self?.documentController?.uti = "net.whatsapp.image"

      guard let rootVC = UIApplication.shared.keyWindow?.rootViewController else {
        result(FlutterError(code: "NO_VIEW", message: "No root view controller", details: nil))
        return
      }

      // Find the topmost presented view controller
      var topVC = rootVC
      while let presented = topVC.presentedViewController {
        topVC = presented
      }

      let opened = self?.documentController?.presentOpenInMenu(
        from: CGRect(x: 0, y: 0, width: 300, height: 300),
        in: topVC.view,
        animated: true
      ) ?? false

      if opened {
        result(true)
      } else {
        // WhatsApp not installed or can't open
        result(false)
      }
    }
  }
}
