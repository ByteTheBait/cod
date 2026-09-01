import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/tool.dart';

void main() {
  group('Tool serialization', () {
    const tool = Tool(
      name: 'read_file',
      description: 'Read the contents of a file.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
    );

    test('toClaudeJson uses input_schema', () {
      final json = tool.toClaudeJson();
      expect(json['name'], 'read_file');
      expect(json['description'], 'Read the contents of a file.');
      expect(json['input_schema']['type'], 'object');
      expect(json['input_schema']['required'], ['path']);
    });

    test('toOpenAIJson wraps in function', () {
      final json = tool.toOpenAIJson();
      expect(json['type'], 'function');
      final fn = json['function'] as Map<String, dynamic>;
      expect(fn['name'], 'read_file');
      expect(fn['parameters']['required'], ['path']);
    });

    test('toGeminiJson uses parameters', () {
      final json = tool.toGeminiJson();
      expect(json['name'], 'read_file');
      expect(json['parameters']['type'], 'object');
    });
  });

  group('ToolCall', () {
    test('stores id, name and input', () {
      const call = ToolCall(
        id: 'toolu_1',
        name: 'write_file',
        input: {'path': 'a.txt', 'content': 'hi'},
      );
      expect(call.id, 'toolu_1');
      expect(call.name, 'write_file');
      expect(call.input['content'], 'hi');
    });
  });

  group('AgentEvent sealed hierarchy', () {
    test('AgentText carries text', () {
      const e = AgentText('hello');
      expect(e.text, 'hello');
    });

    test('AgentToolStart carries the call', () {
      const call = ToolCall(id: '1', name: 'run_command', input: {'command': 'ls'});
      const e = AgentToolStart(call);
      expect(e.call.name, 'run_command');
    });

    test('AgentToolDone carries name and result', () {
      const e = AgentToolDone('read_file', 'file contents');
      expect(e.toolName, 'read_file');
      expect(e.result, 'file contents');
    });

    test('AgentCommandOutput carries a line', () {
      const e = AgentCommandOutput('stdout line');
      expect(e.line, 'stdout line');
    });

    test('AgentComplete and AgentError exist', () {
      const done = AgentComplete();
      const err = AgentError('boom');
      expect(done, isA<AgentEvent>());
      expect(err.message, 'boom');
    });
  });
}
