import 'package:flutter_test/flutter_test.dart';
import 'package:cardamom_app/models/expense_sheet.dart';

void main() {
  group('ExpenseCategory', () {
    test('fromString parses all categories', () {
      expect(ExpenseCategory.fromString('worker_wages'), ExpenseCategory.workerWages);
      expect(ExpenseCategory.fromString('stitching'), ExpenseCategory.stitching);
      expect(ExpenseCategory.fromString('loading'), ExpenseCategory.loading);
      expect(ExpenseCategory.fromString('transport'), ExpenseCategory.transport);
      expect(ExpenseCategory.fromString('fuel'), ExpenseCategory.fuel);
      expect(ExpenseCategory.fromString('maintenance'), ExpenseCategory.maintenance);
      expect(ExpenseCategory.fromString('misc'), ExpenseCategory.misc);
    });

    test('fromString defaults to misc for unknown', () {
      expect(ExpenseCategory.fromString('unknown'), ExpenseCategory.misc);
      expect(ExpenseCategory.fromString(null), ExpenseCategory.misc);
    });
  });

  group('ExpenseItem', () {
    test('fromJson creates item with all fields', () {
      final json = {
        'id': 'ei1',
        'sheetId': 'es1',
        'category': 'transport',
        'quantity': 5,
        'rate': 200,
        'amount': 1000,
        'note': 'Vehicle hire',
      };

      final item = ExpenseItem.fromJson(json);
      expect(item.id, 'ei1');
      expect(item.sheetId, 'es1');
      expect(item.category, ExpenseCategory.transport);
      expect(item.quantity, 5);
      expect(item.rate, 200.0);
      expect(item.amount, 1000.0);
      expect(item.note, 'Vehicle hire');
    });

    test('toJson round-trip preserves data', () {
      final item = ExpenseItem(
        id: 'ei2',
        sheetId: 'es1',
        category: ExpenseCategory.fuel,
        amount: 500,
        quantity: 10,
        rate: 50,
      );

      final json = item.toJson();
      final restored = ExpenseItem.fromJson(json);

      expect(restored.id, item.id);
      expect(restored.category, item.category);
      expect(restored.amount, item.amount);
    });
  });

  group('ExpenseSheet', () {
    test('fromJson creates sheet with all fields', () {
      final json = {
        'id': 'es1',
        'date': '08/02/26',
        'workerWages': 5000,
        'totalVariable': 3000,
        'totalMisc': 500,
        'grandTotal': 8500,
        'status': 'pending',
        'submittedBy': 'admin',
        'items': [
          {'id': 'ei1', 'sheetId': 'es1', 'category': 'fuel', 'amount': 500},
        ],
      };

      final sheet = ExpenseSheet.fromJson(json);
      expect(sheet.id, 'es1');
      expect(sheet.date, '08/02/26');
      expect(sheet.workerWages, 5000.0);
      expect(sheet.grandTotal, 8500.0);
      expect(sheet.status, ExpenseStatus.pending);
      expect(sheet.items.length, 1);
    });

    test('canEdit returns true for draft and rejected', () {
      final draft = ExpenseSheet(date: '08/02/26', workerWages: 0, grandTotal: 0, status: ExpenseStatus.draft);
      final rejected = ExpenseSheet(date: '08/02/26', workerWages: 0, grandTotal: 0, status: ExpenseStatus.rejected);
      final approved = ExpenseSheet(date: '08/02/26', workerWages: 0, grandTotal: 0, status: ExpenseStatus.approved);

      expect(draft.canEdit, true);
      expect(rejected.canEdit, true);
      expect(approved.canEdit, false);
    });

    test('canApprove returns true only for pending', () {
      final pending = ExpenseSheet(date: '08/02/26', workerWages: 0, grandTotal: 0, status: ExpenseStatus.pending);
      final draft = ExpenseSheet(date: '08/02/26', workerWages: 0, grandTotal: 0, status: ExpenseStatus.draft);

      expect(pending.canApprove, true);
      expect(draft.canApprove, false);
    });

    test('miscPercentage calculates correctly', () {
      final sheet = ExpenseSheet(date: '08/02/26', workerWages: 5000, totalMisc: 1000, grandTotal: 10000);
      expect(sheet.miscPercentage, 10.0);
    });

    test('miscPercentage returns 0 when grandTotal is 0', () {
      final sheet = ExpenseSheet(date: '08/02/26', workerWages: 0, totalMisc: 0, grandTotal: 0);
      expect(sheet.miscPercentage, 0.0);
    });
  });

  group('ExpenseStatus', () {
    test('fromString parses all statuses', () {
      expect(ExpenseStatus.fromString('draft'), ExpenseStatus.draft);
      expect(ExpenseStatus.fromString('pending'), ExpenseStatus.pending);
      expect(ExpenseStatus.fromString('approved'), ExpenseStatus.approved);
      expect(ExpenseStatus.fromString('rejected'), ExpenseStatus.rejected);
    });
  });
}
