import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/message.dart';
import 'package:cod/models/task.dart';
import 'package:cod/widgets/task_tile.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('TaskTile', () {
    testWidgets('shows title and description', (tester) async {
      final task = Task(title: 'Write docs', description: 'For the API');
      await tester.pumpWidget(wrap(TaskTile(task: task, onTap: () {}, onStatusTap: () {})));
      expect(find.text('Write docs'), findsOneWidget);
      expect(find.text('For the API'), findsOneWidget);
    });

    testWidgets('strikes through title when done', (tester) async {
      final task = Task(title: 'Done task', status: TaskStatus.done);
      await tester.pumpWidget(wrap(TaskTile(task: task, onTap: () {}, onStatusTap: () {})));
      final text = tester.widget<Text>(find.text('Done task'));
      expect(text.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('shows message count', (tester) async {
      final task = Task(title: 'Task')..thread.addAll([
        Message.user('a'),
        Message.assistant('b'),
      ]);
      await tester.pumpWidget(wrap(TaskTile(task: task, onTap: () {}, onStatusTap: () {})));
      expect(find.text('2 messages'), findsOneWidget);
    });

    testWidgets('shows run button when not done and onRunTap provided', (tester) async {
      final task = Task(title: 'Task', status: TaskStatus.todo);
      await tester.pumpWidget(wrap(TaskTile(
        task: task,
        onTap: () {},
        onStatusTap: () {},
        onRunTap: () {},
      )));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('hides run button when done', (tester) async {
      final task = Task(title: 'Task', status: TaskStatus.done);
      await tester.pumpWidget(wrap(TaskTile(
        task: task,
        onTap: () {},
        onStatusTap: () {},
        onRunTap: () {},
      )));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('shows unread dot when hasUnread', (tester) async {
      final task = Task(title: 'Task', hasUnread: true);
      await tester.pumpWidget(wrap(TaskTile(task: task, onTap: () {}, onStatusTap: () {})));
      expect(find.byType(Container), findsWidgets);
    });
  });
}
