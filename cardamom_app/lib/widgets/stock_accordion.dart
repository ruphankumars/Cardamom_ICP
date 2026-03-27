import 'package:flutter/material.dart';

/// A reusable Stock Accordion widget that displays stock data in an expandable
/// accordion format with progress bars for each grade.
/// 
/// Features:
/// - Expandable sections for Colour Bold, Fruit Bold, and Rejection
/// - Progress bars showing relative quantities
/// - Green bars for positive values, red bars for negative values
/// - Consistent color palette (Indigo, Emerald, Amber)
class StockAccordion extends StatefulWidget {
  /// Net stock data in the format: { 'headers': [...], 'rows': [...] }
  final Map<dynamic, dynamic> netStock;
  
  /// List of virtual grades (used to hide negative values)
  final List<String> virtualGrades;
  
  /// Stock types to display (default: Colour Bold, Fruit Bold, Rejection)
  final List<String> stockTypes;
  
  /// Whether to show the first section expanded initially
  final bool initiallyExpanded;
  
  const StockAccordion({
    super.key,
    required this.netStock,
    this.virtualGrades = const [],
    this.stockTypes = const ['Colour Bold', 'Fruit Bold', 'Rejection'],
    this.initiallyExpanded = true,
  });

  @override
  State<StockAccordion> createState() => _StockAccordionState();
}

class _StockAccordionState extends State<StockAccordion> {
  late Set<String> _expandedTypes;
  
  @override
  void initState() {
    super.initState();
    // Expand first type by default if initiallyExpanded is true
    _expandedTypes = widget.initiallyExpanded && widget.stockTypes.isNotEmpty
        ? {widget.stockTypes.first}
        : {};
  }
  
  @override
  Widget build(BuildContext context) {
    final headers = List<String>.from(widget.netStock['headers'] ?? []);
    final rows = List<dynamic>.from(widget.netStock['rows'] ?? []);
    
    if (headers.isEmpty || rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No stock data available.', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
        ),
      );
    }
    
    // Build stock data map: { type: { grade: value } }
    // Handle both array format (from dashboard) and object format (from stock calculator)
    final Map<String, Map<String, double>> stockData = {};
    for (var row in rows) {
      if (row is List && row.isNotEmpty) {
        // Array format: [type, val1, val2, ...]
        final type = row[0]?.toString() ?? 'Unknown';
        stockData[type] = {};
        for (int i = 1; i < row.length && i < headers.length; i++) {
          final grade = headers[i];
          final val = row[i] is num ? row[i].toDouble() : (num.tryParse('${row[i]}')?.toDouble() ?? 0);
          stockData[type]![grade] = val;
        }
      } else if (row is Map) {
        // Object format: { 'type': 'Colour Bold', 'values': [val1, val2, ...] }
        final type = row['type']?.toString() ?? 'Unknown';
        final values = row['values'] as List? ?? [];
        stockData[type] = {};
        for (int i = 0; i < values.length && i < headers.length; i++) {
          final grade = headers[i];
          final val = values[i] is num ? values[i].toDouble() : (num.tryParse('${values[i]}')?.toDouble() ?? 0);
          stockData[type]![grade] = val;
        }
      }
    }
    
    // Get grades (headers minus the first column for array format, or full headers for object format)
    final grades = rows.isNotEmpty && rows.first is List 
        ? (headers.length > 1 ? headers.sublist(1) : <String>[])
        : headers;
    
    // Parse rejection breakdown from API response
    final rejBreakdown = widget.netStock['rejectionBreakdown'];

    return Column(
      children: [
        ...widget.stockTypes.map((type) {
          final typeData = stockData[type] ?? {};
          return _buildAccordionSection(type, typeData, grades);
        }),
        // Rejection breakdown: Split (70%) + Sick (30%)
        if (rejBreakdown != null) ...[
          _buildRejectionBreakdown(rejBreakdown),
        ],
      ],
    );
  }
  
  Widget _buildAccordionSection(String type, Map<String, double> typeData, List<String> allGrades) {
    // Calculate totals and filter non-zero grades
    final List<MapEntry<String, double>> gradeEntries = [];
    double totalKg = 0;
    
    for (final grade in allGrades) {
      final isVirtual = widget.virtualGrades.contains(grade);
      // Skip virtual grades entirely — only show absolute grades
      if (isVirtual) continue;
      final val = typeData[grade] ?? 0;
      if (val != 0) {
        gradeEntries.add(MapEntry(grade, val.toDouble()));
        totalKg += val;
      }
    }
    
    final gradeCount = gradeEntries.length;
    final isExpanded = _expandedTypes.contains(type);
    
    // Type-specific colors
    final (Color typeColor, String typeInitial) = _getTypeStyle(type);
    
    // Find max absolute value for progress bar scaling
    final maxAbsValue = gradeEntries.isEmpty 
        ? 1.0 
        : gradeEntries.map((e) => e.value.abs()).reduce((a, b) => a > b ? a : b);
    
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header (always visible, tappable)
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedTypes.remove(type);
                } else {
                  _expandedTypes.add(type);
                }
              });
            },
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  // Type initial circle
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: typeColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        typeInitial,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: typeColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Type name and summary
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          type,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF4A5568),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          '${totalKg.round()} kg • $gradeCount grades',
                          style: TextStyle(
                            fontSize: 11,
                            color: totalKg < 0 
                                ? const Color(0xFFDC2626) 
                                : const Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Expand/collapse icon
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: typeColor.withOpacity(0.7),
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Expandable content
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: _buildGradesList(gradeEntries, maxAbsValue),
            crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
  
  Widget _buildGradesList(List<MapEntry<String, double>> gradeEntries, double maxAbsValue) {
    if (gradeEntries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: Text('No stock in this category', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
      );
    }
    
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        children: gradeEntries.map((entry) {
          return _buildGradeRow(entry.key, entry.value, maxAbsValue);
        }).toList(),
      ),
    );
  }
  
  Widget _buildGradeRow(String grade, double value, double maxAbsValue) {
    final isPositive = value >= 0;
    final progressValue = maxAbsValue > 0 ? (value.abs() / maxAbsValue).clamp(0.0, 1.0) : 0.0;
    
    // Shorten grade names for display
    final shortGrade = _shortenGrade(grade);
    
    // Colors
    final barColor = isPositive 
        ? const Color(0xFF22C55E) // Green
        : const Color(0xFFF87171); // Red/Pink
    final barBgColor = isPositive
        ? const Color(0xFFDCFCE7) // Light green
        : const Color(0xFFFEE2E2); // Light red
    final textColor = isPositive
        ? const Color(0xFF16A34A) // Dark green
        : const Color(0xFFDC2626); // Dark red
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Grade name
          SizedBox(
            width: 48,
            child: Text(
              shortGrade,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // Progress bar
          Expanded(
            child: Container(
              height: 24,
              decoration: BoxDecoration(
                color: barBgColor,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Stack(
                children: [
                  // Filled portion
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progressValue,
                    child: Container(
                      decoration: BoxDecoration(
                        color: barColor.withOpacity(0.65),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                  // Value label - centered in the bar
                  Center(
                    child: Text(
                      '${isPositive ? "+" : ""}${value.round()} kg',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  String _shortenGrade(String grade) {
    return grade
        .replaceAll(' to ', '-')
        .replaceAll(' mm', '')
        .replaceAll(' Bold', ' B')
        .replaceAll('below', '↓');
  }
  
  Widget _buildRejectionBreakdown(dynamic breakdown) {
    final splitTotal = (breakdown['split']?['total'] ?? 0).toDouble();
    final sickTotal = (breakdown['sick']?['total'] ?? 0).toDouble();
    final total = (breakdown['total'] ?? 0).toDouble();

    if (total <= 0) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(Icons.call_split_rounded, size: 14, color: Color(0xFFF59E0B)),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Rejection Breakdown',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF4A5568)),
                  ),
                ),
                Text(
                  '${total.round()} kg total',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Split Rejection (70%)
            _buildBreakdownRow(
              'Split Rejection',
              '70%',
              splitTotal,
              total,
              const Color(0xFF3B82F6),
            ),
            const SizedBox(height: 10),
            // Sick Rejection (30%)
            _buildBreakdownRow(
              'Sick Rejection',
              '30%',
              sickTotal,
              total,
              const Color(0xFFEF4444),
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 12, color: Color(0xFF94A3B8)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sell as: Split only, Sick only, or Mixed (Rejection)',
                    style: TextStyle(fontSize: 10, color: Colors.grey[500], fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBreakdownRow(String label, String pct, double value, double total, Color color) {
    final fraction = total > 0 ? (value / total).clamp(0.0, 1.0) : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ),
        Text(pct, style: TextStyle(fontSize: 10, color: color.withOpacity(0.7))),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              backgroundColor: color.withOpacity(0.1),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${value.round()} kg',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  (Color, String) _getTypeStyle(String type) {
    final lowerType = type.toLowerCase();
    if (lowerType.contains('colour')) {
      return (const Color(0xFF5D6E7E), 'C'); // Indigo
    } else if (lowerType.contains('fruit')) {
      return (const Color(0xFF10B981), 'F'); // Emerald
    } else if (lowerType.contains('rejection')) {
      return (const Color(0xFFF59E0B), 'R'); // Amber
    } else {
      return (const Color(0xFF64748B), type.isNotEmpty ? type[0].toUpperCase() : '?');
    }
  }
}
