-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions

# ===== On-device AI dependencies =====

# ObjectBox — keep native library loader and entity classes
-keep class io.objectbox.** { *; }
-keepclassmembers class ** {
    @io.objectbox.annotation.* <fields>;
}
-dontwarn io.objectbox.**

# ONNX Runtime — keep JNI/native interfaces
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# llama.cpp (lcpp) — keep FFI bridge classes
-keep class com.example.lcpp.** { *; }
-keepclassmembers class * {
    native <methods>;
}
-dontwarn com.example.lcpp.**
