import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/message.dart';
import 'package:cod/models/session.dart';
import 'package:cod/state/sessions.dart';

void main() {
  group('SessionsState', () {
    test('active returns null when no active id', () {
      const state = SessionsState();
      expect(state.active, isNull);
    });

    test('active returns the matching session', () {
      final s = Session(providerId: 'claude', modelId: 'claude-sonnet-4-6');
      final state = SessionsState(sessions: [s], activeId: s.id);
      expect(state.active?.id, s.id);
    });

    test('active returns null when active id not found', () {
      final s = Session(providerId: 'claude', modelId: 'claude-sonnet-4-6');
      final state = SessionsState(sessions: [s], activeId: 'missing');
      expect(state.active, isNull);
    });

    test('copyWith clearActive clears the active id', () {
      final s = Session(providerId: 'claude', modelId: 'claude-sonnet-4-6');
      final state = SessionsState(sessions: [s], activeId: s.id);
      expect(state.copyWith(clearActive: true).activeId, isNull);
    });
  });

  group('SessionsState message helpers', () {
    test('addMessage appends and updates title from first user message', () {
      final s = Session(providerId: 'claude', modelId: 'claude-sonnet-4-6');
      final state = SessionsState(sessions: [s], activeId: s.id);
      final next = state.copyWith(
        sessions: state.sessions.map((x) {
          if (x.id != s.id) return x;
          x.messages.add(Message.user('Fix the bug'));
          x.updatedAt = DateTime.now();
          if (x.title == 'New chat') x.title = Session.titleFrom('Fix the bug');
          return x;
        }).toList(),
      );
      expect(next.sessions.first.messages.length, 1);
      expect(next.sessions.first.title, 'Fix the bug');
    });
  });
}
