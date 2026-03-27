import 'package:flutter_test/flutter_test.dart';
import 'package:cardamom_app/models/order.dart';

void main() {
  group('Order model', () {
    test('fromJson creates Order with all fields', () {
      final json = {
        'orderDate': '08/02/26',
        'billingFrom': 'Emperor Spices',
        'client': 'Test Client',
        'lot': 'LOT-001',
        'grade': '8 mm',
        'bagbox': 'Bag',
        'no': 10,
        'kgs': 500,
        'price': 2000,
        'brand': 'Emperor',
        'status': 'Pending',
        'notes': 'Test note',
        'rowIndex': 5,
      };

      final order = Order.fromJson(json);

      expect(order.orderDate, '08/02/26');
      expect(order.billingFrom, 'Emperor Spices');
      expect(order.client, 'Test Client');
      expect(order.lot, 'LOT-001');
      expect(order.grade, '8 mm');
      expect(order.bagbox, 'Bag');
      expect(order.no, 10);
      expect(order.kgs, 500);
      expect(order.price, 2000);
      expect(order.brand, 'Emperor');
      expect(order.status, 'Pending');
      expect(order.notes, 'Test note');
      expect(order.rowIndex, 5);
    });

    test('fromJson handles null values', () {
      final json = <String, dynamic>{};
      final order = Order.fromJson(json);

      expect(order.orderDate, isNull);
      expect(order.no, isNull);
      expect(order.kgs, isNull);
    });

    test('toJson round-trip preserves data', () {
      final original = Order(
        orderDate: '08/02/26',
        billingFrom: 'Emperor',
        client: 'Client A',
        lot: 'L1',
        grade: '8 mm',
        bagbox: 'Bag',
        no: 10,
        kgs: 500,
        price: 2000,
        brand: 'Emperor',
        status: 'Pending',
        notes: 'Note',
      );

      final json = original.toJson();
      final restored = Order.fromJson(json);

      expect(restored.orderDate, original.orderDate);
      expect(restored.client, original.client);
      expect(restored.grade, original.grade);
      expect(restored.no, original.no);
      expect(restored.kgs, original.kgs);
      expect(restored.price, original.price);
    });

    test('toJson excludes rowIndex', () {
      final order = Order(rowIndex: 5);
      final json = order.toJson();
      expect(json.containsKey('rowIndex'), false);
    });

    test('fromJson converts string numbers to num', () {
      final json = {
        'no': '15',
        'kgs': '750.5',
        'price': '2500',
      };
      final order = Order.fromJson(json);
      expect(order.no, 15);
      expect(order.kgs, 750.5);
      expect(order.price, 2500);
    });
  });
}
