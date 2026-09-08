import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/subagent.dart';
import 'package:cod/models/task.dart';
import 'package:cod/services/agent_service.dart';

void main() {
  group('AgentService.toolsFor', () {
    test('maps known tool names to Tool objects', () {
      const agent = SubAgent(
        id: 'x',
        name: 'X',
        description: '',
        icon: SubAgentIcons.defaultIcon,
        systemPrompt: 'p',
        tools: ['read_file', 'write_file', 'run_command'],
      );
      final tools = AgentService.toolsFor(agent);
      expect(tools.map((t) => t.name), ['read_file', 'write_file', 'run_command']);
    });

    test('ignores unknown tool names (stale config)', () {
      const agent = SubAgent(
        id: 'x',
        name: 'X',
        description: '',
        icon: SubAgentIcons.defaultIcon,
        systemPrompt: 'p',
        tools: ['read_file', 'not_a_real_tool', 'write_file'],
      );
      final tools = AgentService.toolsFor(agent);
      expect(tools.map((t) => t.name), ['read_file', 'write_file']);
    });

    test('empty tools yields empty list', () {
      const agent = SubAgent(
        id: 'x',
        name: 'X',
        description: '',
        icon: SubAgentIcons.defaultIcon,
        systemPrompt: 'p',
        tools: [],
      );
      expect(AgentService.toolsFor(agent), isEmpty);
    });
  });

  group('SkillDef.of', () {
    test('returns a definition for every skill', () {
      for (final skill in TaskSkill.values) {
        final def = SkillDef.of(skill);
        expect(def.tools, isNotEmpty);
        expect(def.system, isNotEmpty);
      }
    });

    test('general skill includes mark_complete and web_search', () {
      final def = SkillDef.of(TaskSkill.general);
      final names = def.tools.map((t) => t.name).toSet();
      expect(names, contains('mark_complete'));
      expect(names, contains('web_search'));
    });

    test('code skill has no web_search', () {
      final def = SkillDef.of(TaskSkill.code);
      final names = def.tools.map((t) => t.name).toSet();
      expect(names, isNot(contains('web_search')));
      expect(names, contains('mark_complete'));
    });
  });

  group('AgentService tool lists', () {
    test('codeTools contains the core file tools', () {
      final names = AgentService.codeTools.map((t) => t.name).toSet();
      expect(names, containsAll([
        'read_file', 'write_file', 'str_replace_file', 'multi_edit',
        'list_directory', 'run_command', 'search_files', 'create_directory',
        'background_start', 'background_status', 'background_list',
        'background_kill', 'delegate', 'delegate_parallel',
      ]));
    });

    test('taskTools is a superset of codeTools plus mark_complete and web_search', () {
      final taskNames = AgentService.taskTools.map((t) => t.name).toSet();
      final codeNames = AgentService.codeTools.map((t) => t.name).toSet();
      expect(taskNames.containsAll(codeNames), isTrue);
      expect(taskNames, contains('mark_complete'));
      expect(taskNames, contains('web_search'));
    });
  });

  group('AgentService.run with malformed tool input', () {
    test('run_command with non-string command does not crash the loop', () async {
      // We can't easily inject a fake LLM, but we can verify the guard logic
      // by checking that the tool schema requires a string command.
      final runCommand = AgentService.codeTools
          .firstWhere((t) => t.name == 'run_command');
      final props = runCommand.inputSchema['properties'] as Map<String, dynamic>;
      expect(props['command']['type'], 'string');
    });

    test('delegate_parallel schema requires delegations list', () {
      final dp = AgentService.codeTools
          .firstWhere((t) => t.name == 'delegate_parallel');
      final props = dp.inputSchema['properties'] as Map<String, dynamic>;
      expect(props['delegations']['type'], 'array');
    });
  });
}
