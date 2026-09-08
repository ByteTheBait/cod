import 'package:flutter_test/flutter_test.dart';
import 'package:cod/state/code.dart';
import 'package:cod/state/sessions.dart';
import 'package:cod/state/calendar.dart';
import 'package:cod/state/email.dart';
import 'package:cod/models/calendar_model.dart';
import 'package:cod/models/session.dart';

void main() {
  group('CodeState.copyWith edge cases', () {
    test('can set subAgentId to null explicitly', () {
      const state = CodeState(subAgentId: 'explore');
      final next = state.copyWith(subAgentId: null);
      expect(next.subAgentId, isNull);
    });

    test('can set activeSessionId to null explicitly', () {
      const state = CodeState(activeSessionId: 's1');
      final next = state.copyWith(activeSessionId: null);
      expect(next.activeSessionId, isNull);
    });

    test('can set activeWorkspaceId to null explicitly', () {
      const state = CodeState(activeWorkspaceId: 'w1');
      final next = state.copyWith(activeWorkspaceId: null);
      expect(next.activeWorkspaceId, isNull);
    });

    test('can set sandboxType to null explicitly', () {
      const state = CodeState(sandboxType: SandboxType.docker);
      final next = state.copyWith(sandboxType: null);
      expect(next.sandboxType, isNull);
    });

    test('clearSandboxError clears error', () {
      const state = CodeState(sandboxError: 'boom');
      expect(state.copyWith(clearSandboxError: true).sandboxError, isNull);
      expect(state.copyWith(sandboxError: 'new').sandboxError, 'new');
    });

    test('preserves fields not passed', () {
      const state = CodeState(workingDir: '/tmp', isRunning: true, mode: CodeMode.ask);
      final next = state.copyWith(workingDir: '/other');
      expect(next.workingDir, '/other');
      expect(next.isRunning, isTrue);
      expect(next.mode, CodeMode.ask);
    });
  });

  group('CodeWorkspace.copyWith edge cases', () {
    test('can set activeFileIndex to null explicitly', () {
      const ws = CodeWorkspace(id: 'w', title: 't', activeFileIndex: 2);
      final next = ws.copyWith(activeFileIndex: null);
      expect(next.activeFileIndex, isNull);
    });

    test('can set activeSessionId to null explicitly', () {
      const ws = CodeWorkspace(id: 'w', title: 't', activeSessionId: 's');
      final next = ws.copyWith(activeSessionId: null);
      expect(next.activeSessionId, isNull);
    });

    test('can set subAgentId to null explicitly', () {
      const ws = CodeWorkspace(id: 'w', title: 't', subAgentId: 'x');
      final next = ws.copyWith(subAgentId: null);
      expect(next.subAgentId, isNull);
    });

    test('preserves fields not passed', () {
      const ws = CodeWorkspace(id: 'w', title: 't', mode: CodeMode.edit, estimatedTokens: 5);
      final next = ws.copyWith(title: 'new');
      expect(next.title, 'new');
      expect(next.mode, CodeMode.edit);
      expect(next.estimatedTokens, 5);
    });
  });

  group('CodeSession.fromJson edge cases', () {
    test('missing updatedAt falls back to now', () {
      final s = CodeSession.fromJson({
        'id': 'a',
        'title': 't',
        'entries': [],
      });
      expect(s.updatedAt, isNotNull);
    });

    test('missing entries defaults to empty', () {
      final s = CodeSession.fromJson({
        'id': 'a',
        'title': 't',
        'updatedAt': '2024-01-01T00:00:00.000',
      });
      expect(s.entries, isEmpty);
      expect(s.history, isEmpty);
    });
  });

  group('SessionsState.copyWith edge cases', () {
    test('activeId null with clearActive false keeps existing', () {
      final s = Session(providerId: 'claude', modelId: 'm');
      final state = SessionsState(sessions: [s], activeId: s.id);
      // Passing activeId: null should NOT clear it (only clearActive does).
      final next = state.copyWith();
      expect(next.activeId, s.id);
    });
  });

  group('CalendarState.eventsForDay edge cases', () {
    test('handles all-day events spanning midnight', () {
      final state = CalendarState(events: [
        CalendarEvent(
          id: 'all-day',
          title: 'Holiday',
          start: DateTime(2024, 6, 1),
          end: DateTime(2024, 6, 2),
          isAllDay: true,
        ),
      ]);
      // All-day event starts on June 1, so it should appear on June 1.
      expect(state.eventsForDay(DateTime(2024, 6, 1)).length, 1);
      // It should NOT appear on June 2 (start is June 1).
      expect(state.eventsForDay(DateTime(2024, 6, 2)), isEmpty);
    });

    test('empty events returns empty', () {
      final state = CalendarState();
      expect(state.eventsForDay(DateTime(2024, 1, 1)), isEmpty);
    });
  });

  group('EmailState.copyWith edge cases', () {
    test('clearError resets error', () {
      const state = EmailState(error: 'oops');
      expect(state.copyWith(clearError: true).error, isNull);
      expect(state.copyWith(error: 'new').error, 'new');
    });

    test('preserves fields not passed', () {
      const state = EmailState(status: EmailConnectionStatus.connected, userEmail: 'a@b.com');
      final next = state.copyWith(loading: true);
      expect(next.status, EmailConnectionStatus.connected);
      expect(next.userEmail, 'a@b.com');
      expect(next.loading, isTrue);
    });
  });
}
