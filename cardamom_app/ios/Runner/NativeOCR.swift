import Foundation
import Vision
import UIKit

/// Native iOS OCR using Apple's Vision framework.
/// Handles rotated documents, mixed print/handwritten text, and multiple languages.
/// Much more reliable than Google ML Kit on iOS release builds.
class NativeOCR {

    /// Recognize text from image file at given path.
    /// Returns full text and array of block-level texts.
    static func recognizeText(
        fromImagePath path: String,
        completion: @escaping ([String: Any]) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: path) else {
            completion(["success": false, "error": "File not found: \(path)"])
            return
        }

        guard let imageData = FileManager.default.contents(atPath: path),
              let cgImage = loadCGImage(from: imageData) else {
            completion(["success": false, "error": "Failed to load image"])
            return
        }

        performOCR(on: cgImage, completion: completion)
    }

    /// Recognize text from raw image bytes (Uint8List from Flutter).
    static func recognizeText(
        fromBytes bytes: FlutterStandardTypedData,
        completion: @escaping ([String: Any]) -> Void
    ) {
        guard let cgImage = loadCGImage(from: bytes.data) else {
            completion(["success": false, "error": "Failed to decode image bytes"])
            return
        }

        performOCR(on: cgImage, completion: completion)
    }

    // MARK: - Private

    private static func loadCGImage(from data: Data) -> CGImage? {
        // Try UIImage first (handles HEIC, JPEG, PNG, etc.)
        if let uiImage = UIImage(data: data),
           let cgImage = uiImage.cgImage {
            return cgImage
        }

        // Fallback: CGImageSource (handles more formats)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return cgImage
    }

    private static func performOCR(
        on cgImage: CGImage,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(["success": false, "error": "Vision error: \(error.localizedDescription)"])
                }
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                DispatchQueue.main.async {
                    completion(["success": true, "text": "", "blocks": [String]()])
                }
                return
            }

            // Collect text blocks (each observation = one text block)
            var blocks: [String] = []
            var fullTextParts: [String] = []

            for observation in observations {
                if let topCandidate = observation.topCandidates(1).first {
                    let text = topCandidate.string
                    blocks.append(text)
                    fullTextParts.append(text)
                }
            }

            let fullText = fullTextParts.joined(separator: "\n")

            DispatchQueue.main.async {
                completion([
                    "success": true,
                    "text": fullText,
                    "blocks": blocks,
                    "blockCount": blocks.count,
                    "charCount": fullText.count,
                    "engine": "apple-vision"
                ])
            }
        }

        // Configure for maximum accuracy
        request.recognitionLevel = .accurate

        // Support English and Hindi (Devanagari)
        request.recognitionLanguages = ["en-US", "hi-IN"]

        // Enable automatic language correction
        request.usesLanguageCorrection = true

        // Automatically handle rotation — Vision framework detects and corrects orientation
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        // Run on a background thread
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    completion(["success": false, "error": "OCR perform error: \(error.localizedDescription)"])
                }
            }
        }
    }
}
