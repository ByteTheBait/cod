import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cod/widgets/ai_input_field.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('AiInputField', () {
    testWidgets('renders the hint text', (tester) async {
      await tester.pumpWidget(wrap(
        AiInputField(controller: TextEditingController(), hintText: 'Ask…'),
      ));
      expect(find.text('Ask…'), findsOneWidget);
    });

    testWidgets('Enter inserts a newline instead of sending', (tester) async {
      final ctrl = TextEditingController(text: 'line one');
      var sent = 0;
      await tester.pumpWidget(wrap(
        AiInputField(controller: ctrl, hintText: 'hint', onSend: () => sent++),
      ));

      final field = find.byType(TextField);
      await tester.showKeyboard(field);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(ctrl.text, 'line one\n');
      expect(sent, 0);
    });

    testWidgets('Shift+Enter sends the message', (tester) async {
      final ctrl = TextEditingController(text: 'hello');
      var sent = 0;
      await tester.pumpWidget(wrap(
        AiInputField(controller: ctrl, hintText: 'hint', onSend: () => sent++),
      ));

      final field = find.byType(TextField);
      await tester.showKeyboard(field);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(sent, 1);
      expect(ctrl.text, 'hello'); // unchanged
    });

    testWidgets('does not send when onSend is null', (tester) async {
      final ctrl = TextEditingController(text: 'hi');
      await tester.pumpWidget(wrap(
        AiInputField(controller: ctrl, hintText: 'hint'),
      ));

      final field = find.byType(TextField);
      await tester.showKeyboard(field);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(ctrl.text, 'hi');
    });
  });
}
