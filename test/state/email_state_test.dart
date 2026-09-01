import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/email_model.dart';
import 'package:cod/state/email.dart';

void main() {
  group('EmailState', () {
    test('defaults to unknown status', () {
      const state = EmailState();
      expect(state.status, EmailConnectionStatus.unknown);
      expect(state.threads, isEmpty);
      expect(state.loading, isFalse);
      expect(state.userEmail, '');
    });

    test('copyWith updates fields', () {
      const state = EmailState();
      final next = state.copyWith(
        status: EmailConnectionStatus.connected,
        userEmail: 'me@x.com',
        loading: true,
      );
      expect(next.status, EmailConnectionStatus.connected);
      expect(next.userEmail, 'me@x.com');
      expect(next.loading, isTrue);
    });

    test('clearError resets error', () {
      const state = EmailState(error: 'oops');
      expect(state.copyWith(clearError: true).error, isNull);
    });
  });

  group('EmailState thread helpers', () {
    test('setAiSummary updates the matching thread', () {
      final state = EmailState(threads: [
        GmailThread(id: 't1', subject: 'a', from: 'x', snippet: '', date: DateTime(2024, 1, 1), isUnread: false),
        GmailThread(id: 't2', subject: 'b', from: 'y', snippet: '', date: DateTime(2024, 1, 1), isUnread: false),
      ]);
      final next = state.copyWith(
        threads: state.threads.map((t) {
          if (t.id == 't2') t.aiSummary = 'summary';
          return t;
        }).toList(),
      );
      expect(next.threads[1].aiSummary, 'summary');
      expect(next.threads[0].aiSummary, isNull);
    });
  });
}
