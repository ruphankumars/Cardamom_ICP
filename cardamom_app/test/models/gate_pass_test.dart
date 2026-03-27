import 'package:flutter_test/flutter_test.dart';
import 'package:cardamom_app/models/gate_pass.dart';

void main() {
  group('GatePass model', () {
    final sampleJson = {
      'id': 'gp1',
      'passNumber': 'GP-001',
      'type': 'exit',
      'packaging': 'bag',
      'bagCount': 10,
      'boxCount': 0,
      'bagWeight': 50,
      'boxWeight': 20,
      'calculatedWeight': 500,
      'actualWeight': 490,
      'finalWeight': 490,
      'purpose': 'transport',
      'notes': 'Rush delivery',
      'vehicleNumber': 'KA-01-1234',
      'driverName': 'Raju',
      'driverPhone': '9876543210',
      'status': 'pending',
      'requestedBy': 'admin',
      'requestedAt': '2026-02-08T09:00:00.000Z',
      'isCompleted': false,
      'updatedAt': '2026-02-08T09:00:00.000Z',
    };

    test('fromJson creates GatePass with all fields', () {
      final gp = GatePass.fromJson(sampleJson);

      expect(gp.id, 'gp1');
      expect(gp.passNumber, 'GP-001');
      expect(gp.type, GatePassType.exit);
      expect(gp.packaging, GatePassPackaging.bag);
      expect(gp.bagCount, 10);
      expect(gp.boxCount, 0);
      expect(gp.calculatedWeight, 500);
      expect(gp.actualWeight, 490);
      expect(gp.finalWeight, 490);
      expect(gp.purpose, GatePassPurpose.transport);
      expect(gp.status, GatePassStatus.pending);
      expect(gp.requestedBy, 'admin');
      expect(gp.isCompleted, false);
    });

    test('toJson round-trip preserves data', () {
      final original = GatePass.fromJson(sampleJson);
      final json = original.toJson();
      final restored = GatePass.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.passNumber, original.passNumber);
      expect(restored.type, original.type);
      expect(restored.packaging, original.packaging);
      expect(restored.bagCount, original.bagCount);
      expect(restored.calculatedWeight, original.calculatedWeight);
      expect(restored.status, original.status);
    });

    test('fromJson parses entry type', () {
      final json = {...sampleJson, 'type': 'entry'};
      final gp = GatePass.fromJson(json);
      expect(gp.type, GatePassType.entry);
    });

    test('fromJson parses all packaging types', () {
      expect(GatePass.fromJson({...sampleJson, 'packaging': 'bag'}).packaging, GatePassPackaging.bag);
      expect(GatePass.fromJson({...sampleJson, 'packaging': 'box'}).packaging, GatePassPackaging.box);
      expect(GatePass.fromJson({...sampleJson, 'packaging': 'mixed'}).packaging, GatePassPackaging.mixed);
    });

    test('fromJson parses all purpose types', () {
      expect(GatePass.fromJson({...sampleJson, 'purpose': 'auction'}).purpose, GatePassPurpose.auction);
      expect(GatePass.fromJson({...sampleJson, 'purpose': 'transport'}).purpose, GatePassPurpose.transport);
      expect(GatePass.fromJson({...sampleJson, 'purpose': 'local'}).purpose, GatePassPurpose.local);
      expect(GatePass.fromJson({...sampleJson, 'purpose': 'return'}).purpose, GatePassPurpose.return_);
    });

    test('fromJson parses all status types', () {
      expect(GatePass.fromJson({...sampleJson, 'status': 'pending'}).status, GatePassStatus.pending);
      expect(GatePass.fromJson({...sampleJson, 'status': 'approved'}).status, GatePassStatus.approved);
      expect(GatePass.fromJson({...sampleJson, 'status': 'rejected'}).status, GatePassStatus.rejected);
    });

    test('computed properties work correctly', () {
      final pending = GatePass.fromJson({...sampleJson, 'status': 'pending'});
      expect(pending.isPending, true);
      expect(pending.isApproved, false);

      final approved = GatePass.fromJson({...sampleJson, 'status': 'approved'});
      expect(approved.isApproved, true);
      expect(approved.isPending, false);
    });

    test('typeDisplay returns correct string', () {
      expect(GatePass.fromJson({...sampleJson, 'type': 'entry'}).typeDisplay, 'Entry');
      expect(GatePass.fromJson({...sampleJson, 'type': 'exit'}).typeDisplay, 'Exit');
    });
  });
}
