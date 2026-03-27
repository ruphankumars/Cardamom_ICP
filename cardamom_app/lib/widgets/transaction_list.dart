import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// A single transaction/order item with avatar
class TransactionItem extends StatelessWidget {
  final String clientName;
  final String grade;
  final double amount;
  final String? status;
  final DateTime? timestamp;
  final VoidCallback? onTap;

  const TransactionItem({
    super.key,
    required this.clientName,
    required this.grade,
    required this.amount,
    this.status,
    this.timestamp,
    this.onTap,
  });

  String _getInitials(String name) {
    final words = name.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words[0][0].toUpperCase();
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }

  Color _getAvatarColor(String name) {
    final colors = [
      const Color(0xFF5D6E7E), // Indigo
      const Color(0xFF10B981), // Emerald
      const Color(0xFFF59E0B), // Amber
      const Color(0xFFEF4444), // Red
      const Color(0xFF4A5568), // Purple
      const Color(0xFF5D6E7E), // Blue
      const Color(0xFFEC4899), // Pink
    ];
    final index = name.hashCode.abs() % colors.length;
    return colors[index];
  }

  Color _getStatusColor(String? status) {
    switch (status?.toLowerCase()) {
      case 'pending':
        return const Color(0xFFF59E0B);
      case 'dispatched':
      case 'billed':
        return const Color(0xFF10B981);
      case 'cancelled':
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF64748B);
    }
  }

  @override
  Widget build(BuildContext context) {
    final initials = _getInitials(clientName);
    final avatarColor = _getAvatarColor(clientName);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: avatarColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  initials,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: avatarColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clientName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${grade}${status != null ? ' • $status' : ''}',
                    style: TextStyle(
                      fontSize: 11,
                      color: status?.toLowerCase() == 'pending' 
                          ? const Color(0xFFF59E0B) 
                          : Colors.white.withOpacity(0.6),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Amount
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '₹${NumberFormat('#,##,###').format(amount)}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                if (timestamp != null)
                  Text(
                    DateFormat('HH:mm').format(timestamp!),
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.white.withOpacity(0.5),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A list of transactions with header
class TransactionList extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> transactions;
  final VoidCallback? onSeeAll;
  final int maxItems;

  const TransactionList({
    super.key,
    required this.title,
    required this.transactions,
    this.onSeeAll,
    this.maxItems = 5,
  });

  @override
  Widget build(BuildContext context) {
    final displayItems = transactions.take(maxItems).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF4A5568),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF334155),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              if (onSeeAll != null && transactions.length > maxItems)
                GestureDetector(
                  onTap: onSeeAll,
                  child: Text(
                    'See All',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF5D6E7E).withOpacity(0.8),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // Items
          if (displayItems.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'No transactions yet',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 13,
                  ),
                ),
              ),
            )
          else
            ...displayItems.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TransactionItem(
                    clientName: item['client'] ?? 'Unknown',
                    grade: item['grade'] ?? '',
                    amount: (item['amount'] ?? item['price'] ?? 0).toDouble(),
                    status: item['status'],
                    timestamp: item['timestamp'] is DateTime
                        ? item['timestamp']
                        : null,
                  ),
                )),
        ],
      ),
    );
  }
}

/// Compact recent orders widget for dashboard
class RecentOrdersWidget extends StatelessWidget {
  final List<dynamic> orders;
  final VoidCallback? onSeeAll;

  const RecentOrdersWidget({
    super.key,
    required this.orders,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    final transactions = orders.take(4).map((order) {
      final price = order['price'] ?? 0;
      final kgs = order['kgs'] ?? 0;
      final amount = (price is num ? price : double.tryParse('$price') ?? 0) *
          (kgs is num ? kgs : double.tryParse('$kgs') ?? 0);

      return {
        'client': order['client'] ?? 'Unknown',
        'grade': order['grade'] ?? '',
        'amount': amount,
        'status': order['status'],
      };
    }).toList();

    return TransactionList(
      title: 'Recent Orders',
      transactions: transactions.cast<Map<String, dynamic>>(),
      onSeeAll: onSeeAll,
      maxItems: 4,
    );
  }
}
