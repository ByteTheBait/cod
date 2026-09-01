import 'package:flutter_test/flutter_test.dart';
import 'package:cod/state/code.dart';

void main() {
  group('CodeEntry', () {
    test('factories set type and content', () {
      expect(CodeEntry.user('hi').type, CodeEntryType.user);
      expect(CodeEntry.assistant('yo').type, CodeEntryType.assistantText);
      expect(CodeEntry.error('bad').type, CodeEntryType.error);
      expect(CodeEntry.toolCall('read_file', 'x').type, CodeEntryType.toolCall);
      expect(CodeEntry.toolCall('read_file', 'x').label, 'read_file');
      expect(CodeEntry.toolResult('write_file', 'ok').type, CodeEntryType.toolResult);
    });

    test('JSON round-trip preserves fields', () {
      final e = CodeEntry.toolCall('run_command', 'ls -la');
      final restored = CodeEntry.fromJson(e.toJson());
      expect(restored.type, CodeEntryType.toolCall);
      expect(restored.content, 'ls -la');
      expect(restored.label, 'run_command');
      expect(restored.timestamp.millisecondsSinceEpoch, e.timestamp.millisecondsSinceEpoch);
    });
  });

  group('CodeState', () {
    test('defaults to agent tab (no active file)', () {
      const state = CodeState();
      expect(state.activeFileIndex, isNull);
      expect(state.openFiles, isEmpty);
      expect(state.workingDir, '');
      expect(state.isRunning, isFalse);
    });

    test('copyWith can set activeFileIndex to null explicitly', () {
      const state = CodeState(activeFileIndex: 2);
      final next = state.copyWith(activeFileIndex: null);
      expect(next.activeFileIndex, isNull);
    });

    test('copyWith preserves fields not passed', () {
      const state = CodeState(workingDir: '/tmp', isRunning: true);
      final next = state.copyWith(workingDir: '/other');
      expect(next.workingDir, '/other');
      expect(next.isRunning, isTrue);
    });
  });
}
