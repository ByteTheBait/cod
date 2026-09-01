import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/email_model.dart';

void main() {
  group('GmailThread', () {
    test('stores thread metadata', () {
      final t = GmailThread(
        id: 'thread1',
        subject: 'Hello',
        from: 'a@x.com',
        snippet: '...',
        date: DateTime(2024, 1, 1),
        isUnread: true,
      );
      expect(t.id, 'thread1');
      expect(t.subject, 'Hello');
      expect(t.from, 'a@x.com');
      expect(t.isUnread, isTrue);
      expect(t.messages, isNull);
      expect(t.aiSummary, isNull);
    });
  });

  group('GmailMessage', () {
    test('stores message fields', () {
      final m = GmailMessage(
        id: 'msg1',
        from: 'a@x.com',
        to: 'b@x.com',
        subject: 'Re: Hello',
        body: 'Thanks!',
        date: DateTime(2024, 1, 1),
        messageId: '<abc@mail>',
      );
      expect(m.id, 'msg1');
      expect(m.from, 'a@x.com');
      expect(m.to, 'b@x.com');
      expect(m.subject, 'Re: Hello');
      expect(m.body, 'Thanks!');
      expect(m.messageId, '<abc@mail>');
    });
  });

  group('EmailMode', () {
    test('labels match the modes', () {
      expect(EmailMode.summaryOnly.label, 'Summarize');
      expect(EmailMode.draftWait.label, 'Draft reply');
      expect(EmailMode.autoSend.label, 'Auto send');
    });
  });
}
