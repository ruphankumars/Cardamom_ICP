import 'package:flutter_test/flutter_test.dart';
import 'package:cardamom_app/models/client_request.dart';

void main() {
  group('ClientRequest model', () {
    test('fromJson creates ClientRequest with all fields', () {
      final json = {
        'requestId': 'REQ-123',
        'requestType': 'NEGOTIATION',
        'status': 'OPEN',
        'clientUsername': 'testclient',
        'clientName': 'Test Client Co',
        'requestedItems': [
          {'grade': '8 mm', 'kgs': 500, 'no': 10, 'bagbox': 'Bag'},
        ],
        'createdAt': '2026-02-08T09:00:00.000Z',
        'updatedAt': '2026-02-08T09:00:00.000Z',
        'initialText': 'Need 500 kg of 8mm',
      };

      final request = ClientRequest.fromJson(json);

      expect(request.requestId, 'REQ-123');
      expect(request.requestType, 'NEGOTIATION');
      expect(request.status, 'OPEN');
      expect(request.clientUsername, 'testclient');
      expect(request.clientName, 'Test Client Co');
      expect(request.requestedItems.length, 1);
      expect(request.initialText, 'Need 500 kg of 8mm');
    });

    test('fromJson uses fallback keys for clientUsername/clientName', () {
      final json = {
        'requestId': 'REQ-456',
        'requestType': 'NEGOTIATION',
        'status': 'OPEN',
        'username': 'fallback_user',
        'client': 'Fallback Client',
        'requestedItems': [],
        'createdAt': '2026-02-08T09:00:00.000Z',
        'updatedAt': '2026-02-08T09:00:00.000Z',
      };

      final request = ClientRequest.fromJson(json);
      expect(request.clientUsername, 'fallback_user');
      expect(request.clientName, 'Fallback Client');
    });

    test('fromJson handles empty requestedItems', () {
      final json = {
        'requestId': 'REQ-789',
        'requestType': 'NEGOTIATION',
        'status': 'OPEN',
        'clientUsername': 'test',
        'clientName': 'Test',
        'createdAt': '2026-02-08T09:00:00.000Z',
        'updatedAt': '2026-02-08T09:00:00.000Z',
      };

      final request = ClientRequest.fromJson(json);
      expect(request.requestedItems, isEmpty);
    });
  });

  group('RequestItem model', () {
    test('fromJson creates item with all fields', () {
      final json = {
        'grade': '7.5 to 8 mm',
        'kgs': 250,
        'no': 5,
        'bagbox': 'Box',
        'price': 2500,
        'brand': 'Emperor',
        'notes': 'Priority',
        'offeredKgs': 240,
        'offeredNo': 5,
        'unitPrice': 500,
      };

      final item = RequestItem.fromJson(json);
      expect(item.grade, '7.5 to 8 mm');
      expect(item.kgs, 250);
      expect(item.no, 5);
      expect(item.bagbox, 'Box');
      expect(item.price, 2500);
      expect(item.offeredKgs, 240);
    });

    test('toJson round-trip preserves data', () {
      final original = RequestItem(
        grade: '8 mm',
        kgs: 500,
        no: 10,
        bagbox: 'Bag',
        price: 2000,
      );

      final json = original.toJson();
      final restored = RequestItem.fromJson(json);

      expect(restored.grade, original.grade);
      expect(restored.kgs, original.kgs);
      expect(restored.no, original.no);
      expect(restored.bagbox, original.bagbox);
      expect(restored.price, original.price);
    });

    test('fromJson handles null numeric fields', () {
      final json = {'grade': '8 mm'};
      final item = RequestItem.fromJson(json);

      expect(item.kgs, isNull);
      expect(item.no, isNull);
      expect(item.price, isNull);
    });
  });

  group('ChatMessage model', () {
    test('fromJson creates message with all fields', () {
      final json = {
        'messageId': 'MSG-123',
        'senderRole': 'admin',
        'senderUsername': 'admin1',
        'messageType': 'TEXT',
        'message': 'Hello',
        'timestamp': '2026-02-08T09:00:00.000Z',
      };

      final msg = ChatMessage.fromJson(json);
      expect(msg.messageId, 'MSG-123');
      expect(msg.senderRole, 'admin');
      expect(msg.messageType, 'TEXT');
      expect(msg.message, 'Hello');
    });

    test('fromJson handles payload field', () {
      final json = {
        'messageId': 'MSG-456',
        'senderRole': 'admin',
        'senderUsername': 'admin1',
        'messageType': 'PANEL',
        'payload': {'items': []},
        'timestamp': '2026-02-08T09:00:00.000Z',
      };

      final msg = ChatMessage.fromJson(json);
      expect(msg.payload, isNotNull);
      expect(msg.message, isNull);
    });
  });
}
