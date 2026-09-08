import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/message.dart';
import 'package:cod/models/session.dart';
import 'package:cod/models/task.dart';
import 'package:cod/models/config.dart';
import 'package:cod/models/calendar_model.dart';
import 'package:cod/models/subagent.dart';
import 'package:cod/models/command.dart';
import 'package:cod/state/code.dart';
import 'package:cod/utils/security.dart';
import 'package:cod/services/update_service.dart';

void main() {
  group('Message.fromJson edge cases', () {
    test('throws on invalid role name', () {
      expect(
        () => Message.fromJson({
          'id': 'a',
          'role': 'not_a_role',
          'content': 'hi',
          'timestamp': '2024-01-01T00:00:00.000',
        }),
        throwsA(anything),
      );
    });

    test('throws on missing timestamp', () {
      expect(
        () => Message.fromJson({
          'id': 'a',
          'role': 'user',
          'content': 'hi',
        }),
        throwsA(anything),
      );
    });
  });

  group('Task.fromJson edge cases', () {
    test('throws on invalid status name', () {
      expect(
        () => Task.fromJson({
          'id': 'a',
          'title': 't',
          'status': 'bogus',
          'skill': 'general',
          'createdAt': '2024-01-01T00:00:00.000',
          'updatedAt': '2024-01-01T00:00:00.000',
        }),
        throwsA(anything),
      );
    });

    test('throws on invalid createdAt', () {
      expect(
        () => Task.fromJson({
          'id': 'a',
          'title': 't',
          'status': 'todo',
          'skill': 'general',
          'createdAt': 'not-a-date',
          'updatedAt': '2024-01-01T00:00:00.000',
        }),
        throwsA(anything),
      );
    });

    test('falls back to general skill for unknown skill', () {
      final t = Task.fromJson({
        'id': 'a',
        'title': 't',
        'status': 'todo',
        'skill': 'unknown_skill',
        'createdAt': '2024-01-01T00:00:00.000',
        'updatedAt': '2024-01-01T00:00:00.000',
      });
      expect(t.skill, TaskSkill.general);
    });

    test('handles missing optional fields', () {
      final t = Task.fromJson({
        'id': 'a',
        'title': 't',
        'status': 'todo',
        'createdAt': '2024-01-01T00:00:00.000',
        'updatedAt': '2024-01-01T00:00:00.000',
      });
      expect(t.description, '');
      expect(t.skill, TaskSkill.general);
      expect(t.thread, isEmpty);
      expect(t.hasUnread, isFalse);
    });
  });

  group('Session.fromJson edge cases', () {
    test('throws on missing messages list', () {
      expect(
        () => Session.fromJson({
          'id': 'a',
          'title': 't',
          'createdAt': '2024-01-01T00:00:00.000',
          'updatedAt': '2024-01-01T00:00:00.000',
          'providerId': 'claude',
          'modelId': 'm',
        }),
        throwsA(anything),
      );
    });
  });

  group('Session.titleFrom edge cases', () {
    test('empty string stays empty', () {
      expect(Session.titleFrom(''), '');
    });

    test('whitespace-only collapses to empty', () {
      expect(Session.titleFrom('   \n\t  '), '');
    });

    test('exactly 42 chars is not truncated', () {
      final s = 'a' * 42;
      expect(Session.titleFrom(s), s);
    });

    test('43 chars is truncated to 42 with ellipsis', () {
      final result = Session.titleFrom('a' * 43);
      expect(result.length, 42);
      expect(result.endsWith('...'), isTrue);
    });
  });

  group('Task expiry edge cases', () {
    test('isExpired with negative ttlDays never expires', () {
      final old = Task(
        title: 'old',
        updatedAt: DateTime.now().subtract(const Duration(days: 30)),
      );
      expect(old.isExpired(-1), isFalse);
    });

    test('isExpired exactly at boundary', () {
      final t = Task(
        title: 't',
        updatedAt: DateTime.now().subtract(const Duration(seconds: 2 * 86400)),
      );
      expect(t.isExpired(2), isTrue);
    });

    test('timeUntilExpiry with negative ttlDays returns null', () {
      final t = Task(title: 't');
      expect(t.timeUntilExpiry(-1), isNull);
    });

    test('timeUntilExpiry already expired returns zero', () {
      final t = Task(
        title: 't',
        updatedAt: DateTime.now().subtract(const Duration(days: 5)),
      );
      expect(t.timeUntilExpiry(2), Duration.zero);
    });
  });

  group('AppConfig.active edge cases', () {
    test('active with empty providers does not crash', () {
      const c = AppConfig(
        activeProviderId: 'missing',
        providers: {},
      );
      // Should not throw; returns a safe fallback.
      expect(c.active, isNotNull);
    });

    test('active falls back to first provider when id missing', () {
      const c = AppConfig(
        activeProviderId: 'nope',
        providers: {
          'claude': ProviderConfig(
            id: 'claude',
            name: 'Claude',
            selectedModel: 'm',
            models: ['m'],
          ),
        },
      );
      expect(c.active.id, 'claude');
    });
  });

  group('ProviderConfig.modelFor edge cases', () {
    test('empty featureModels falls back to selectedModel', () {
      const p = ProviderConfig(
        id: 'x',
        name: 'X',
        selectedModel: 'default',
        models: ['default'],
        featureModels: {},
      );
      expect(p.modelFor(Feature.code), 'default');
    });
  });

  group('CalendarEvent.fromJson edge cases', () {
    test('missing start/end defaults to now', () {
      final e = CalendarEvent.fromJson({'id': 'x', 'summary': 'S'});
      expect(e.start, isNotNull);
      expect(e.end, isNotNull);
    });

    test('malformed attendees are skipped', () {
      final e = CalendarEvent.fromJson({
        'id': 'x',
        'summary': 'S',
        'start': {'dateTime': '2024-06-01T09:00:00Z'},
        'end': {'dateTime': '2024-06-01T09:30:00Z'},
        'attendees': [
          {'email': 'a@x.com'},
          'not-a-map',
          null,
        ],
      });
      expect(e.attendees, ['a@x.com']);
    });
  });

  group('CalendarSuggestion.fromJson edge cases', () {
    test('unknown type maps to info', () {
      final s = CalendarSuggestion.fromJson({
        'title': 'x',
        'detail': 'y',
        'type': 'weird',
      });
      expect(s.action, SuggestionAction.info);
    });

    test('malformed event start falls back to now', () {
      final s = CalendarSuggestion.fromJson({
        'title': 'x',
        'detail': 'y',
        'type': 'add',
        'event': {'title': 'E', 'start': 'not-a-date', 'end': 'also-bad'},
      });
      expect(s.event, isNotNull);
      expect(s.event!.start, isNotNull);
    });
  });

  group('CodeEntry.fromJson edge cases', () {
    test('unknown type falls back to assistantText', () {
      final e = CodeEntry.fromJson({
        'type': 'bogus',
        'content': 'hi',
        'ts': 0,
      });
      expect(e.type, CodeEntryType.assistantText);
    });

    test('missing ts throws', () {
      expect(
        () => CodeEntry.fromJson({'type': 'user', 'content': 'hi'}),
        throwsA(anything),
      );
    });
  });

  group('SubAgent.fromJson edge cases', () {
    test('missing systemPrompt throws', () {
      expect(
        () => SubAgent.fromJson({'id': 'a', 'name': 'n'}),
        throwsA(anything),
      );
    });

    test('missing icon falls back to default', () {
      final a = SubAgent.fromJson({
        'id': 'a',
        'name': 'n',
        'systemPrompt': 'p',
      });
      expect(a.icon, SubAgentIcons.defaultIcon);
    });
  });

  group('Shortcut.fromJson edge cases', () {
    test('missing id throws', () {
      expect(
        () => Shortcut.fromJson({'key': 'cmd+k'}),
        throwsA(anything),
      );
    });

    test('missing defaultKey falls back to empty', () {
      final s = Shortcut.fromJson({'id': 'x'});
      expect(s.defaultKey, '');
      expect(s.effectiveKey, '');
    });
  });

  group('security.isCommandBlocked edge cases', () {
    test('blocks rm -rf on root', () {
      expect(isCommandBlocked('rm -rf /'), isTrue);
    });

    test('blocks sudo', () {
      expect(isCommandBlocked('sudo rm -rf /'), isTrue);
    });

    test('blocks fork bomb', () {
      expect(isCommandBlocked(':(){ :|:& };:'), isTrue);
    });

    test('blocks dd to /dev', () {
      expect(isCommandBlocked('dd if=/dev/zero of=/dev/sda'), isTrue);
    });

    test('allows benign command', () {
      expect(isCommandBlocked('ls -la'), isFalse);
    });

    test('allows rm of a single file in working dir', () {
      expect(isCommandBlocked('rm file.txt'), isFalse);
    });
  });

  group('security.redactSecrets edge cases', () {
    test('skips short secret values', () {
      expect(redactSecrets('abc', {'ab'}), 'abc');
    });

    test('redacts long secret values', () {
      expect(redactSecrets('token=supersecretvalue', {'supersecretvalue'}),
          'token=REDACTED');
    });

    test('empty text returns empty', () {
      expect(redactSecrets('', {'abcde'}), '');
    });

    test('no secrets returns text unchanged', () {
      expect(redactSecrets('hello world', {}), 'hello world');
    });
  });

  group('UpdateService version comparison edge cases', () {
    test('equal versions are not newer', () {
      expect(UpdateService.isNewer('2.7.9', '2.7.9'), isFalse);
    });

    test('newer patch is newer', () {
      expect(UpdateService.isNewer('2.7.10', '2.7.9'), isTrue);
    });

    test('older is not newer', () {
      expect(UpdateService.isNewer('2.7.8', '2.7.9'), isFalse);
    });

    test('build metadata does not break comparison', () {
      // current "2.7.9+1" should NOT be considered older than "2.7.9"
      expect(UpdateService.isNewer('2.7.9', '2.7.9+1'), isFalse);
    });

    test('prerelease-ish suffix does not break comparison', () {
      expect(UpdateService.isNewer('2.7.9', '2.7.9-beta'), isFalse);
    });

    test('non-numeric segments are treated as zero', () {
      expect(UpdateService.isNewer('2.7.9', '2.7'), isTrue);
    });
  });
}
