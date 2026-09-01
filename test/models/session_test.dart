import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/message.dart';
import 'package:cod/models/session.dart';

void main() {
  group('Session.titleFrom', () {
    test('trims surrounding whitespace', () {
      expect(Session.titleFrom('  hello  '), 'hello');
    });

    test('collapses internal whitespace', () {
      expect(Session.titleFrom('a   b\n\tc'), 'a b c');
    });

    test('keeps short titles unchanged', () {
      final short = 'a' * 42;
      expect(Session.titleFrom(short), short);
    });

    test('truncates long titles with an ellipsis', () {
      final long = 'a' * 50;
      final result = Session.titleFrom(long);
      expect(result.length, 42);
      expect(result.endsWith('...'), isTrue);
      expect(result.substring(0, 39), 'a' * 39);
    });
  });

  group('Session', () {
    test('defaults to "New chat" title and empty messages', () {
      final s = Session(providerId: 'claude', modelId: 'claude-sonnet-4-6');
      expect(s.title, 'New chat');
      expect(s.messages, isEmpty);
      expect(s.providerId, 'claude');
      expect(s.modelId, 'claude-sonnet-4-6');
    });

    test('JSON round-trip preserves fields', () {
      final s = Session(
        providerId: 'gemini',
        modelId: 'gemini-2.0-flash',
        title: 'My session',
      )..messages.add(Message.user('hello'));
      final restored = Session.fromJson(s.toJson());
      expect(restored.id, s.id);
      expect(restored.title, 'My session');
      expect(restored.providerId, 'gemini');
      expect(restored.modelId, 'gemini-2.0-flash');
      expect(restored.messages.length, 1);
      expect(restored.messages.first.content, 'hello');
      expect(restored.createdAt, s.createdAt);
      expect(restored.updatedAt, s.updatedAt);
    });
  });
}
