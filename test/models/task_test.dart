import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/message.dart';
import 'package:cod/models/task.dart';

void main() {
  group('TaskStatus', () {
    test('cycles todo → in progress → done → todo', () {
      expect(TaskStatus.todo.next, TaskStatus.inProgress);
      expect(TaskStatus.inProgress.next, TaskStatus.done);
      expect(TaskStatus.done.next, TaskStatus.todo);
    });

    test('labels are human readable', () {
      expect(TaskStatus.todo.label, 'todo');
      expect(TaskStatus.inProgress.label, 'in progress');
      expect(TaskStatus.done.label, 'done');
    });
  });

  group('Task', () {
    test('defaults to todo status and general skill', () {
      final t = Task(title: 'Write docs');
      expect(t.status, TaskStatus.todo);
      expect(t.skill, TaskSkill.general);
      expect(t.thread, isEmpty);
      expect(t.hasUnread, isFalse);
    });

    test('generates a unique id when none provided', () {
      final a = Task(title: 'a');
      final b = Task(title: 'b');
      expect(a.id, isNot(b.id));
    });

    test('JSON round-trip preserves all fields', () {
      final t = Task(
        title: 'Fix bug',
        description: 'in the agent loop',
        status: TaskStatus.inProgress,
        skill: TaskSkill.code,
        thread: [Message.user('go'), Message.assistant('done')],
        hasUnread: true,
      );
      final restored = Task.fromJson(t.toJson());
      expect(restored.id, t.id);
      expect(restored.title, 'Fix bug');
      expect(restored.description, 'in the agent loop');
      expect(restored.status, TaskStatus.inProgress);
      expect(restored.skill, TaskSkill.code);
      expect(restored.thread.length, 2);
      expect(restored.hasUnread, isTrue);
      expect(restored.createdAt, t.createdAt);
      expect(restored.updatedAt, t.updatedAt);
    });

    test('isExpired respects ttlDays', () {
      final fresh = Task(title: 'fresh');
      expect(fresh.isExpired(2), isFalse);

      final old = Task(
        title: 'old',
        updatedAt: DateTime.now().subtract(const Duration(days: 3)),
      );
      expect(old.isExpired(2), isTrue);
      expect(old.isExpired(0), isFalse); // 0 = never expire
    });

    test('timeUntilExpiry returns remaining duration', () {
      final t = Task(
        title: 't',
        updatedAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      final remaining = t.timeUntilExpiry(2);
      expect(remaining, isNotNull);
      expect(remaining!.inHours, closeTo(47, 1));
      expect(t.timeUntilExpiry(0), isNull);
    });
  });
}
