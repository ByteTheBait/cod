import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/message.dart';

void main() {
  group('Message', () {
    test('factories set the correct role', () {
      expect(Message.user('hi').role, MessageRole.user);
      expect(Message.assistant('yo').role, MessageRole.assistant);
      expect(Message.system('sys').role, MessageRole.system);
    });

    test('assistant factory can mark streaming', () {
      final m = Message.assistant('partial', isStreaming: true);
      expect(m.isStreaming, isTrue);
      expect(Message.assistant('done').isStreaming, isFalse);
    });

    test('generates a unique id and timestamp by default', () {
      final a = Message.user('a');
      final b = Message.user('b');
      expect(a.id, isNot(b.id));
      expect(a.timestamp, isNotNull);
    });

    test('JSON round-trip preserves all fields', () {
      final original = Message.assistant('hello world', isStreaming: true);
      final restored = Message.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.role, original.role);
      expect(restored.content, original.content);
      expect(restored.timestamp, original.timestamp);
    });

    test('fromJson parses a user message', () {
      final json = {
        'id': 'abc',
        'role': 'user',
        'content': 'what is 2+2?',
        'timestamp': '2024-01-01T00:00:00.000',
      };
      final m = Message.fromJson(json);
      expect(m.id, 'abc');
      expect(m.role, MessageRole.user);
      expect(m.content, 'what is 2+2?');
      expect(m.timestamp, DateTime.parse('2024-01-01T00:00:00.000'));
    });
  });
}
