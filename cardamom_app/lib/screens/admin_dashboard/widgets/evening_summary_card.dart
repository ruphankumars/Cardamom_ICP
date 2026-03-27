/// Evening summary card widget for the admin dashboard.
///
/// A titanium-well styled card displaying end-of-day summary metrics
/// including total sales, packed quantities, and orders fulfilled.
import 'package:flutter/material.dart';

/// Daily summary card shown in evening hours with key metrics and share button.
class EveningSummaryCard extends StatelessWidget {
  final Map<String, dynamic>? dashboardData;

  const EveningSummaryCard({super.key, this.dashboardData});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF9A9A94),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(5, 5)),
          BoxShadow(color: Colors.white.withOpacity(0.2), blurRadius: 5, offset: const Offset(-2, -2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Text('\u{1F319}', style: TextStyle(fontSize: 20)),
          SizedBox(width: 10),
          Text('DAILY SUMMARY', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
        ]),
        const SizedBox(height: 20),
        _buildEveningRow('Total Sales', '\u{20B9}${(((_salesValue) is num ? (_salesValue) : (num.tryParse('$_salesValue') ?? 0)) / 100000).toStringAsFixed(2)}L'),
        _buildEveningRow('Total Packed', '${dashboardData?['todayPackedKgs'] ?? 0} kg'),
        _buildEveningRow('Orders Fulfilled', '${dashboardData?['todayPackedCount'] ?? 0}'),
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: () => Navigator.pushNamed(context, '/sales_summary'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white.withOpacity(0.1),
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('SHARE REPORT', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
        )),
      ]),
    );
  }

  num get _salesValue => dashboardData?['todaySalesVal'] ?? 0;

  Widget _buildEveningRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.6))),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
      ]),
    );
  }
}
