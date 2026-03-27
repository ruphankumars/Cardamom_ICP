import 'package:flutter_test/flutter_test.dart';
import 'package:cardamom_app/models/task.dart';

void main() {
  group('Task model', () {
    test('fromJson creates Task with all fields', () {
      final json = {
        'id': 't1',
        'title': 'Complete order packing',
        'description': 'Pack order for Client A',
        'notes': 'Use premium boxes',
        'assigneeId': 'u1',
        'assigneeName': 'Raju',
        'hasDueDate': true,
        'dueDate': '2026-02-10T00:00:00.000Z',
        'dueTime': '14:30',
        'hasDueTime': true,
        'isUrgent': true,
        'repeatType': 'daily',
        'priority': 'high',
        'status': 'ongoing',
        'tags': ['packing', 'urgent'],
        'subtasks': [
          {'title': 'Get boxes', 'completed': true},
          {'title': 'Label packages', 'completed': false},
        ],
        'createdAt': '2026-02-08T09:00:00.000Z',
      };

      final task = Task.fromJson(json);

      expect(task.id, 't1');
      expect(task.title, 'Complete order packing');
      expect(task.description, 'Pack order for Client A');
      expect(task.assigneeName, 'Raju');
      expect(task.isUrgent, true);
      expect(task.repeatType, RepeatType.daily);
      expect(task.priority, 'high');
      expect(task.status, TaskStatus.ongoing);
      expect(task.tags.length, 2);
      expect(task.subtasks.length, 2);
    });

    test('fromJson uses defaults for missing optional fields', () {
      final json = {
        'id': 't2',
        'title': 'Simple task',
        'createdAt': '2026-02-08T09:00:00.000Z',
      };

      final task = Task.fromJson(json);
      expect(task.description, '');
      expect(task.isUrgent, false);
      expect(task.repeatType, RepeatType.none);
      expect(task.status, TaskStatus.pending);
      expect(task.tags, isEmpty);
      expect(task.subtasks, isEmpty);
      expect(task.priority, 'none');
    });

    test('toJson round-trip preserves core fields', () {
      final original = Task(
        id: 't3',
        title: 'Round-trip test',
        description: 'Test desc',
        priority: 'medium',
        status: TaskStatus.completed,
        tags: ['test'],
        createdAt: DateTime.parse('2026-02-08T09:00:00.000Z'),
      );

      final json = original.toJson();
      final restored = Task.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.description, original.description);
      expect(restored.priority, original.priority);
      expect(restored.status, original.status);
      expect(restored.tags, original.tags);
    });

    test('TaskStatus parsing covers all values', () {
      final pending = Task.fromJson({'id': '1', 'title': 't', 'status': 'pending', 'createdAt': '2026-01-01T00:00:00Z'});
      final ongoing = Task.fromJson({'id': '1', 'title': 't', 'status': 'ongoing', 'createdAt': '2026-01-01T00:00:00Z'});
      final completed = Task.fromJson({'id': '1', 'title': 't', 'status': 'completed', 'createdAt': '2026-01-01T00:00:00Z'});
      final overdue = Task.fromJson({'id': '1', 'title': 't', 'status': 'overdue', 'createdAt': '2026-01-01T00:00:00Z'});

      expect(pending.status, TaskStatus.pending);
      expect(ongoing.status, TaskStatus.ongoing);
      expect(completed.status, TaskStatus.completed);
      expect(overdue.status, TaskStatus.overdue);
    });
  });

  group('Subtask model', () {
    test('fromJson creates subtask', () {
      final subtask = Subtask.fromJson({'title': 'Do thing', 'completed': true});
      expect(subtask.title, 'Do thing');
      expect(subtask.completed, true);
    });

    test('toJson round-trip works', () {
      final original = Subtask(title: 'Test', completed: false);
      final json = original.toJson();
      final restored = Subtask.fromJson(json);
      expect(restored.title, 'Test');
      expect(restored.completed, false);
    });

    test('copyWith updates fields', () {
      final subtask = Subtask(title: 'Original', completed: false);
      final updated = subtask.copyWith(completed: true);
      expect(updated.completed, true);
      expect(updated.title, 'Original');
    });
  });

  group('RepeatType parsing', () {
    test('parses all repeat types', () {
      expect(Task.fromJson({'id': '1', 'title': 't', 'repeatType': 'daily', 'createdAt': '2026-01-01T00:00:00Z'}).repeatType, RepeatType.daily);
      expect(Task.fromJson({'id': '1', 'title': 't', 'repeatType': 'weekly', 'createdAt': '2026-01-01T00:00:00Z'}).repeatType, RepeatType.weekly);
      expect(Task.fromJson({'id': '1', 'title': 't', 'repeatType': 'monthly', 'createdAt': '2026-01-01T00:00:00Z'}).repeatType, RepeatType.monthly);
      expect(Task.fromJson({'id': '1', 'title': 't', 'repeatType': 'yearly', 'createdAt': '2026-01-01T00:00:00Z'}).repeatType, RepeatType.yearly);
    });
  });
}
