import 'package:flutter_test/flutter_test.dart';
import 'package:cardamom_app/models/worker.dart';

void main() {
  group('Worker model', () {
    test('fromJson creates Worker with all fields', () {
      final json = {
        'id': 'w1',
        'name': 'Raju',
        'phone': '9876543210',
        'baseDailyWage': 600,
        'otHourlyRate': 120,
        'team': 'Sorting',
        'isActive': true,
        'createdAt': '2026-01-01T00:00:00.000Z',
      };

      final worker = Worker.fromJson(json);

      expect(worker.id, 'w1');
      expect(worker.name, 'Raju');
      expect(worker.phone, '9876543210');
      expect(worker.baseDailyWage, 600.0);
      expect(worker.otHourlyRate, 120.0);
      expect(worker.team, 'Sorting');
      expect(worker.isActive, true);
      expect(worker.createdAt, isNotNull);
    });

    test('fromJson uses defaults for missing fields', () {
      final json = {'id': 'w2', 'name': 'Kumar'};
      final worker = Worker.fromJson(json);

      expect(worker.baseDailyWage, 500.0);
      expect(worker.otHourlyRate, 100.0);
      expect(worker.team, 'General');
      expect(worker.isActive, true);
      expect(worker.phone, isNull);
    });

    test('toJson round-trip preserves data', () {
      final original = Worker(
        id: 'w3',
        name: 'Sanjay',
        phone: '1234567890',
        baseDailyWage: 700,
        otHourlyRate: 150,
        team: 'Loading',
        isActive: false,
        createdAt: DateTime(2026, 1, 15),
      );

      final json = original.toJson();
      final restored = Worker.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.phone, original.phone);
      expect(restored.baseDailyWage, original.baseDailyWage);
      expect(restored.team, original.team);
      expect(restored.isActive, original.isActive);
    });

    test('toJson excludes similarity field', () {
      final worker = Worker(id: 'w4', name: 'Test', similarity: 0.95);
      final json = worker.toJson();
      expect(json.containsKey('similarity'), false);
    });

    test('copyWith creates new instance with updated fields', () {
      final worker = Worker(id: 'w5', name: 'Original');
      final updated = worker.copyWith(name: 'Updated', team: 'New Team');

      expect(updated.name, 'Updated');
      expect(updated.team, 'New Team');
      expect(updated.id, 'w5');
    });
  });

  group('AttendanceStatus', () {
    test('fromString parses all status values', () {
      expect(AttendanceStatus.fromString('full'), AttendanceStatus.full);
      expect(AttendanceStatus.fromString('half_am'), AttendanceStatus.halfAm);
      expect(AttendanceStatus.fromString('half_pm'), AttendanceStatus.halfPm);
      expect(AttendanceStatus.fromString('ot'), AttendanceStatus.ot);
    });

    test('fromString defaults to full for unknown', () {
      expect(AttendanceStatus.fromString(null), AttendanceStatus.full);
      expect(AttendanceStatus.fromString('unknown'), AttendanceStatus.full);
    });
  });

  group('AttendanceRecord', () {
    test('fromJson creates record with all fields', () {
      final json = {
        'id': 'ar1',
        'date': '08/02/26',
        'workerId': 'w1',
        'workerName': 'Raju',
        'status': 'full',
        'otHours': 2,
        'calculatedWage': 500,
        'finalWage': 500,
      };

      final record = AttendanceRecord.fromJson(json);
      expect(record.id, 'ar1');
      expect(record.workerName, 'Raju');
      expect(record.status, AttendanceStatus.full);
      expect(record.finalWage, 500.0);
    });
  });
}
