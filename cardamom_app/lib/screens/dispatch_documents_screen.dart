import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/operation_queue.dart';
import '../mixins/optimistic_action_mixin.dart';
import '../theme/app_theme.dart';

/// Native iOS OCR via Apple Vision framework (platform channel)
const _nativeOcrChannel = MethodChannel('com.sygt.cardamom/native_ocr');

// ── Send raw camera bytes — zero re-encoding for lossless quality ──
Future<String> _prepareImageForUpload(Uint8List rawBytes) async {
  // Send original camera JPEG directly — no re-encoding to avoid quality loss.
  // ImagePicker already returns correctly-oriented JPEG on modern Android/iOS.
  // Only resize if over 8MB to cap network payload.
  if (rawBytes.length > 8 * 1024 * 1024) {
    final resized = await compute(_resizeOnly, rawBytes);
    return base64Encode(resized);
  }
  return base64Encode(rawBytes);
}

/// Isolate function — only resizes oversized images to cap network payload
Uint8List _resizeOnly(Uint8List bytes) {
  var decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  if (decoded.width > 2000) {
    decoded = img.copyResize(decoded, width: 2000, interpolation: img.Interpolation.cubic);
  }
  return Uint8List.fromList(img.encodeJpg(decoded, quality: 100));
}

/// Re-decode image bytes and re-encode as PNG in an isolate.
/// Handles HEIC/HEIF or other formats that ML Kit may not read directly.
Uint8List? _decodeAndReencode(Uint8List rawBytes) {
  var decoded = img.decodeImage(rawBytes);
  if (decoded == null) return null;
  decoded = img.bakeOrientation(decoded);
  return Uint8List.fromList(img.encodePng(decoded));
}

// ── OCR text parsing helpers ──

/// Represents a client match with similarity score
class ClientMatch {
  final String name;
  final double score; // 0.0 to 1.0
  ClientMatch(this.name, this.score);
  int get percentage => (score * 100).round();
}

/// Find top N client matches from OCR text using known client list.
/// Returns list sorted by similarity score (highest first).
///
/// PRIMARY STRATEGY: Extract "Bill To" / "Ship To" section from Tally A4
/// invoice, then match ONLY that section text against clients.
/// FALLBACK: Word-level matching on cleaned full text with noise filtering.
List<ClientMatch> findTopClientMatches(String text, List<String> knownClients, {int topN = 3}) {
  if (text.isEmpty || knownClients.isEmpty) return [];

  const ownCompanyWords = ['emperor spices', 'yogaganapathi', 'espl', 'sygt'];

  // Common business suffixes — low signal alone
  const commonWords = {
    'the', 'and', 'pvt', 'ltd', 'private', 'limited',
    'traders', 'trading', 'trader',
    'enterprise', 'enterprises', 'industries', 'company', 'group',
    'inc', 'corp', 'llc', 'llp', 'sons', 'brothers', 'bros', 'associates',
    'international', 'india', 'spice', 'spices', 'foods', 'food',
    'exports', 'imports', 'general', 'new', 'sri', 'shri', 'sree', 'shree',
  };

  // Indian city names — location qualifiers, not identity words
  const cityWords = {
    'guwahati', 'delhi', 'mumbai', 'chennai', 'kolkata', 'bangalore',
    'hyderabad', 'pune', 'ahmedabad', 'jaipur', 'lucknow', 'kanpur',
    'nagpur', 'indore', 'thane', 'bhopal', 'patna', 'vadodara',
    'ghaziabad', 'ludhiana', 'agra', 'nashik', 'rajkot', 'varanasi',
    'surat', 'coimbatore', 'vijayawada', 'madurai', 'jalna', 'jodhpur',
    'raipur', 'kochi', 'chandigarh', 'mysore', 'ranchi', 'bhubaneswar',
    'mangalore', 'dibrugarh', 'silchar', 'tezpur', 'jorhat', 'tinsukia',
  };

  // Logistics company names that pollute OCR text (from Lorry Receipts)
  const logisticsNoise = {
    'delhivery', 'bluedart', 'blue dart', 'spoton', 'spot on',
    'gati', 'dtdc', 'professional couriers', 'safe express',
    'safexpress', 'vrl logistics', 'tci express', 'xpressbees',
    'ecom express', 'trackon', 'maruti courier', 'shree maruti',
    'first flight', 'india post', 'speed post', 'fedex', 'dhl',
  };

  // ══════════════════════════════════════════════════════════════════
  // STRATEGY 1: Extract "Bill To" / "Ship To" from Tally A4 invoice
  // This is the PRIMARY strategy — Tally invoices always have these
  // sections with the client name right after the label.
  // ══════════════════════════════════════════════════════════════════
  final sectionText = _extractBillToSection(text);
  if (sectionText != null && sectionText.length >= 3) {
    debugPrint('[ClientMatch] Found Bill To section: "$sectionText"');
    final sectionMatches = _matchClientsAgainstSection(
      sectionText, knownClients, ownCompanyWords, commonWords, cityWords,
    );
    if (sectionMatches.isNotEmpty && sectionMatches.first.score >= 0.40) {
      debugPrint('[ClientMatch] Section match: ${sectionMatches.map((m) => '${m.name}=${m.percentage}%').join(', ')}');
      return sectionMatches.take(topN).toList();
    }
    debugPrint('[ClientMatch] Section match too weak (${sectionMatches.isEmpty ? "none" : "${sectionMatches.first.percentage}%"}), falling back');
  }

  // ══════════════════════════════════════════════════════════════════
  // STRATEGY 2: Full-text word matching with noise filtering
  // Used when Bill To section is not found (e.g. non-Tally documents)
  // ══════════════════════════════════════════════════════════════════

  // Clean the text and strip logistics company noise
  var lowerText = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  for (final noise in logisticsNoise) {
    lowerText = lowerText.replaceAll(noise, ' ');
  }
  final cleanedText = lowerText
      .replaceAll(RegExp(r'[|!@#\$%^&*(){}\[\]<>~`]'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  final scores = <String, double>{};

  for (final client in knownClients) {
    if (client.isEmpty || client.length < 3) continue;
    final lowerClient = client.toLowerCase().trim();
    if (ownCompanyWords.any((c) => lowerClient.contains(c) || c.contains(lowerClient))) continue;

    double score = 0.0;

    // Exact substring match — longer names score higher
    if (cleanedText.contains(lowerClient)) {
      if (client.length >= 15) {
        score = 0.95 + (client.length / 500.0).clamp(0.0, 0.05);
      } else if (client.length >= 10) {
        score = 0.80 + (client.length / 200.0).clamp(0.0, 0.10);
      } else {
        score = 0.40 + (client.length / 100.0).clamp(0.0, 0.15);
      }
      scores[client] = score;
      continue;
    }

    // Word-level matching
    final allWords = lowerClient
        .split(RegExp(r'[\s&.,\-]+'))
        .where((w) => w.length >= 3)
        .toList();
    final significantWords = allWords.where((w) => !commonWords.contains(w) && !cityWords.contains(w)).toList();
    final cityWordsInClient = allWords.where((w) => cityWords.contains(w)).toList();
    final genericWords = allWords.where((w) => commonWords.contains(w)).toList();

    if (significantWords.isEmpty && genericWords.isEmpty && cityWordsInClient.isEmpty) continue;

    int matchedSignificant = 0;
    int fuzzySignificant = 0;
    int matchedGeneric = 0;
    int matchedCity = 0;

    // Use word-boundary matching for significant words
    for (final word in significantWords) {
      if (_wordBoundaryMatch(cleanedText, word)) {
        matchedSignificant++;
      } else if (word.length >= 5) {
        final wordLen = word.length;
        bool fuzzyFound = false;
        for (int i = 0; i <= cleanedText.length - wordLen && !fuzzyFound; i++) {
          final end = (i + wordLen + 1).clamp(0, cleanedText.length);
          final substr = cleanedText.substring(i, end);
          if (_levenshtein(word, substr) <= 1) fuzzyFound = true;
        }
        if (fuzzyFound) fuzzySignificant++;
      }
    }

    for (final word in genericWords) {
      if (_wordBoundaryMatch(cleanedText, word)) matchedGeneric++;
    }
    // Word-boundary matching for city words — prevents "delhivery" → "delhi"
    for (final word in cityWordsInClient) {
      if (_wordBoundaryMatch(cleanedText, word)) matchedCity++;
    }

    final totalSig = significantWords.length;
    final totalGen = genericWords.length;
    final totalCity = cityWordsInClient.length;

    if (totalSig == 0 && totalGen == 0 && totalCity == 0) continue;

    if (totalSig > 0) {
      score += 0.60 * (matchedSignificant / totalSig);
      score += 0.12 * (fuzzySignificant / totalSig);
    }
    if (totalGen > 0) {
      score += 0.08 * (matchedGeneric / totalGen);
    }
    if (totalCity > 0) {
      score += 0.03 * (matchedCity / totalCity);
    }

    final coreMatched = matchedSignificant + fuzzySignificant + matchedGeneric;
    // Absolute count bonus — more words matched = more confident
    // "Shyam Lal Raj Kumar Agarwal" (5 matches) should beat "Agarwal Trading" (1 match)
    score += (coreMatched * 0.03).clamp(0.0, 0.15);
    score += (client.length / 500.0).clamp(0.0, 0.05);

    if (totalSig >= 2 && matchedSignificant == totalSig) {
      score += 0.08;
    }

    // Penalty: ONLY city words matched → heavily penalize
    if (matchedSignificant == 0 && fuzzySignificant == 0 && matchedGeneric == 0 && matchedCity > 0) {
      score = score * 0.3;
    }

    // Penalty: low significant word match ratio
    if (totalSig >= 2 && matchedSignificant <= 1 && fuzzySignificant == 0) {
      score = score * 0.65;
    }

    if (score > 0.10) {
      scores[client] = score;
    }
  }

  final sorted = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return sorted.take(topN).map((e) => ClientMatch(e.key, e.value)).toList();
}

/// Extract the client name section from a Tally A4 Tax Invoice.
/// Looks for "Bill To", "Ship To", "Buyer", "Consignee" labels and extracts
/// the text block immediately following them (which is the client name + address).
/// Returns the extracted section text, or null if not found.
String? _extractBillToSection(String text) {
  // Patterns ordered by specificity — most reliable Tally labels first.
  // Each captures text after the label up to the next section boundary.
  //
  // IMPORTANT: Tally invoices use formats like:
  //   "Buyer (Bill to)"  — parenthetical qualifier after main label
  //   "Consignee (Ship to)" — same pattern
  // The regex must skip the parenthetical part before capturing client name.
  final patterns = [
    // Tally "Buyer (Bill to)" or "Buyer:" — skip optional parenthetical
    RegExp(r'Buyer\s*(?:\([^)]*\))?\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|State|Code|Phone|Place|Shop|Ship|Deliver|Description|Sl\.?\s*No|S\.?\s*No|Particulars|HSN)|$)', caseSensitive: false, dotAll: true),
    // Tally "Consignee (Ship to)" — skip optional parenthetical
    RegExp(r'Consignee\s*(?:\([^)]*\))?\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|State|Code|Phone|Place|Shop|Bill|Description|Sl\.?\s*No|S\.?\s*No|Particulars|HSN)|$)', caseSensitive: false, dotAll: true),
    // Standard: "Bill To:" or "Billed To:" followed by name
    RegExp(r'Bill(?:ed)?\s*To\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|State|Code|Phone|Place|Shop|Ship|Deliver|Description|Sl\.?\s*No|S\.?\s*No|Particulars|HSN)|$)', caseSensitive: false, dotAll: true),
    // "Ship To:" / "Deliver To:" — same client name as Bill To
    RegExp(r'(?:Ship(?:ped)?\s*To|Deliver(?:y|ed)?\s*To)\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|State|Code|Phone|Place|Shop|Bill|Description|Sl\.?\s*No|S\.?\s*No|Particulars|HSN)|$)', caseSensitive: false, dotAll: true),
    // "Receiver" from transport docs
    RegExp(r'Receiver\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|Phone|Address|From|Consignor|Description)|$)', caseSensitive: false, dotAll: true),
    // "To: M/s." pattern
    RegExp(r'To\s*[:\-]?\s*M\/s\.?\s*(.+?)(?:\n\s*(?:GSTIN|GST|Phone|Address)|$)', caseSensitive: false, dotAll: true),
  ];

  for (final re in patterns) {
    final match = re.firstMatch(text);
    if (match != null) {
      // Take just the first line of the captured group — that's the client name.
      // The rest is typically address lines.
      final rawSection = match.group(1)?.trim() ?? '';
      if (rawSection.isEmpty) continue;

      // Extract the first meaningful line (client name)
      final lines = rawSection.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      if (lines.isEmpty) continue;

      // Use first line (client name) + city words from lines 2-3 for matching.
      // Don't include full address lines — street names like "SUBASH MARG"
      // cause false matches with clients like "Subash Trading Co".
      String sectionLines = lines.first;
      // Append any city-name words found in subsequent lines (for tie-breaking)
      if (lines.length > 1) {
        const knownCities = {'guwahati','delhi','mumbai','chennai','kolkata','bangalore',
          'hyderabad','pune','ahmedabad','jaipur','lucknow','kanpur','nagpur','indore',
          'thane','bhopal','patna','vadodara','ghaziabad','ludhiana','agra','nashik',
          'rajkot','varanasi','surat','coimbatore','vijayawada','madurai','jalna',
          'jodhpur','raipur','kochi','chandigarh','mysore','ranchi','bhubaneswar',
          'mangalore','dibrugarh','silchar','tezpur','jorhat','tinsukia','bikaner',
          'gorakhpur','jammu','gwalior','amritsar','kurukshetra','baroda','nadiad',
          'haveri','berhampur','murshidabad','ganganagar','gandhinagar','guntur','dhuri',
          'barpeta','siliguri'};
        for (int i = 1; i < lines.length && i < 3; i++) {
          final lineWords = lines[i].toLowerCase().split(RegExp(r'[\s,\-]+')).where((w) => w.length >= 3);
          for (final w in lineWords) {
            if (knownCities.contains(w)) {
              sectionLines += ' $w';
            }
          }
        }
      }

      // Skip if it looks like our own company name
      final lower = sectionLines.toLowerCase();
      if (lower.contains('emperor spices') || lower.contains('yogaganapathi') ||
          lower.contains('espl') || lower.contains('sygt')) {
        continue;
      }

      // Must have at least one letter (not just numbers/symbols)
      if (!RegExp(r'[a-zA-Z]').hasMatch(sectionLines)) continue;

      return sectionLines;
    }
  }
  return null;
}

/// Match clients against a short extracted section (e.g. "Bill To" text).
/// Uses tighter matching since we're working with a focused text snippet.
List<ClientMatch> _matchClientsAgainstSection(
  String sectionText,
  List<String> knownClients,
  List<String> ownCompanyWords,
  Set<String> commonWords,
  Set<String> cityWords,
) {
  final lowerSection = sectionText.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  final cleanedSection = lowerSection
      .replaceAll(RegExp(r'[|!@#\$%^&*(){}\[\]<>~`]'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  final scores = <String, double>{};

  for (final client in knownClients) {
    if (client.isEmpty || client.length < 3) continue;
    final lowerClient = client.toLowerCase().trim();
    if (ownCompanyWords.any((c) => lowerClient.contains(c) || c.contains(lowerClient))) continue;

    // Strip the city suffix from client name for matching
    // e.g. "Shree Vardhman Traders - Jalna" → try matching "Shree Vardhman Traders" first
    final dashIdx = lowerClient.lastIndexOf(' - ');
    final clientNamePart = dashIdx > 0 ? lowerClient.substring(0, dashIdx).trim() : lowerClient;

    double score = 0.0;

    // Dot-stripped and compact versions for abbreviation matching
    // "V.P.H.Corporation" → "vphcorporation" → matches "vph corporation" compacted
    final dotStrippedPart = clientNamePart.replaceAll('.', '');
    final dotStrippedClient = lowerClient.replaceAll('.', '');
    final dotStrippedSection = cleanedSection.replaceAll('.', '');
    final compactPart = clientNamePart.replaceAll(RegExp(r'[.\s]'), '');
    final compactSection = cleanedSection.replaceAll(RegExp(r'[.\s]'), '');

    // Exact substring match — with coverage-based scoring
    // Short substring in long section = weak (e.g. "agarwal" in 60-char section)
    // Long substring covering most of section = strong match
    final fullMatch = cleanedSection.contains(lowerClient) || dotStrippedSection.contains(dotStrippedClient);
    // partMatch: check normal → dot-stripped → compact (for spaced abbreviations like "R N G")
    bool partMatch = false;
    bool viaCompact = false;
    if (!fullMatch && dashIdx > 0) {
      if (cleanedSection.contains(clientNamePart) || dotStrippedSection.contains(dotStrippedPart)) {
        partMatch = true;
      } else if (compactSection.contains(compactPart)) {
        partMatch = true;
        viaCompact = true;
      }
    }
    // Pick the right substring & length for coverage calculation
    String? substringToCheck;
    double coverageDenom = cleanedSection.length.toDouble();
    if (fullMatch) {
      substringToCheck = cleanedSection.contains(lowerClient) ? lowerClient : dotStrippedClient;
    } else if (partMatch) {
      if (viaCompact) {
        substringToCheck = compactPart;
        coverageDenom = compactSection.length.toDouble();
      } else {
        substringToCheck = cleanedSection.contains(clientNamePart) ? clientNamePart : dotStrippedPart;
      }
    }

    if (substringToCheck != null && coverageDenom > 0) {
      final coverage = substringToCheck.length / coverageDenom;
      if (coverage >= 0.25) {
        // Good coverage — substring match is meaningful
        double subScore = fullMatch ? 0.98 : (0.80 + coverage * 0.40).clamp(0.0, 0.97);
        // City tie-break for identical-except-city clients
        final cityInClient = lowerClient.split(RegExp(r'[\s&.,\-]+')).where((w) => cityWords.contains(w)).toList();
        for (final cw in cityInClient) {
          if (_wordBoundaryMatch(cleanedSection, cw)) subScore += 0.02;
        }
        scores[client] = subScore.clamp(0.0, 1.0);
        continue;
      }
      // Low coverage — fall through to word-level matching
    }

    // Word-level matching against the section text
    final allWords = clientNamePart
        .split(RegExp(r'[\s&.,\-]+'))
        .where((w) => w.length >= 3)
        .toList();
    final significantWords = allWords.where((w) => !commonWords.contains(w) && !cityWords.contains(w)).toList();
    final genericWordsInClient = allWords.where((w) => commonWords.contains(w)).toList();

    // Don't skip clients with only generic words (e.g. "B.J Brothers")
    if (significantWords.isEmpty && genericWordsInClient.isEmpty) continue;

    int matchedExact = 0;
    int matchedFuzzy = 0;
    for (final word in significantWords) {
      if (_wordBoundaryMatch(cleanedSection, word)) {
        matchedExact++;
      } else if (word.length >= 4) {
        // Fuzzy match with edit distance 1 — handles OCR typos
        bool fuzzyFound = false;
        final sectionWords = cleanedSection.split(RegExp(r'\s+'));
        for (final sw in sectionWords) {
          if (sw.length >= word.length - 2 && sw.length <= word.length + 2) {
            if (_levenshtein(word, sw) <= 1) { fuzzyFound = true; break; }
          }
        }
        if (fuzzyFound) matchedFuzzy++;
      }
    }

    // Also match generic words (traders, brothers, etc.)
    int matchedGenericInSection = 0;
    for (final word in genericWordsInClient) {
      if (_wordBoundaryMatch(cleanedSection, word)) matchedGenericInSection++;
    }

    final totalSig = significantWords.length;

    if (totalSig > 0) {
      if (matchedExact == 0 && matchedFuzzy == 0) continue;

      final totalMatched = matchedExact + matchedFuzzy;
      final matchRatio = (matchedExact + matchedFuzzy * 0.8) / totalSig;
      score = matchRatio * 0.75; // base: up to 75% from ratio
      if (matchedFuzzy > 0 && matchedExact < totalSig) {
        score -= 0.05; // small penalty for fuzzy-only matches
      }
      // Bonus: all significant words matched exactly
      if (matchedExact == totalSig) score += 0.05;
      // CRITICAL: Absolute word count bonus — more matched words = higher confidence
      // Ensures "Agarwal Karyana Store" (3 match) beats "Agarwal Trading Co" (1 match)
      score += (totalMatched * 0.05).clamp(0.0, 0.20);
      // Small bonus for generic words also matching
      if (genericWordsInClient.isNotEmpty && matchedGenericInSection > 0) {
        score += 0.02;
      }
      // Check for prefix/abbreviation match (handles "V.P.H.Corporation" vs "B.B.Corporation")
      final shortTokens = clientNamePart.split(RegExp(r'[\s&.,]+')).where((w) => w.length >= 1 && w.length < 3).toList();
      if (shortTokens.isNotEmpty) {
        for (final st in shortTokens) {
          if (cleanedSection.contains(st)) { score += 0.03; break; }
        }
      }
    } else if (genericWordsInClient.isNotEmpty && matchedGenericInSection > 0) {
      // Client has ONLY generic words (e.g. "B.J Brothers")
      final genRatio = matchedGenericInSection / genericWordsInClient.length;
      score = genRatio * 0.50; // max 50% from generic-only matching
      // Check if the short prefix (e.g. "b.j", "c.r") also appears
      final prefix = clientNamePart.split(RegExp(r'\s+')).first;
      if (prefix.length >= 2) {
        if (_wordBoundaryMatch(cleanedSection, prefix)) {
          score += 0.30; // strong bonus: prefix is a whole word match
        } else if (prefix.length >= 3 && cleanedSection.contains(prefix)) {
          score += 0.20; // moderate bonus for longer prefix substring
        }
      }
    } else {
      continue;
    }

    // Check city word in section for tie-breaking
    final cityInClient = lowerClient.split(RegExp(r'[\s&.,\-]+')).where((w) => cityWords.contains(w)).toList();
    for (final cw in cityInClient) {
      if (_wordBoundaryMatch(cleanedSection, cw)) {
        score += 0.02; // small city tie-breaker
      }
    }

    score = score.clamp(0.0, 1.0);
    if (score > 0.20) scores[client] = score;
  }

  final sorted = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.map((e) => ClientMatch(e.key, e.value)).toList();
}

/// Check if [word] appears as a whole word in [text] (not as a substring).
/// Prevents "delhi" matching inside "delhivery".
bool _wordBoundaryMatch(String text, String word) {
  // Fast path: if the word isn't even a substring, skip regex
  if (!text.contains(word)) return false;
  final escaped = word.replaceAll(RegExp(r'[.*+?^${}()|[\]\\]'), r'\$0');
  return RegExp('(?:^|[\\s,;:\\-./])$escaped(?:[\\s,;:\\-./]|\$)').hasMatch(text);
}

/// Simple Levenshtein distance for OCR fuzzy matching
int _levenshtein(String a, String b) {
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final matrix = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
  for (int i = 0; i <= a.length; i++) matrix[i][0] = i;
  for (int j = 0; j <= b.length; j++) matrix[0][j] = j;
  for (int i = 1; i <= a.length; i++) {
    for (int j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      matrix[i][j] = [matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + cost].reduce((a, b) => a < b ? a : b);
    }
  }
  return matrix[a.length][b.length];
}

/// Extract invoice number from Tally invoice OCR text.
/// Patterns: "Invoice No. 659/2025-26", "Invoice No: 437", "Inv. No. 123/2025-26"
String? extractInvoiceNumber(String text) {
  // Pattern 1: "Invoice No." followed by number/year format (e.g. "659/2025-26")
  final p1 = RegExp(r'(?:Invoice|Inv\.?)\s*(?:No\.?|Number|#)\s*[:\-]?\s*(\d+(?:\/\d{4}[-–]\d{2})?)', caseSensitive: false);
  final m1 = p1.firstMatch(text);
  if (m1 != null) return m1.group(1);

  // Pattern 2: "Bill No." (some Tally configs use this)
  final p2 = RegExp(r'Bill\s*(?:No\.?|Number)\s*[:\-]?\s*(\d+(?:\/\d{4}[-–]\d{2})?)', caseSensitive: false);
  final m2 = p2.firstMatch(text);
  if (m2 != null) return m2.group(1);

  // Pattern 3: "Voucher No." (Tally voucher format)
  final p3 = RegExp(r'Voucher\s*(?:No\.?|Number)\s*[:\-]?\s*(\d+(?:\/\d{4}[-–]\d{2})?)', caseSensitive: false);
  final m3 = p3.firstMatch(text);
  if (m3 != null) return m3.group(1);

  return null;
}

/// Extract invoice date from Tally invoice OCR text.
/// Patterns: "Dated 20-Feb-26", "dt. 20-Feb-26", "Date: 20/02/2026", "Ack Date : 21-Feb-26"
/// Returns DateTime or null.
DateTime? extractInvoiceDate(String text) {
  // Pattern 1: "Dated DD-Mon-YY" or "Dated DD Mon YY"
  final p1 = RegExp(r'Dated\s+(\d{1,2})\s*[-\s]\s*([A-Za-z]{3})\s*[-\s]\s*(\d{2,4})', caseSensitive: false);
  final m1 = p1.firstMatch(text);
  if (m1 != null) {
    final dt = _parseOcrDate(m1.group(1)!, m1.group(2)!, m1.group(3)!);
    if (dt != null) return dt;
  }

  // Pattern 2: "dt. DD-Mon-YY"
  final p2 = RegExp(r'dt\.\s*(\d{1,2})\s*[-\s]\s*([A-Za-z]{3})\s*[-\s]\s*(\d{2,4})', caseSensitive: false);
  final m2 = p2.firstMatch(text);
  if (m2 != null) {
    final dt = _parseOcrDate(m2.group(1)!, m2.group(2)!, m2.group(3)!);
    if (dt != null) return dt;
  }

  // Pattern 3: "Date: DD-Mon-YY" or "Date : DD/MM/YYYY"
  final p3 = RegExp(r'(?:Inv(?:oice)?\s*)?Date\s*[:\-]?\s*(\d{1,2})\s*[-/\s]\s*([A-Za-z]{3}|\d{1,2})\s*[-/\s]\s*(\d{2,4})', caseSensitive: false);
  final m3 = p3.firstMatch(text);
  if (m3 != null) {
    final dt = _parseOcrDate(m3.group(1)!, m3.group(2)!, m3.group(3)!);
    if (dt != null) return dt;
  }

  return null;
}

/// Parse OCR date components into DateTime.
/// Handles: day="20", month="Feb" or "02", year="26" or "2026"
DateTime? _parseOcrDate(String dayStr, String monthStr, String yearStr) {
  try {
    final day = int.parse(dayStr);
    int month;
    if (RegExp(r'^\d+$').hasMatch(monthStr)) {
      month = int.parse(monthStr);
    } else {
      const months = {'jan':1,'feb':2,'mar':3,'apr':4,'may':5,'jun':6,'jul':7,'aug':8,'sep':9,'oct':10,'nov':11,'dec':12};
      month = months[monthStr.toLowerCase()] ?? 0;
    }
    int year = int.parse(yearStr);
    if (year < 100) year += 2000; // 26 → 2026

    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  } catch (_) {
    return null;
  }
}

/// Extract the sender company name (ESPL or SYGT) from OCR text.
/// Returns 'Emperor Spices Pvt Ltd' or 'Sri Yogaganapathi Traders' or null.
String? extractCompanyFromBill(String text) {
  // Normalize: lowercase, collapse whitespace, strip common OCR junk
  final lower = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final cleaned = lower
      .replaceAll(RegExp(r'[|!@#\$%^&*(){}\[\]<>~`]'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  // ESPL patterns — check both raw and cleaned text
  final esplPatterns = [
    'emperor spices',
    'emperor spice',
    'emperorspices',
    'espl',
    'e.s.p.l',
    'e s p l',
    'emperor s',
    'emp spices',
    'emperor private',    // "EMPEROR SPICES PRIVATE LIMITED"
    'emperor pvt',
    'emperor limited',
    'emperors',           // common OCR merge
    'emperior',           // common OCR typo
    'emporor',            // common OCR typo
    'emperer',            // common OCR typo
    'emp. spices',
  ];
  for (final p in esplPatterns) {
    if (lower.contains(p) || cleaned.contains(p)) return 'Emperor Spices Pvt Ltd';
  }
  // Regex fallback: "EMPEROR" + "SPICE" nearby (handles OCR line breaks)
  if (RegExp(r'emp[ei]r[oe]r[\s\S]{0,20}spice', caseSensitive: false).hasMatch(text)) {
    return 'Emperor Spices Pvt Ltd';
  }

  // SYGT patterns
  final sygtPatterns = [
    'yogaganapathi',
    'yoga ganapathi',
    'yogaganapathy',
    'yoganagapathi',     // OCR transposition
    'yogagnapathi',      // OCR missing letter
    'yogaganapati',      // alternate spelling
    'yogaganapath',      // truncated
    'sygt',
    's.y.g.t',
    's y g t',
    'sri yoga',
    'yoganandha',        // common OCR misread
    'ganapathi trader',
    'ganapathy trader',
    'ganapathi',         // just the distinctive word
    'yogagan',           // truncated but distinctive prefix
  ];
  for (final p in sygtPatterns) {
    if (lower.contains(p) || cleaned.contains(p)) return 'Sri Yogaganapathi Traders';
  }
  // Regex fallback: "YOGA" + "GANAPATHI" nearby (handles OCR line breaks / noise)
  if (RegExp(r'yoga[\s\S]{0,20}ganap', caseSensitive: false).hasMatch(text)) {
    return 'Sri Yogaganapathi Traders';
  }

  return null;
}

class DispatchDocumentsScreen extends StatefulWidget {
  const DispatchDocumentsScreen({super.key});

  @override
  State<DispatchDocumentsScreen> createState() => _DispatchDocumentsScreenState();
}

class _DispatchDocumentsScreenState extends State<DispatchDocumentsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.titaniumLight,
      appBar: AppBar(
        title: Text('Dispatch Documents', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        backgroundColor: AppTheme.titaniumMid,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.muted,
          indicatorColor: AppTheme.primary,
          tabs: const [
            Tab(icon: Icon(Icons.camera_alt_outlined), text: 'Upload'),
            Tab(icon: Icon(Icons.history_rounded), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _UploadTab(onUploaded: () {
            _tabController.animateTo(1);
          }),
          const _HistoryTab(),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// UPLOAD TAB
// ══════════════════════════════════════════════════════════════════════════════
class _UploadTab extends StatefulWidget {
  final VoidCallback onUploaded;
  const _UploadTab({required this.onUploaded});

  @override
  State<_UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<_UploadTab> with OptimisticActionMixin {
  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();

  final ApiService _apiService = ApiService();

  // Images (multi-image support)
  List<Uint8List> _capturedImages = [];

  // OCR
  bool _isRunningOcr = false;
  bool _isSending = false;
  String? _ocrRawText;
  String? _ocrError;
  bool _ocrCompanyDetected = false;
  int _ocrVersion = 0; // incremented on each capture to cancel stale OCR runs

  // Form
  String? _selectedClient;
  List<String> _clientPhones = [];
  List<Map<String, dynamic>> _allClients = [];
  String _companyName = 'Sri Yogaganapathi Traders';
  DateTime _selectedDate = DateTime.now();
  String? _invoiceNumber;
  DateTime? _invoiceDate;
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _clientTextController = TextEditingController();
  final TextEditingController _invoiceNumberController = TextEditingController();
  List<String> _linkedOrderIds = [];
  List<Map<String, dynamic>> _packedOrders = [];

  @override
  void initState() {
    super.initState();
    _clientsReady = _loadClients();
  }

  /// Completes when _allClients is loaded — OCR waits on this
  late final Future<void> _clientsReady;

  @override
  void dispose() {
    _notesController.dispose();
    _clientTextController.dispose();
    _invoiceNumberController.dispose();
    super.dispose();
  }

  Future<void> _loadClients() async {
    // Load from dropdown endpoint (dropdown_data/clients) — this is the
    // single source of truth for client names. Previously used client_contacts
    // which could contain stale/old-format names not in the dropdown.
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final resp = await _apiService.getDropdownOptions();
        final clientList = resp.data['client'];
        if (clientList is List && clientList.isNotEmpty) {
          if (mounted) {
            setState(() {
              _allClients = clientList
                  .map((name) => <String, dynamic>{'name': name.toString()})
                  .toList();
            });
          }
          debugPrint('[Clients] Loaded ${_allClients.length} clients from dropdown (attempt $attempt)');
          return;
        }
      } catch (e) {
        debugPrint('[Clients] Failed to load (attempt $attempt): $e');
        if (attempt < 3) await Future.delayed(Duration(seconds: attempt));
      }
    }
    debugPrint('[Clients] All 3 attempts failed — OCR client matching will not work');
  }

  Future<void> _loadClientPhones(String clientName) async {
    try {
      final resp = await _apiService.getClientContact(clientName);
      final contact = resp.data['contact'];
      if (contact != null) {
        final phones = <String>[];
        if (contact['phones'] is List && (contact['phones'] as List).isNotEmpty) {
          phones.addAll((contact['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty));
        } else if (contact['phone'] != null && contact['phone'].toString().trim().isNotEmpty) {
          phones.add(contact['phone'].toString().trim());
        }
        setState(() => _clientPhones = phones);
      }
    } catch (e) {
      debugPrint('Failed to load client phones: $e');
    }
  }

  Future<void> _loadPackedOrders(String clientName) async {
    try {
      final resp = await _apiService.getFilteredOrders(status: 'Billed', client: clientName);
      // Response is { orders: { date: { client: [rows] } }, clients: [...] }
      final ordersMap = resp.data is Map && resp.data.containsKey('orders')
          ? resp.data['orders'] as Map?
          : (resp.data is Map ? resp.data as Map : null);
      if (ordersMap == null) return;
      final orders = <Map<String, dynamic>>[];
      ordersMap.forEach((date, clients) {
        if (clients is Map) {
          clients.forEach((client, rows) {
            if (rows is List) {
              for (final row in rows) {
                if (row is List && row.isNotEmpty) {
                  // row indices: [0]=date, [1]=billing, [2]=client, [3]=lot,
                  // [4]=grade, [5]=bagbox, [6]=no, [7]=kgs, [8]=price,
                  // [9]=brand, [10]=status, [11]=notes, [12]=docId
                  final rawId = row.length > 12 ? row[12].toString() : row[row.length - 1].toString();
                  final docId = rawId.startsWith('-') ? rawId.substring(1) : rawId;
                  orders.add({
                    'id': docId,
                    'index': docId,
                    'grade': row.length > 4 ? '${row[4]}' : '',
                    'bagbox': row.length > 5 ? '${row[5]}' : '',
                    'no': row.length > 6 ? '${row[6]}' : '',
                    'kgs': row.length > 7 ? '${row[7]}' : '',
                    'rate': row.length > 8 ? '${row[8]}' : '',
                    'billing': row.length > 1 ? '${row[1]}' : '',
                    'date': '$date',
                  });
                }
              }
            }
          });
        }
      });
      setState(() {
        _packedOrders = orders.take(30).toList();
      });
    } catch (e) {
      debugPrint('Failed to load packed orders: $e');
    }
  }

  /// Open iPhone's native full-screen camera via ImagePicker
  Future<void> _captureWithNativeCamera() async {
    try {
      final picker = ImagePicker();
      final xFile = await picker.pickImage(source: ImageSource.camera, imageQuality: 100);
      if (xFile == null) return;
      final bytes = await xFile.readAsBytes();
      final isFirst = _capturedImages.isEmpty;
      setState(() {
        _capturedImages.add(bytes);
      });
      // Run OCR only on the first image
      if (isFirst) {
        final version = ++_ocrVersion;
        setState(() => _isRunningOcr = true);
        _runOcr(xFile.path, version);
      }
    } catch (e) {
      debugPrint('Native camera error: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final picker = ImagePicker();
      // Allow multi-image selection from gallery
      final xFiles = await picker.pickMultiImage(imageQuality: 100);
      if (xFiles.isEmpty) return;
      final isFirst = _capturedImages.isEmpty;
      for (final xFile in xFiles) {
        final bytes = await xFile.readAsBytes();
        setState(() {
          _capturedImages.add(bytes);
        });
      }
      // Run OCR only on the first image if this is the first pick
      if (isFirst && _capturedImages.isNotEmpty) {
        final version = ++_ocrVersion;
        setState(() => _isRunningOcr = true);
        _runOcr(xFiles.first.path, version);
      }
    } catch (e) {
      debugPrint('Gallery pick error: $e');
    }
  }

  /// Run OCR on the captured image.
  /// Strategy: Native Apple Vision (iOS) → ML Kit fallback → Server-side fallback
  Future<void> _runOcr(String imagePath, int version, {int attempt = 0}) async {
    try {
      debugPrint('[OCR] Starting OCR v$version attempt=$attempt on: $imagePath');
      if (mounted) setState(() { _ocrError = null; _ocrCompanyDetected = false; });

      String fullText = '';
      List<String> blockTexts = [];

      // ── Strategy 1: Native Apple Vision framework (iOS only, most reliable) ──
      if (attempt == 0 && defaultTargetPlatform == TargetPlatform.iOS) {
        try {
          debugPrint('[OCR] Trying native Apple Vision OCR...');
          final result = await _nativeOcrChannel.invokeMethod<Map>('recognizeFromPath', {
            'imagePath': imagePath,
          });

          if (result != null && result['success'] == true) {
            fullText = result['text']?.toString() ?? '';
            blockTexts = (result['blocks'] as List?)?.map((b) => b.toString()).toList() ?? [];
            debugPrint('[OCR] Apple Vision: ${fullText.length} chars, ${blockTexts.length} blocks');
          } else {
            debugPrint('[OCR] Apple Vision failed: ${result?['error']}');
          }
        } on PlatformException catch (e) {
          debugPrint('[OCR] Apple Vision platform error: ${e.message}');
        } catch (e) {
          debugPrint('[OCR] Apple Vision error: $e');
        }
      }

      // ── Strategy 2: Native Apple Vision from bytes (if path-based failed) ──
      if (fullText.isEmpty && attempt == 0 && defaultTargetPlatform == TargetPlatform.iOS && _capturedImages.isNotEmpty) {
        try {
          debugPrint('[OCR] Trying Apple Vision from bytes...');
          final result = await _nativeOcrChannel.invokeMethod<Map>('recognizeFromBytes', {
            'imageBytes': _capturedImages.first,
          });

          if (result != null && result['success'] == true) {
            fullText = result['text']?.toString() ?? '';
            blockTexts = (result['blocks'] as List?)?.map((b) => b.toString()).toList() ?? [];
            debugPrint('[OCR] Apple Vision (bytes): ${fullText.length} chars, ${blockTexts.length} blocks');
          }
        } catch (e) {
          debugPrint('[OCR] Apple Vision bytes error: $e');
        }
      }

      // ── Strategy 3: Google ML Kit (fallback for non-iOS or if Vision fails) ──
      if (fullText.isEmpty && attempt <= 1) {
        try {
          debugPrint('[OCR] Trying ML Kit ${attempt == 0 ? "default" : "latin"} recognizer...');
          final imageFile = File(imagePath);
          if (await imageFile.exists() && await imageFile.length() > 0) {
            final inputImage = InputImage.fromFile(imageFile);
            final textRecognizer = attempt == 0
                ? TextRecognizer()
                : TextRecognizer(script: TextRecognitionScript.latin);
            final recognizedText = await textRecognizer.processImage(inputImage);
            await textRecognizer.close();

            fullText = recognizedText.text;
            blockTexts = recognizedText.blocks.map((b) => b.text).toList();
            debugPrint('[OCR] ML Kit: ${fullText.length} chars, ${blockTexts.length} blocks');
          }
        } catch (e) {
          debugPrint('[OCR] ML Kit error: $e');
        }
      }

      // Log results
      if (fullText.isNotEmpty) {
        debugPrint('[OCR] Text preview: ${fullText.substring(0, fullText.length > 500 ? 500 : fullText.length)}');
        for (int i = 0; i < blockTexts.length && i < 10; i++) {
          debugPrint('[OCR] Block $i: ${blockTexts[i].replaceAll('\n', ' | ')}');
        }
      }

      if (!mounted || version != _ocrVersion) {
        debugPrint('[OCR] v$version stale, discarding');
        return;
      }

      // ── Escalation: if still empty, try next attempt or server fallback ──
      if (fullText.isEmpty) {
        if (attempt == 0) {
          return _runOcr(imagePath, version, attempt: 1);
        }
        if (attempt == 1 && _capturedImages.isNotEmpty) {
          // Try PNG re-encode + ML Kit Latin
          try {
            final pngBytes = await compute(_decodeAndReencode, _capturedImages.first);
            if (pngBytes != null) {
              final tempDir = await getTemporaryDirectory();
              final retryFile = File('${tempDir.path}/dispatch_ocr_retry_$version.png');
              await retryFile.writeAsBytes(pngBytes);
              return _runOcr(retryFile.path, version, attempt: 2);
            }
          } catch (e) {
            debugPrint('[OCR] Re-encode failed: $e');
          }
        }
      }

      // ── Final fallback: server-side OCR ──
      if (fullText.isEmpty && _capturedImages.isNotEmpty) {
        debugPrint('[OCR] All on-device attempts empty — trying server OCR...');
        if (mounted) setState(() => _ocrError = 'On-device OCR empty — trying cloud OCR...');
        await _runServerOcr(version);
        return;
      }

      setState(() { _ocrRawText = fullText; _isRunningOcr = false; });

      if (fullText.isEmpty) {
        debugPrint('[OCR] WARNING: All OCR attempts returned empty');
        if (mounted) setState(() => _ocrError = 'OCR returned empty — try re-capturing');
        return;
      }

      await _processOcrResult(fullText, blockTexts, version);
    } catch (e, stackTrace) {
      debugPrint('[OCR] Error: $e');
      debugPrint('[OCR] Stack: $stackTrace');
      if (mounted) setState(() { _isRunningOcr = false; _ocrError = 'OCR failed: $e'; });
    }
  }

  /// Fallback: Run OCR on the server via Google Cloud Vision API
  Future<void> _runServerOcr(int version) async {
    if (_capturedImages.isEmpty || !mounted) return;
    try {
      debugPrint('[OCR-Server] Sending image to server for Cloud Vision OCR...');
      final imageBase64 = base64Encode(_capturedImages.first);
      await _clientsReady;
      final clientNames = _allClients.map((c) => c['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList();

      final response = await ApiService().runServerOcr(
        imageBase64: imageBase64,
        clientNames: clientNames,
      );

      if (!mounted || version != _ocrVersion) return;

      final data = response.data;
      if (data['success'] != true) {
        debugPrint('[OCR-Server] Failed: ${data['error']}');
        setState(() { _isRunningOcr = false; _ocrError = 'Cloud OCR: ${data['error'] ?? 'unknown error'}'; });
        return;
      }

      final fullText = data['text']?.toString() ?? '';
      debugPrint('[OCR-Server] Got ${fullText.length} chars from server');

      setState(() {
        _ocrRawText = fullText;
        _isRunningOcr = false;
        _ocrError = null;
      });

      if (fullText.isEmpty) {
        setState(() => _ocrError = 'Cloud OCR also returned empty — try a clearer photo');
        return;
      }

      // Apply server-detected company
      final serverCompany = data['company']?.toString();
      if (serverCompany != null && serverCompany.isNotEmpty && mounted) {
        // Map ESPL/SYGT to full names
        final companyFull = serverCompany.toUpperCase().contains('ESPL')
            ? 'Emperor Spices Pvt Ltd'
            : serverCompany.toUpperCase().contains('SYGT')
                ? 'Sri Yogaganapathi Traders'
                : serverCompany;
        setState(() { _companyName = companyFull; _ocrCompanyDetected = true; });
        debugPrint('[OCR-Server] Company: $companyFull');
      }

      // Apply server-detected invoice number
      final serverInvNo = data['invoiceNumber']?.toString();
      if (serverInvNo != null && serverInvNo.isNotEmpty && _invoiceNumber == null && mounted) {
        setState(() { _invoiceNumber = serverInvNo; _invoiceNumberController.text = serverInvNo; });
        debugPrint('[OCR-Server] Invoice Number: $serverInvNo');
      }

      // Apply server-detected invoice date
      final serverInvDate = data['invoiceDate']?.toString();
      if (serverInvDate != null && serverInvDate.isNotEmpty && _invoiceDate == null && mounted) {
        try {
          final dt = DateTime.parse(serverInvDate);
          setState(() { _invoiceDate = dt; _selectedDate = dt; });
          debugPrint('[OCR-Server] Invoice Date: $serverInvDate');
        } catch (_) {}
      }

      // Find top client matches from the server OCR text and show popup
      if (_selectedClient == null && mounted) {
        final topMatches = findTopClientMatches(fullText, clientNames);
        if (topMatches.isNotEmpty) {
          for (final m in topMatches) {
            debugPrint('[OCR-Server] Match: ${m.name} → ${m.percentage}%');
          }
          _showClientSuggestionPopup(topMatches);
        }
      }

      // If server OCR found text but nothing matched, show hint
      if (serverCompany == null && _selectedClient == null && mounted) {
        setState(() {
          _ocrError = 'Cloud OCR found text but no fields matched. Text: "${fullText.substring(0, fullText.length > 100 ? 100 : fullText.length).replaceAll('\n', ' ')}..."';
        });
      }
    } catch (e) {
      debugPrint('[OCR-Server] Error: $e');
      if (mounted) setState(() { _isRunningOcr = false; _ocrError = 'Cloud OCR failed: $e'; });
    }
  }

  /// Retry OCR — try native Apple Vision from bytes, then server-side fallback
  Future<void> _retryOcr() async {
    if (_capturedImages.isEmpty) return;
    final version = ++_ocrVersion;
    setState(() { _isRunningOcr = true; _ocrError = null; });

    // Try native Vision from bytes first
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        debugPrint('[OCR-Retry] Trying Apple Vision from bytes...');
        final result = await _nativeOcrChannel.invokeMethod<Map>('recognizeFromBytes', {
          'imageBytes': _capturedImages.first,
        });
        if (result != null && result['success'] == true) {
          final text = result['text']?.toString() ?? '';
          if (text.isNotEmpty) {
            debugPrint('[OCR-Retry] Apple Vision: ${text.length} chars');
            // Process the result through the field extraction pipeline
            setState(() { _ocrRawText = text; _isRunningOcr = false; _ocrError = null; });
            await _processOcrResult(text, (result['blocks'] as List?)?.map((b) => b.toString()).toList() ?? [], version);
            return;
          }
        }
      } catch (e) {
        debugPrint('[OCR-Retry] Apple Vision error: $e');
      }
    }

    // Fallback to server-side OCR
    await _runServerOcr(version);
  }

  /// Process OCR text result — detect company and show client suggestions popup
  Future<void> _processOcrResult(String fullText, List<String> blockTexts, int version) async {
    if (!mounted || version != _ocrVersion) return;

    // Debug: log the full OCR text for diagnosis
    debugPrint('[OCR-EXTRACT] ════ Full OCR Text (${fullText.length} chars) ════');
    final lines = fullText.split('\n');
    for (int i = 0; i < lines.length; i++) {
      debugPrint('[OCR-EXTRACT] Line $i: ${lines[i]}');
    }
    debugPrint('[OCR-EXTRACT] ════ End OCR Text ════');

    // 1. Auto-detect company — try full text first, then individual blocks
    String? detectedCompany = extractCompanyFromBill(fullText);
    if (detectedCompany == null) {
      for (final block in blockTexts) {
        detectedCompany = extractCompanyFromBill(block);
        if (detectedCompany != null) break;
      }
    }
    if (detectedCompany != null && mounted) {
      setState(() { _companyName = detectedCompany!; _ocrCompanyDetected = true; });
      debugPrint('[OCR-EXTRACT] ✓ Detected company: $detectedCompany');
    } else {
      debugPrint('[OCR-EXTRACT] ✗ No company detected');
    }

    // 1b. Auto-detect invoice number
    String? detectedInvNo = extractInvoiceNumber(fullText);
    if (detectedInvNo == null) {
      for (final block in blockTexts) {
        detectedInvNo = extractInvoiceNumber(block);
        if (detectedInvNo != null) break;
      }
    }
    if (detectedInvNo != null && mounted) {
      setState(() { _invoiceNumber = detectedInvNo; _invoiceNumberController.text = detectedInvNo!; });
      debugPrint('[OCR-EXTRACT] ✓ Detected invoice number: $detectedInvNo');
    }

    // 1c. Auto-detect invoice date
    DateTime? detectedDate = extractInvoiceDate(fullText);
    if (detectedDate == null) {
      for (final block in blockTexts) {
        detectedDate = extractInvoiceDate(block);
        if (detectedDate != null) break;
      }
    }
    if (detectedDate != null && mounted) {
      setState(() { _invoiceDate = detectedDate; _selectedDate = detectedDate!; });
      debugPrint('[OCR-EXTRACT] ✓ Detected invoice date: $detectedDate');
    }

    // 2. Wait for clients to load, then find top matches
    await _clientsReady;
    final clientNames = _allClients.map((c) => c['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList();
    debugPrint('[OCR-EXTRACT] Matching against ${clientNames.length} known clients');

    // Find top matches from full text first
    List<ClientMatch> topMatches = findTopClientMatches(fullText, clientNames);

    // If no good matches from full text, try individual blocks
    if (topMatches.isEmpty || topMatches.first.score < 0.15) {
      for (final block in blockTexts) {
        final blockMatches = findTopClientMatches(block, clientNames);
        if (blockMatches.isNotEmpty && blockMatches.first.score > (topMatches.isEmpty ? 0.0 : topMatches.first.score)) {
          topMatches = blockMatches;
          debugPrint('[OCR-EXTRACT] Better matches from block: "${block.replaceAll('\n', ' ').substring(0, block.length > 80 ? 80 : block.length)}"');
        }
      }
    }

    for (final m in topMatches) {
      debugPrint('[OCR-EXTRACT] Match: ${m.name} → ${m.percentage}%');
    }

    // 3. Show popup with top matches if any found
    if (topMatches.isNotEmpty && _selectedClient == null && mounted) {
      _showClientSuggestionPopup(topMatches);
    } else if (topMatches.isEmpty) {
      debugPrint('[OCR-EXTRACT] ✗ No client matches found');
    }

    // Show helpful message if nothing auto-detected
    if (detectedCompany == null && topMatches.isEmpty && mounted) {
      setState(() {
        _ocrError = 'Could not auto-detect fields. Text: "${fullText.substring(0, fullText.length > 120 ? 120 : fullText.length).replaceAll('\n', ' ')}..."';
      });
    }
  }

  /// Show bottom sheet with top client matches for user to select
  void _showClientSuggestionPopup(List<ClientMatch> matches) {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Title
            Row(
              children: [
                const Icon(Icons.document_scanner_outlined, size: 22, color: AppTheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Client detected from document',
                    style: GoogleFonts.outfit(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.primary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Select the correct client name:',
              style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.muted),
            ),
            const SizedBox(height: 16),

            // Top matches
            ...matches.asMap().entries.map((entry) {
              final idx = entry.key;
              final match = entry.value;
              final isTop = idx == 0;
              final pct = match.percentage;

              // Color based on score
              final Color barColor;
              final Color bgColor;
              if (pct >= 80) {
                barColor = const Color(0xFF10B981);
                bgColor = const Color(0xFF10B981).withValues(alpha: 0.06);
              } else if (pct >= 50) {
                barColor = const Color(0xFFF59E0B);
                bgColor = const Color(0xFFF59E0B).withValues(alpha: 0.06);
              } else {
                barColor = const Color(0xFF6B7280);
                bgColor = const Color(0xFF6B7280).withValues(alpha: 0.04);
              }

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _selectClient(match.name);
                      setState(() => _clientTextController.text = match.name);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Row(
                        children: [
                          // Rank indicator
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isTop ? barColor : Colors.transparent,
                              border: Border.all(color: barColor, width: 2),
                            ),
                            child: Center(
                              child: Text(
                                '${idx + 1}',
                                style: GoogleFonts.manrope(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: isTop ? Colors.white : barColor,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          // Name + score
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  match.name,
                                  style: GoogleFonts.manrope(
                                    fontSize: 15,
                                    fontWeight: isTop ? FontWeight.w700 : FontWeight.w600,
                                    color: const Color(0xFF1F2937),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // Score bar
                                Row(
                                  children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: LinearProgressIndicator(
                                          value: match.score,
                                          backgroundColor: Colors.grey.shade200,
                                          color: barColor,
                                          minHeight: 6,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '$pct% match',
                                      style: GoogleFonts.manrope(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: barColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.chevron_right, color: barColor, size: 22),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),

            const SizedBox(height: 8),
            // Skip button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close, size: 18),
                label: Text('None of these — select manually', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.muted,
                  side: BorderSide(color: Colors.grey.shade300),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectClient(String clientName) {
    setState(() {
      _selectedClient = clientName;
      _clientPhones = [];
      _packedOrders = [];
      _linkedOrderIds = [];
    });
    _loadClientPhones(clientName);
    _loadPackedOrders(clientName);
  }

  Future<void> _sendAndStore() async {
    // Validate all required fields before sending
    final missingFields = <String>[];
    if (_capturedImages.isEmpty) missingFields.add('Photo');
    if (_selectedClient == null) missingFields.add('Client');
    if (_companyName.isEmpty) missingFields.add('Company');
    if (_invoiceNumberController.text.trim().isEmpty) missingFields.add('Invoice Number');

    if (missingFields.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Missing: ${missingFields.join(', ')}'),
          backgroundColor: const Color(0xFFEF4444),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // Capture all form data before resetting
    final allImageBytes = List<Uint8List>.from(_capturedImages);
    final clientName = _selectedClient!;
    final companyName = _companyName;
    final date = _selectedDate;
    final invoiceNo = _invoiceNumberController.text.trim();
    final invoiceDateStr = _invoiceDate != null ? DateFormat('yyyy-MM-dd').format(_invoiceDate!) : null;
    final notes = _notesController.text.trim();
    final phones = List<String>.from(_clientPhones);
    final orderIds = List<String>.from(_linkedOrderIds);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final createdBy = auth.username ?? 'unknown';

    // Build linkedOrders detail list from selected order IDs
    final linkedOrders = orderIds.map((id) {
      final order = _packedOrders.firstWhere(
        (o) => (o['index']?.toString() ?? o['id']?.toString()) == id,
        orElse: () => <String, dynamic>{},
      );
      if (order.isEmpty) return null;
      return {
        'id': id,
        'grade': order['grade'] ?? '',
        'bagbox': order['bagbox'] ?? '',
        'no': order['no'] ?? '',
        'kgs': order['kgs'] ?? '',
        'rate': order['rate'] ?? '',
        'date': order['date'] ?? '',
      };
    }).whereType<Map<String, dynamic>>().toList();

    // Show loading indicator
    setState(() => _isSending = true);

    try {
      final imagesBase64 = await Future.wait(
        allImageBytes.map((bytes) => _prepareImageForUpload(bytes)),
      );
      final dateStr = DateFormat('yyyy-MM-dd').format(date);

      final resp = await _apiService.createDispatchDocument(
        imagesBase64: imagesBase64,
        clientName: clientName,
        date: dateStr,
        companyName: companyName,
        notes: notes.isNotEmpty ? notes : null,
        invoiceNumber: invoiceNo.isNotEmpty ? invoiceNo : null,
        invoiceDate: invoiceDateStr,
        linkedOrderIds: orderIds.isNotEmpty ? orderIds : null,
        linkedOrders: linkedOrders.isNotEmpty ? linkedOrders : null,
        phones: phones,
        createdBy: createdBy,
      );

      if (mounted) setState(() => _isSending = false);

      if (resp.data['success'] == true) {
        // Show success popup FIRST (before resetting form to avoid rebuild killing dialog)
        if (mounted) await _showDispatchSuccessPopup();
        // Reset form AFTER popup closes
        if (mounted) _softResetForm();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed: ${resp.data['error'] ?? 'Unknown error'}'),
              backgroundColor: const Color(0xFFEF4444),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isSending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save dispatch document: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  void _softResetForm() {
    setState(() {
      _capturedImages = [];
      _ocrRawText = null; _ocrError = null; _ocrCompanyDetected = false;
      _selectedClient = null;
      _clientTextController.clear();
      _clientPhones = [];
      _notesController.clear();
      _invoiceNumber = null;
      _invoiceDate = null;
      _invoiceNumberController.clear();
      _linkedOrderIds = [];
      _packedOrders = [];
    });
  }

  Future<void> _showDispatchSuccessPopup() async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.all(32),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 48),
            ),
            const SizedBox(height: 20),
            const Text(
              '✅ Sent Successfully',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF4A5568)),
            ),
            const SizedBox(height: 12),
            const Text(
              'Dispatch document saved & WhatsApp sent.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  // Stay on fresh dispatch page
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF185A9D),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text('➕ Add More Document', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onUploaded(); // Switch to history tab
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF22C55E),
                  side: const BorderSide(color: Color(0xFF22C55E)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text('📋 View History', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
    // Outside tap dismisses → form already soft-reset above
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Camera / Preview ──
          _buildCameraSection(),
          const SizedBox(height: 16),

          // ── OCR Status ──
          if (_isRunningOcr)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text('Scanning for client & company...', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.muted)),
                ],
              ),
            ),

          // ── OCR Error Banner ──
          if (_ocrError != null && !_isRunningOcr)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, size: 16, color: Color(0xFFEF4444)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_ocrError!, style: GoogleFonts.manrope(fontSize: 11, color: const Color(0xFFEF4444)))),
                  if (_capturedImages.isNotEmpty)
                    GestureDetector(
                      onTap: _retryOcr,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('Retry OCR', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w600, color: const Color(0xFFEF4444))),
                      ),
                    ),
                ],
              ),
            ),

          // ── OCR Results Banner ──
          if (_ocrRawText != null && !_isRunningOcr && _ocrError == null &&
              (_selectedClient != null || _ocrCompanyDetected))
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome, size: 16, color: Color(0xFF10B981)),
                      const SizedBox(width: 8),
                      Text('Auto-detected from document',
                          style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: const Color(0xFF10B981))),
                    ],
                  ),
                  if (_selectedClient != null) ...[
                    const SizedBox(height: 4),
                    Text('  Client: $_selectedClient',
                        style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF059669))),
                  ],
                  if (_ocrCompanyDetected) ...[
                    const SizedBox(height: 2),
                    Text('  Company: ${_companyName.contains('Emperor') ? 'ESPL' : 'SYGT'}',
                        style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF059669))),
                  ],
                ],
              ),
            ),

          // ── Client Selector ──
          _buildClientSelector(),
          const SizedBox(height: 12),

          // ── Company Toggle ──
          _buildCompanyToggle(),
          const SizedBox(height: 12),

          // ── Date Picker ──
          _buildDatePicker(),
          const SizedBox(height: 12),

          // ── Invoice Number (OCR-detected, editable) ──
          TextField(
            controller: _invoiceNumberController,
            decoration: InputDecoration(
              labelText: 'Invoice Number',
              hintText: 'Auto-detected from OCR',
              prefixIcon: const Icon(Icons.receipt_long, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            style: GoogleFonts.manrope(fontSize: 14),
            onChanged: (v) => _invoiceNumber = v.trim().isNotEmpty ? v.trim() : null,
          ),
          const SizedBox(height: 12),

          // ── Optional Order Linking ──
          if (_selectedClient != null && _packedOrders.isNotEmpty)
            _buildOrderLinking(),
          if (_selectedClient != null && _packedOrders.isNotEmpty)
            const SizedBox(height: 12),

          // ── Notes ──
          _buildNotesField(),
          const SizedBox(height: 20),

          // ── Phone Info (visible only to superadmin) ──
          if (_clientPhones.isNotEmpty && Provider.of<AuthProvider>(context, listen: false).role == 'superadmin')
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF25D366).withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF25D366).withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.chat, size: 16, color: Color(0xFF25D366)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'WhatsApp: ${_clientPhones.join(', ')}',
                      style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF25D366)),
                    ),
                  ),
                ],
              ),
            ),

          // ── Store & Send Button ──
          Builder(builder: (context) {
            final isSuperAdmin = Provider.of<AuthProvider>(context, listen: false).role == 'superadmin';
            final hasPhones = _clientPhones.isNotEmpty;
            // Only superadmin sees phone-related labels/colors
            final showPhoneHints = isSuperAdmin && hasPhones;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton.icon(
                  onPressed: _capturedImages.isEmpty || _selectedClient == null || _isSending
                      ? null
                      : _sendAndStore,
                  icon: _isSending
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(showPhoneHints ? Icons.send_rounded : Icons.save_rounded),
                  label: Text(
                    _isSending
                        ? 'Sending...'
                        : showPhoneHints
                            ? 'Store & Send via WhatsApp'
                            : _selectedClient != null
                                ? 'Store & Send'
                                : 'Select client to send',
                    style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: showPhoneHints ? const Color(0xFF25D366) : AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 2,
                  ),
                ),

                // ── Phone status hint (superadmin only) ──
                if (isSuperAdmin && _selectedClient != null && _clientPhones.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 14, color: Colors.orange.shade700),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'No WhatsApp number found for this client. Will store only. Add phone in client contacts to enable sending.',
                            style: GoogleFonts.manrope(fontSize: 11, color: Colors.orange.shade700),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildCameraSection() {
    if (_capturedImages.isNotEmpty) {
      // Show image carousel with add more / remove / clear all
      return Column(
        children: [
          SizedBox(
            height: 300,
            child: PageView.builder(
              itemCount: _capturedImages.length,
              itemBuilder: (context, index) {
                return Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(_capturedImages[index], width: double.infinity, height: 300, fit: BoxFit.cover),
                    ),
                    // Page indicator
                    Positioned(
                      top: 8, left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                        child: Text('${index + 1} / ${_capturedImages.length}',
                            style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                    // Remove this image
                    Positioned(
                      top: 8, right: 8,
                      child: _circleButton(Icons.close, 'Remove', () {
                        setState(() {
                          _capturedImages.removeAt(index);
                          if (_capturedImages.isEmpty) {
                            _ocrRawText = null; _ocrError = null; _ocrCompanyDetected = false;
                            _selectedClient = null;
                            _clientTextController.clear();
                            _clientPhones = [];
                            _linkedOrderIds = [];
                            _packedOrders = [];
                          }
                        });
                      }),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // Add more + Clear all buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _pickFromGallery,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text('Add from Gallery', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _captureWithNativeCamera,
                icon: const Icon(Icons.camera_alt_rounded, size: 18),
                label: Text('Add Capture', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _capturedImages = [];
                    _ocrRawText = null; _ocrError = null; _ocrCompanyDetected = false;
                    _selectedClient = null;
                    _clientTextController.clear();
                    _clientPhones = [];
                    _linkedOrderIds = [];
                    _packedOrders = [];
                  });
                },
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text('Clear', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFEF4444),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ],
      );
    }

    // No image yet — show Upload Media + Capture buttons
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 1.5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined, size: 40, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            'Capture bill documents (multiple)',
            style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.muted),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _pickFromGallery,
                icon: const Icon(Icons.photo_library_outlined, size: 20),
                label: Text('Upload Media', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.primary,
                  elevation: 1,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.3)),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: _captureWithNativeCamera,
                icon: const Icon(Icons.camera_alt_rounded, size: 20),
                label: Text('Capture', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  elevation: 2,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black54,
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Widget _buildClientSelector() {
    return Autocomplete<String>(
      optionsBuilder: (textEditingValue) {
        if (textEditingValue.text.isEmpty) {
          return _allClients.map((c) => c['name']?.toString() ?? '').where((n) => n.isNotEmpty);
        }
        final query = textEditingValue.text.toLowerCase();
        return _allClients
            .map((c) => c['name']?.toString() ?? '')
            .where((n) => n.isNotEmpty && n.toLowerCase().contains(query));
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
        // Sync with OCR-detected client
        if (_clientTextController.text.isNotEmpty && controller.text.isEmpty) {
          controller.text = _clientTextController.text;
        }
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Client Name *',
            prefixIcon: const Icon(Icons.person_outline),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.white,
          ),
          style: GoogleFonts.manrope(fontSize: 14),
        );
      },
      onSelected: (clientName) {
        _clientTextController.text = clientName;
        _selectClient(clientName);
      },
    );
  }

  Widget _buildCompanyToggle() {
    return Row(
      children: [
        Text('Company: ', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primary)),
        const SizedBox(width: 8),
        Expanded(
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'Sri Yogaganapathi Traders', label: Text('SYGT', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 'Emperor Spices Pvt Ltd', label: Text('ESPL', style: TextStyle(fontSize: 12))),
            ],
            selected: {_companyName},
            onSelectionChanged: (val) => setState(() => _companyName = val.first),
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected) ? AppTheme.primary.withOpacity(0.1) : Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDatePicker() {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _selectedDate,
          firstDate: DateTime(2024),
          lastDate: DateTime.now().add(const Duration(days: 7)),
        );
        if (picked != null) setState(() => _selectedDate = picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.titaniumBorder),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today_outlined, size: 18, color: AppTheme.muted),
            const SizedBox(width: 12),
            Text(
              DateFormat('dd MMM yyyy').format(_selectedDate),
              style: GoogleFonts.manrope(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderLinking() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.inventory_2_outlined, size: 18, color: AppTheme.primary),
            const SizedBox(width: 8),
            Text('Billed Orders', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primary)),
            const Spacer(),
            if (_linkedOrderIds.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_linkedOrderIds.length} selected',
                  style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text('Tap to select orders for this dispatch:', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.muted)),
        const SizedBox(height: 10),
        ..._packedOrders.map((order) {
          final docId = order['index']?.toString() ?? order['id']?.toString() ?? '';
          final grade = order['grade']?.toString() ?? '';
          final bagbox = order['bagbox']?.toString() ?? 'Box';
          final no = order['no']?.toString() ?? '';
          final kgs = order['kgs']?.toString() ?? '';
          final rate = order['rate']?.toString() ?? '';
          final date = order['date']?.toString() ?? '';
          final isSelected = _linkedOrderIds.contains(docId);

          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: isSelected ? AppTheme.primary.withValues(alpha: 0.08) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  setState(() {
                    if (isSelected) {
                      _linkedOrderIds.remove(docId);
                    } else {
                      _linkedOrderIds.add(docId);
                    }
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? AppTheme.primary.withValues(alpha: 0.4) : Colors.grey.shade300,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Checkbox
                      Container(
                        width: 22, height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected ? AppTheme.primary : Colors.transparent,
                          border: Border.all(
                            color: isSelected ? AppTheme.primary : Colors.grey.shade400,
                            width: 2,
                          ),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check, size: 14, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      // Order details
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Grade (main info)
                            Text(
                              grade.isNotEmpty ? grade : 'Order',
                              style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: const Color(0xFF1F2937)),
                            ),
                            const SizedBox(height: 3),
                            // Details row: boxes × qty @ rate
                            Row(
                              children: [
                                if (no.isNotEmpty) ...[
                                  Icon(Icons.widgets_outlined, size: 13, color: Colors.grey.shade600),
                                  const SizedBox(width: 3),
                                  Text('$no $bagbox', style: GoogleFonts.manrope(fontSize: 12, color: Colors.grey.shade700)),
                                  const SizedBox(width: 10),
                                ],
                                if (kgs.isNotEmpty) ...[
                                  Icon(Icons.scale_outlined, size: 13, color: Colors.grey.shade600),
                                  const SizedBox(width: 3),
                                  Text('${kgs}kg', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                                  const SizedBox(width: 10),
                                ],
                                if (rate.isNotEmpty && rate != '0') ...[
                                  Icon(Icons.currency_rupee, size: 12, color: Colors.grey.shade600),
                                  Text(rate, style: GoogleFonts.manrope(fontSize: 12, color: Colors.grey.shade700)),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Date badge
                      if (date.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(date, style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.muted)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildNotesField() {
    return TextField(
      controller: _notesController,
      maxLines: 2,
      decoration: InputDecoration(
        labelText: 'Notes (optional)',
        prefixIcon: const Icon(Icons.note_outlined),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
      style: GoogleFonts.manrope(fontSize: 14),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// HISTORY TAB
// ══════════════════════════════════════════════════════════════════════════════
class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> with SingleTickerProviderStateMixin, OptimisticActionMixin {
  @override
  OperationQueue get operationQueue => context.read<OperationQueue>();

  final ApiService _apiService = ApiService();
  List<Map<String, dynamic>> _documents = [];
  bool _isLoading = true;
  late TabController _tabController;

  // Filters
  String? _clientFilter;
  DateTime? _dateFilter;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadDocuments();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDocuments() async {
    setState(() => _isLoading = true);
    try {
      final resp = await _apiService.getDispatchDocuments(limit: 200);
      if (resp.data['documents'] != null) {
        setState(() {
          _documents = List<Map<String, dynamic>>.from(resp.data['documents']);
        });
      }
    } catch (e) {
      debugPrint('Failed to load dispatch documents: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<String> get _uniqueClients {
    final clients = _documents.map((d) => d['clientName']?.toString() ?? '').where((c) => c.isNotEmpty).toSet().toList();
    clients.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return clients;
  }

  List<Map<String, dynamic>> _filterByCompany(String companyKey) {
    return _documents.where((d) {
      // Company filter
      final company = (d['companyName'] ?? '').toString().toLowerCase();
      final matchCompany = companyKey == 'ESPL'
          ? (company == 'espl' || company.contains('emperor'))
          : (company == 'sygt' || company.contains('yoga') || company.contains('ganapathi')
              || (!company.contains('emperor') && company != 'espl'));
      if (!matchCompany) return false;

      // Client filter
      if (_clientFilter != null && _clientFilter!.isNotEmpty) {
        if (d['clientName']?.toString() != _clientFilter) return false;
      }

      // Date filter
      if (_dateFilter != null) {
        final raw = (d['invoiceDate'] ?? d['date'] ?? '').toString();
        if (raw.isNotEmpty) {
          try {
            final docDate = DateTime.parse(raw);
            if (docDate.year != _dateFilter!.year || docDate.month != _dateFilter!.month || docDate.day != _dateFilter!.day) return false;
          } catch (_) {
            return false;
          }
        } else {
          return false;
        }
      }

      return true;
    }).toList()
      ..sort((a, b) {
        final dateA = (a['invoiceDate'] ?? a['date'] ?? a['createdAt'] ?? '').toString();
        final dateB = (b['invoiceDate'] ?? b['date'] ?? b['createdAt'] ?? '').toString();
        return dateB.compareTo(dateA);
      });
  }

  String _formatDisplayDate(Map<String, dynamic> doc) {
    final raw = (doc['invoiceDate'] ?? doc['date'] ?? '').toString();
    if (raw.isEmpty) return '';
    try {
      final dt = DateTime.parse(raw);
      return DateFormat('dd-MMM-yy').format(dt);
    } catch (_) {
      return raw;
    }
  }

  void _showDocumentDetail(Map<String, dynamic> doc) {
    final imageUrl = doc['imageUrl']?.toString() ?? '';
    final clientName = doc['clientName']?.toString() ?? '';
    final invoiceNo = doc['invoiceNumber']?.toString() ?? '';
    final displayDate = _formatDisplayDate(doc);
    final linkedOrders = doc['linkedOrders'] is List ? List<Map<String, dynamic>>.from(doc['linkedOrders']) : <Map<String, dynamic>>[];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: EdgeInsets.zero,
        titlePadding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
        title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(clientName, style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700, color: const Color(0xFF1F2937))),
                  const SizedBox(height: 2),
                  Text(
                    '${displayDate.isNotEmpty ? displayDate : 'No date'}  •  ${invoiceNo.isNotEmpty ? invoiceNo : 'No invoice'}',
                    style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.muted),
                  ),
                ],
              ),
            ),
            IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
          ],
        ),
        content: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.9,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Linked Orders ──
                if (linkedOrders.isNotEmpty) ...[
                  Row(
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 15, color: AppTheme.primary),
                      const SizedBox(width: 6),
                      Text('Tagged Orders', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                        decoration: BoxDecoration(color: AppTheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                        child: Text('${linkedOrders.length}', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...linkedOrders.map((order) {
                    final grade = order['grade']?.toString() ?? '';
                    final bagbox = order['bagbox']?.toString() ?? 'Box';
                    final no = order['no']?.toString() ?? '';
                    final kgs = order['kgs']?.toString() ?? '';
                    final rate = order['rate']?.toString() ?? '';
                    final orderDate = order['date']?.toString() ?? '';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(grade.isNotEmpty ? grade : 'Order', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700, color: const Color(0xFF1F2937))),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    if (no.isNotEmpty) ...[
                                      Icon(Icons.widgets_outlined, size: 12, color: Colors.grey.shade600),
                                      const SizedBox(width: 2),
                                      Text('$no $bagbox', style: GoogleFonts.manrope(fontSize: 11, color: Colors.grey.shade700)),
                                      const SizedBox(width: 8),
                                    ],
                                    if (kgs.isNotEmpty) ...[
                                      Icon(Icons.scale_outlined, size: 12, color: Colors.grey.shade600),
                                      const SizedBox(width: 2),
                                      Text('${kgs}kg', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                                      const SizedBox(width: 8),
                                    ],
                                    if (rate.isNotEmpty && rate != '0') ...[
                                      Icon(Icons.currency_rupee, size: 11, color: Colors.grey.shade600),
                                      Text(rate, style: GoogleFonts.manrope(fontSize: 11, color: Colors.grey.shade700)),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (orderDate.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(5)),
                              child: Text(orderDate, style: GoogleFonts.manrope(fontSize: 9, color: AppTheme.muted)),
                            ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                ],

                // ── Image ──
                if (imageUrl.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _ImageViewerScreen(
                          imageUrl: imageUrl,
                          title: '$displayDate - ${invoiceNo.isNotEmpty ? invoiceNo : 'N/A'} - $clientName',
                          clientName: clientName,
                          invoiceNumber: invoiceNo,
                          companyName: doc['companyName']?.toString() ?? '',
                        ),
                      ));
                    },
                    child: Container(
                      width: double.infinity,
                      height: 200,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.network(
                              imageUrl,
                              fit: BoxFit.cover,
                              loadingBuilder: (_, child, progress) {
                                if (progress == null) return child;
                                return Center(child: CircularProgressIndicator(
                                  value: progress.expectedTotalBytes != null
                                      ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                                      : null,
                                  strokeWidth: 2,
                                ));
                              },
                              errorBuilder: (_, __, ___) => const Center(
                                child: Icon(Icons.broken_image_outlined, size: 40, color: Colors.grey),
                              ),
                            ),
                            // Tap-to-zoom overlay
                            Positioned(
                              bottom: 6, right: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.zoom_in, size: 14, color: Colors.white),
                                    const SizedBox(width: 4),
                                    Text('Tap to zoom', style: GoogleFonts.manrope(fontSize: 10, color: Colors.white)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                const SizedBox(height: 10),

                // ── WhatsApp Status ──
                Builder(builder: (_) {
                  final waStatus = doc['whatsappStatus']?.toString() ?? '';
                  final waResults = doc['whatsappResults'] as List? ?? [];
                  final sentTo = doc['sentToPhones'] as List? ?? [];
                  final docPhones = doc['phones'] as List? ?? [];

                  IconData icon; Color iconColor; String label;
                  if (waStatus == 'sent') {
                    icon = Icons.check_circle; iconColor = const Color(0xFF10B981);
                    label = 'Sent to ${sentTo.length} number${sentTo.length > 1 ? 's' : ''}';
                  } else if (waStatus == 'partial') {
                    icon = Icons.warning_amber_rounded; iconColor = Colors.orange.shade700;
                    label = 'Sent to ${sentTo.length} of ${docPhones.length}';
                  } else if (waStatus == 'failed') {
                    icon = Icons.error_outline; iconColor = const Color(0xFFEF4444);
                    label = 'WhatsApp send failed';
                  } else if (waStatus == 'no_phones') {
                    icon = Icons.phone_disabled; iconColor = Colors.grey.shade500;
                    label = 'No phone number for client';
                  } else if (sentTo.isNotEmpty) {
                    icon = Icons.check_circle; iconColor = const Color(0xFF10B981);
                    label = 'Sent to ${sentTo.length} number${sentTo.length > 1 ? 's' : ''}';
                  } else {
                    icon = Icons.pending_outlined; iconColor = Colors.orange.shade600;
                    label = 'WhatsApp pending';
                  }

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: iconColor.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(icon, size: 16, color: iconColor),
                          const SizedBox(width: 6),
                          Text(label, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: iconColor)),
                        ]),
                        if (waResults.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          ...waResults.map((r) {
                            final rMap = r is Map ? r : <String, dynamic>{};
                            final phone = rMap['phone']?.toString() ?? '?';
                            final ok = rMap['success'] == true;
                            final err = rMap['error']?.toString() ?? '';
                            return Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(children: [
                                Icon(ok ? Icons.check : Icons.close, size: 12, color: ok ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
                                const SizedBox(width: 4),
                                Text(phone, style: GoogleFonts.manrope(fontSize: 11, color: Colors.grey.shade700)),
                                if (!ok && err.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(err, style: GoogleFonts.manrope(fontSize: 10, color: const Color(0xFFEF4444)), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                ],
                              ]),
                            );
                          }),
                        ],
                      ],
                    ),
                  );
                }),

                const SizedBox(height: 10),

                // ── Share Buttons ──
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _shareManual(ctx, doc),
                        icon: const Icon(Icons.share_rounded, size: 16),
                        label: Text('Share Manual', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF3B82F6),
                          side: const BorderSide(color: Color(0xFF3B82F6)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _resendDocument(doc);
                        },
                        icon: const Icon(Icons.send_rounded, size: 16),
                        label: Text('Share Auto', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _shareManual(BuildContext ctx, Map<String, dynamic> doc) async {
    final imageUrl = doc['imageUrl']?.toString() ?? '';
    final clientName = doc['clientName']?.toString() ?? '';
    final invoiceNo = doc['invoiceNumber']?.toString() ?? '';
    final companyName = doc['companyName']?.toString() ?? '';
    if (imageUrl.isEmpty) return;

    try {
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(children: [CircularProgressIndicator(), SizedBox(width: 20), Expanded(child: Text('Preparing...'))]),
        ),
      );

      final response = await Dio().get<List<int>>(imageUrl, options: Options(responseType: ResponseType.bytes));
      if (ctx.mounted) Navigator.of(ctx).pop();
      if (response.data == null) return;

      final tempDir = await getTemporaryDirectory();
      final companyShort = companyName.toLowerCase().contains('emperor') || companyName.toLowerCase() == 'espl' ? 'ESPL' : 'SYGT';
      final safeInvoice = invoiceNo.replaceAll(RegExp(r'[^a-zA-Z0-9\-]'), '-');
      final fileName = invoiceNo.isNotEmpty
          ? '$companyShort-$safeInvoice.jpg'
          : '$companyShort-${clientName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.jpg';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(response.data!);

      await Share.shareXFiles([XFile(file.path)], text: 'Dispatch Document - $clientName');
    } catch (e) {
      if (ctx.mounted) {
        Navigator.of(ctx, rootNavigator: true).pop();
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Share failed: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  Future<void> _resendDocument(Map<String, dynamic> doc) async {
    final clientName = doc['clientName'] ?? '';
    List<String> phones = [];

    try {
      final contactResp = await _apiService.getClientContact(clientName);
      final contact = contactResp.data['contact'];
      if (contact != null) {
        if (contact['phones'] is List && (contact['phones'] as List).isNotEmpty) {
          phones = (contact['phones'] as List).map((p) => p.toString().trim()).where((p) => p.isNotEmpty).toList();
        } else if (contact['phone'] != null && contact['phone'].toString().trim().isNotEmpty) {
          phones = [contact['phone'].toString().trim()];
        }
      }
    } catch (e) {
      debugPrint('Failed to load phones for resend: $e');
    }

    if (phones.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No phone numbers found for this client'), backgroundColor: Color(0xFFEF4444)),
        );
      }
      return;
    }

    final docId = doc['id'];

    fireAndForget(
      type: 'dispatch_resend',
      apiCall: () async {
        final resp = await _apiService.resendDispatchDocument(docId, phones);
        if (resp.data['success'] != true) {
          throw Exception(resp.data['error'] ?? 'Resend failed');
        }
        return resp.data;
      },
      onSuccess: () {
        if (mounted) _loadDocuments();
      },
      successMessage: 'Resent to ${phones.length} number${phones.length > 1 ? 's' : ''} via WhatsApp',
      failureMessage: 'Failed to resend dispatch document',
    );
  }

  Future<void> _deleteDocument(Map<String, dynamic> doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Document', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Delete dispatch document for "${doc['clientName']}"?\nThis action cannot be undone.',
            style: GoogleFonts.manrope(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFEF4444)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final docId = doc['id'];
    final index = _documents.indexWhere((d) => d['id'] == docId);
    final removed = index >= 0 ? _documents[index] : null;

    optimistic(
      type: 'dispatch_delete',
      applyLocal: () => setState(() { _documents.removeWhere((d) => d['id'] == docId); }),
      apiCall: () => _apiService.deleteDispatchDocument(docId),
      rollback: removed != null && index >= 0
          ? () => setState(() { _documents.insert(index.clamp(0, _documents.length), removed); })
          : null,
      successMessage: 'Document deleted',
      failureMessage: 'Failed to delete document',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Filters ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              // Client filter
              Expanded(
                child: GestureDetector(
                  onTap: () => _showClientPicker(),
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _clientFilter != null ? AppTheme.primary : const Color(0xFFCCCCCC)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.person_outline, size: 16, color: _clientFilter != null ? AppTheme.primary : AppTheme.muted),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _clientFilter ?? 'All clients',
                            style: GoogleFonts.manrope(
                              fontSize: 12,
                              fontWeight: _clientFilter != null ? FontWeight.w600 : FontWeight.w500,
                              color: _clientFilter != null ? AppTheme.primary : AppTheme.muted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_clientFilter != null)
                          GestureDetector(
                            onTap: () => setState(() => _clientFilter = null),
                            child: Icon(Icons.close, size: 15, color: AppTheme.muted),
                          )
                        else
                          Icon(Icons.arrow_drop_down, size: 18, color: AppTheme.muted),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Date filter
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _dateFilter ?? DateTime.now(),
                    firstDate: DateTime(2024),
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                  );
                  if (picked != null) setState(() => _dateFilter = picked);
                },
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _dateFilter != null ? AppTheme.primary : const Color(0xFFCCCCCC)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.calendar_today, size: 14, color: _dateFilter != null ? AppTheme.primary : AppTheme.muted),
                      const SizedBox(width: 6),
                      Text(
                        _dateFilter != null ? DateFormat('dd-MMM-yy').format(_dateFilter!) : 'All dates',
                        style: GoogleFonts.manrope(
                          fontSize: 12,
                          fontWeight: _dateFilter != null ? FontWeight.w600 : FontWeight.w500,
                          color: _dateFilter != null ? AppTheme.primary : AppTheme.muted,
                        ),
                      ),
                      if (_dateFilter != null) ...[
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => setState(() => _dateFilter = null),
                          child: Icon(Icons.close, size: 15, color: AppTheme.muted),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // ── Company Tabs ──
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: TabBar(
            controller: _tabController,
            onTap: (_) => setState(() {}),
            indicator: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: _tabController.index == 0 ? const Color(0xFF3B82F6) : const Color(0xFF10B981),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            labelColor: Colors.white,
            unselectedLabelColor: AppTheme.muted,
            labelStyle: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700),
            unselectedLabelStyle: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(text: 'ESPL', height: 36),
              Tab(text: 'SYGT', height: 36),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // ── Document List ──
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildCompanyList('ESPL'),
                    _buildCompanyList('SYGT'),
                  ],
                ),
        ),
      ],
    );
  }

  void _showClientPicker() {
    final clients = _uniqueClients;
    String query = '';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final filtered = query.isEmpty
              ? clients
              : clients.where((c) => c.toLowerCase().contains(query.toLowerCase())).toList();
          return AlertDialog(
            title: Text('Select Client', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 16)),
            contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'Search client...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    style: GoogleFonts.manrope(fontSize: 14),
                    onChanged: (v) => setDialogState(() => query = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        ListTile(
                          dense: true,
                          title: Text('All clients', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                          leading: const Icon(Icons.clear_all, size: 18),
                          onTap: () { setState(() => _clientFilter = null); Navigator.pop(ctx); },
                        ),
                        ...filtered.map((c) => ListTile(
                          dense: true,
                          title: Text(c, style: GoogleFonts.manrope(fontSize: 13), overflow: TextOverflow.ellipsis),
                          selected: _clientFilter == c,
                          onTap: () { setState(() => _clientFilter = c); Navigator.pop(ctx); },
                        )),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCompanyList(String companyKey) {
    final docs = _filterByCompany(companyKey);
    if (docs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined, size: 48, color: AppTheme.muted.withValues(alpha: 0.4)),
            const SizedBox(height: 8),
            Text(
              _clientFilter != null || _dateFilter != null ? 'No matching documents' : 'No $companyKey documents yet',
              style: GoogleFonts.manrope(color: AppTheme.muted),
            ),
          ],
        ),
      );
    }

    final isEspl = companyKey == 'ESPL';
    final accentColor = isEspl ? const Color(0xFF3B82F6) : const Color(0xFF10B981);

    return RefreshIndicator(
      onRefresh: _loadDocuments,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: docs.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade200),
        itemBuilder: (context, index) {
          final doc = docs[index];
          final displayDate = _formatDisplayDate(doc);
          final invoiceNo = doc['invoiceNumber']?.toString() ?? '';
          final clientName = doc['clientName'] ?? '';
          final sentPhones = doc['sentToPhones'] as List?;
          final sentCount = sentPhones?.length ?? 0;
          final waStatus = doc['whatsappStatus']?.toString() ?? '';
          final phones = doc['phones'] as List?;
          final phoneCount = phones?.length ?? 0;

          final parts = <String>[];
          if (displayDate.isNotEmpty) parts.add(displayDate);
          parts.add(invoiceNo.isNotEmpty ? invoiceNo : '—');
          if (clientName.isNotEmpty) parts.add(clientName);

          return Dismissible(
            key: ValueKey(doc['id']),
            direction: DismissDirection.endToStart,
            confirmDismiss: (_) async {
              await _deleteDocument(doc);
              return false; // We handle removal in _deleteDocument
            },
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: const Color(0xFFEF4444),
              child: const Icon(Icons.delete_outline, color: Colors.white, size: 22),
            ),
            child: InkWell(
              onTap: () => _showDocumentDetail(doc),
              onLongPress: () => _resendDocument(doc),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 3, height: 32,
                      decoration: BoxDecoration(color: accentColor, borderRadius: BorderRadius.circular(2)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        parts.join('  -  '),
                        style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF1F2937), height: 1.3),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Manual share via native share sheet
                    GestureDetector(
                      onTap: () => _shareManual(context, doc),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.share_rounded, size: 18, color: const Color(0xFF3B82F6)),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Auto-resend via WhatsApp API
                    GestureDetector(
                      onTap: () => _resendDocument(doc),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.send_rounded, size: 18, color: const Color(0xFF25D366)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (waStatus == 'sent' || (waStatus.isEmpty && sentCount > 0))
                      Tooltip(message: 'Sent to $sentCount number${sentCount > 1 ? 's' : ''}', child: const Icon(Icons.check_circle, size: 14, color: Color(0xFF10B981)))
                    else if (waStatus == 'partial')
                      Tooltip(message: 'Sent to $sentCount of $phoneCount', child: Icon(Icons.warning_amber_rounded, size: 14, color: Colors.orange.shade700))
                    else if (waStatus == 'failed')
                      Tooltip(message: 'WhatsApp send failed', child: const Icon(Icons.error_outline, size: 14, color: Color(0xFFEF4444)))
                    else if (waStatus == 'no_phones')
                      Tooltip(message: 'No phone number for client', child: Icon(Icons.phone_disabled, size: 14, color: Colors.grey.shade500))
                    else
                      Icon(Icons.pending_outlined, size: 14, color: Colors.orange.shade600),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade400),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Full-screen image viewer with share functionality
// ══════════════════════════════════════════════════════════════════════════════
class _ImageViewerScreen extends StatelessWidget {
  final String imageUrl;
  final String title;
  final String clientName;
  final String invoiceNumber;
  final String companyName;

  const _ImageViewerScreen({
    required this.imageUrl,
    required this.title,
    required this.clientName,
    this.invoiceNumber = '',
    this.companyName = '',
  });

  Future<void> _shareImage(BuildContext context) async {
    try {
      // Show loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(children: [CircularProgressIndicator(), SizedBox(width: 20), Expanded(child: Text('Preparing...'))]),
        ),
      );

      // Download image
      final response = await Dio().get<List<int>>(
        imageUrl,
        options: Options(responseType: ResponseType.bytes),
      );

      if (context.mounted) Navigator.of(context).pop();

      if (response.data == null) return;

      final tempDir = await getTemporaryDirectory();
      final companyShort = companyName.toLowerCase().contains('emperor') || companyName.toLowerCase() == 'espl' ? 'ESPL' : 'SYGT';
      final safeInvoice = invoiceNumber.replaceAll(RegExp(r'[^a-zA-Z0-9\-]'), '-');
      final fileName = invoiceNumber.isNotEmpty
          ? '$companyShort-$safeInvoice.jpg'
          : '$companyShort-${clientName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.jpg';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(response.data!);

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Dispatch Document - $clientName',
      );
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          title,
          style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_rounded),
            tooltip: 'Share',
            onPressed: () => _shareImage(context),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) {
              if (progress == null) return child;
              return Center(
                child: CircularProgressIndicator(
                  value: progress.expectedTotalBytes != null
                      ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                      : null,
                  color: Colors.white,
                ),
              );
            },
            errorBuilder: (_, __, ___) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined, size: 48, color: Colors.white54),
                const SizedBox(height: 8),
                Text('Image unavailable', style: GoogleFonts.manrope(color: Colors.white54)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
