import 'package:flutter_test/flutter_test.dart';
import 'package:cod/llm/agent_llm.dart';
import 'package:cod/models/tool.dart';

void main() {
  group('AgentLLM message conversion edge cases', () {
    // We test the public behavior indirectly through the response parsing
    // helpers that are exercised via the tool-call flow. Since the converters
    // are private, we test the ToolCall/AgentLLMResponse model and the
    // protocol routing contract.

    test('AgentLLMResponse hasToolCalls reflects tool calls', () {
      const empty = AgentLLMResponse(text: '', toolCalls: [], stopReason: 'stop');
      expect(empty.hasToolCalls, isFalse);

      const withCalls = AgentLLMResponse(
        text: '',
        toolCalls: [ToolCall(id: '1', name: 'read_file', input: {'path': 'x'})],
        stopReason: 'tool_use',
      );
      expect(withCalls.hasToolCalls, isTrue);
    });

    test('ToolCall stores arbitrary input maps', () {
      const call = ToolCall(
        id: 't',
        name: 'multi_edit',
        input: {
          'edits': [
            {'path': 'a', 'old_string': 'x', 'new_string': 'y'},
          ],
        },
      );
      expect(call.input['edits'], isA<List>());
    });
  });

  group('CodeMode edge cases', () {
    test('requiresApproval only for ask and plan', () {
      expect(CodeMode.yolo.requiresApproval, isFalse);
      expect(CodeMode.ask.requiresApproval, isTrue);
      expect(CodeMode.plan.requiresApproval, isTrue);
      expect(CodeMode.edit.requiresApproval, isFalse);
    });

    test('editOnly only for edit mode', () {
      expect(CodeMode.edit.editOnly, isTrue);
      expect(CodeMode.yolo.editOnly, isFalse);
      expect(CodeMode.ask.editOnly, isFalse);
      expect(CodeMode.plan.editOnly, isFalse);
    });
  });
}
