/// Available stock modal widget for the admin dashboard.
///
/// Dialog and content widgets for displaying available stock grades
/// with positive quantities, sorted by amount.
import 'package:flutter/material.dart';

/// Dialog widget showing available stock grades for allocation.
class AvailableStockDialog extends StatelessWidget {
  final Map<String, double> stockMap;

  const AvailableStockDialog({super.key, required this.stockMap});

  @override
  Widget build(BuildContext context) {
    final sortedGrades = stockMap.keys.toList()
      ..sort((a, b) => stockMap[b]!.compareTo(stockMap[a]!));

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Available for Allocation', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                CloseButton(),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Absolute grades with positive stock, aggregated across buckets.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.left,
            ),
            const SizedBox(height: 16),
            stockMap.isEmpty
              ? const Padding(padding: EdgeInsets.all(20), child: Text('No positive absolute grades available.', style: TextStyle(color: Colors.grey)))
              : Flexible(
                  child: SingleChildScrollView(
                    child: Table(
                      columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1)},
                      border: TableBorder(horizontalInside: BorderSide(color: Colors.grey.withOpacity(0.2))),
                      children: [
                        const TableRow(
                          decoration: BoxDecoration(color: Color(0xFFF1F5F9)),
                          children: [
                            Padding(padding: EdgeInsets.all(8.0), child: Text('Grade', style: TextStyle(fontWeight: FontWeight.bold))),
                            Padding(padding: EdgeInsets.all(8.0), child: Text('Available (kg)', style: TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
                          ],
                        ),
                        ...sortedGrades.map((grade) => TableRow(
                          children: [
                            Padding(padding: const EdgeInsets.all(12.0), child: Text(grade)),
                            Padding(padding: const EdgeInsets.all(12.0), child: Text('${stockMap[grade]?.round()}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                          ],
                        )),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
