/// Daily cart modal widget for the admin dashboard.
///
/// Dialog and drag content widgets for viewing today's packed orders,
/// grouped by client, with cancel dispatch functionality.
import 'package:flutter/material.dart';

/// Dialog widget for viewing today's packed orders grouped by client.
class DailyCartDialog extends StatelessWidget {
  final List<dynamic> todayCart;
  final Function(String, String) onCancelDispatch;

  const DailyCartDialog({super.key, required this.todayCart, required this.onCancelDispatch});

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<dynamic>>{};
    for (var order in todayCart) {
      final client = order['client'] ?? 'Unknown';
      if (!grouped.containsKey(client)) grouped[client] = [];
      grouped[client]!.add(order);
    }
    final sortedClients = grouped.keys.toList()..sort();

    final bool isMobile = MediaQuery.of(context).size.width < 800;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: isMobile ? MediaQuery.of(context).size.width * 0.95 : 800,
        height: isMobile ? MediaQuery.of(context).size.height * 0.85 : 600,
        padding: EdgeInsets.all(isMobile ? 12 : 24),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text("Today's Packed Orders", style: TextStyle(fontSize: isMobile ? 16 : 20, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                const CloseButton(),
              ],
            ),
            const Divider(),
            Expanded(
              child: todayCart.isEmpty
                ? const Center(child: Text('No packed orders today.', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: sortedClients.length,
                    itemBuilder: (context, index) {
                      final client = sortedClients[index];
                      final orders = grouped[client]!;
                      return _buildClientGroup(client, orders);
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClientGroup(String client, List<dynamic> orders) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.05),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.2))),
            ),
            child: Text(client, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
          ),
          ...orders.map((o) => Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Lot ${o['lot']}: ${o['grade']} \u2022 ${o['kgs']} kg \u2022 \u20B9${o['price']}',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      if (o['notes'] != null && o['notes'].toString().isNotEmpty)
                        Text('${o['notes']}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.red, size: 20),
                  onPressed: () => onCancelDispatch(o['lot'].toString(), client),
                  tooltip: 'Cancel Dispatch',
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}

/// Content widget for daily cart drag popup - matches DailyCartDialog styling.
class DailyCartDragContent extends StatelessWidget {
  final List<dynamic> todayCart;
  final ScrollController scrollController;
  final Future<void> Function(String lot, String client) onCancelDispatch;

  const DailyCartDragContent({
    super.key,
    required this.todayCart,
    required this.scrollController,
    required this.onCancelDispatch,
  });

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<dynamic>>{};
    for (var order in todayCart) {
      final client = order['client'] ?? 'Unknown';
      if (!grouped.containsKey(client)) grouped[client] = [];
      grouped[client]!.add(order);
    }
    final sortedClients = grouped.keys.toList()..sort();

    return todayCart.isEmpty
      ? const Center(child: Text('No packed orders today.', style: TextStyle(color: Colors.grey)))
      : ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.all(12),
          itemCount: sortedClients.length,
          itemBuilder: (context, index) {
            final client = sortedClients[index];
            final orders = grouped[client]!;
            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.withOpacity(0.2))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: Colors.blue.withOpacity(0.05), borderRadius: const BorderRadius.vertical(top: Radius.circular(12)), border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.2)))),
                  child: Text(client, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4A5568))),
                ),
                ...orders.map((o) => Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Lot ${o['lot']}: ${o['grade']} \u2022 ${o['kgs']} kg \u2022 \u20B9${o['price']}', style: const TextStyle(fontWeight: FontWeight.w500)),
                      if (o['notes'] != null && o['notes'].toString().isNotEmpty)
                        Text('${o['notes']}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ])),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.red, size: 20),
                      onPressed: () => onCancelDispatch(o['lot']?.toString() ?? '', client),
                      tooltip: 'Cancel Dispatch',
                    ),
                  ]),
                )),
              ]),
            );
          },
        );
  }
}
