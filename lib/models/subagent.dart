import 'package:flutter/material.dart';

/// Named icons that sub-agents can use. Stored as a string key so the app can
/// tree-shake icon fonts (no non-constant IconData at runtime).
class SubAgentIcons {
  static const explore = 'explore';
  static const debug = 'debug';
  static const refactor = 'refactor';
  static const test = 'test';
  static const security = 'security';
  static const data = 'data';
  static const bolt = 'bolt';
  static const clean = 'clean';
  static const rocket = 'rocket';
  static const defaultIcon = 'default';

  /// All selectable icon keys, in display order.
  static const all = [
    defaultIcon, explore, debug, refactor, test,
    security, data, bolt, clean, rocket,
  ];

  /// Resolve an icon key to a constant IconData.
  static IconData dataOf(String? key) => _map[key] ?? _map[defaultIcon]!;

  static const _map = {
    explore: Icons.travel_explore_outlined,
    debug: Icons.bug_report_outlined,
    refactor: Icons.auto_fix_high_outlined,
    test: Icons.science_outlined,
    security: Icons.security_outlined,
    data: Icons.data_object_outlined,
    bolt: Icons.bolt_outlined,
    clean: Icons.cleaning_services_outlined,
    rocket: Icons.rocket_launch_outlined,
    defaultIcon: Icons.smart_toy_outlined,
  };
}

/// A specialised agent with its own system prompt and restricted tool set.
/// Defaults ship with the app (explore, debug, refactor, test); users can add
/// their own custom subagents from Settings.
class SubAgent {
  final String id;
  final String name;
  final String description;
  /// An icon key from [SubAgentIcons]. Resolve to an IconData with
  /// [SubAgentIcons.dataOf].
  final String icon;
  /// System prompt that shapes the subagent's behaviour.
  final String systemPrompt;
  /// Names of the tools this subagent may use. Names must match the tools
  /// exposed by [AgentService.codeTools] (e.g. 'read_file', 'run_command').
  final List<String> tools;
  /// Optional model override. When null, the subagent uses the Code feature's
  /// default model for the active provider.
  final String? model;
  /// True for the built-in subagents; user-created ones are false.
  final bool isDefault;

  const SubAgent({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.systemPrompt,
    required this.tools,
    this.model,
    this.isDefault = false,
  });

  IconData get iconData => SubAgentIcons.dataOf(icon);

  SubAgent copyWith({
    String? name,
    String? description,
    String? icon,
    String? systemPrompt,
    List<String>? tools,
    Object? model = _unset,
  }) =>
      SubAgent(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        icon: icon ?? this.icon,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        tools: tools ?? this.tools,
        model: identical(model, _unset) ? this.model : model as String?,
        isDefault: isDefault,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'icon': icon,
        'systemPrompt': systemPrompt,
        'tools': tools,
        if (model != null) 'model': model,
        'isDefault': isDefault,
      };

  factory SubAgent.fromJson(Map<String, dynamic> j) => SubAgent(
        id: j['id'] as String,
        name: j['name'] as String,
        description: j['description'] as String? ?? '',
        icon: j['icon'] as String? ?? SubAgentIcons.defaultIcon,
        systemPrompt: j['systemPrompt'] as String,
        tools: (j['tools'] as List? ?? []).cast<String>(),
        model: j['model'] as String?,
        isDefault: j['isDefault'] as bool? ?? false,
      );
}

const _unset = Object();

/// The built-in subagents that ship with the app.
class SubAgentDefaults {
  static const _readTools = ['read_file', 'list_directory', 'search_files'];
  static const _editTools = [
    'read_file', 'str_replace_file', 'multi_edit', 'write_file',
    'list_directory', 'search_files', 'create_directory',
  ];
  static const _shellTools = [
    'run_command', 'background_start', 'background_status',
    'background_list', 'background_kill',
  ];

  static const List<SubAgent> all = [
    SubAgent(
      id: 'explore',
      name: 'Explore',
      description: 'Read-only exploration of the codebase. Reports structure, '
          'key files, and findings without changing anything.',
      icon: SubAgentIcons.explore,
      systemPrompt: 'You are an exploration agent. Your job is to understand '
          'and report on the codebase without modifying anything. '
          'Use read_file, list_directory, and search_files to map out the '
          'project structure, identify key files, and answer questions about '
          'how things work. Be thorough and cite specific file paths. '
          'Never write, edit, or run commands.',
      tools: _readTools,
      isDefault: true,
    ),
    SubAgent(
      id: 'debug',
      name: 'Debug',
      description: 'Diagnoses and fixes bugs. Reads code and runs commands to '
          'reproduce issues, then proposes or applies fixes.',
      icon: SubAgentIcons.debug,
      systemPrompt: 'You are a debugging agent. Diagnose the reported problem '
          'by reading relevant files and running commands to reproduce it. '
          'Form a hypothesis, verify it, then fix the root cause with minimal, '
          'correct changes. Always read a file before editing it. '
          'Use str_replace_file for targeted edits and multi_edit for several '
          'related edits. Run tests or commands to confirm the fix.',
      tools: [..._readTools, ..._editTools, ..._shellTools],
      isDefault: true,
    ),
    SubAgent(
      id: 'refactor',
      name: 'Refactor',
      description: 'Improves code structure and readability. Reads, edits, and '
          'runs commands to verify changes.',
      icon: SubAgentIcons.refactor,
      systemPrompt: 'You are a refactoring agent. Improve the structure, '
          'readability, and maintainability of the code while preserving '
          'behaviour. Read files before editing. Prefer str_replace_file for '
          'targeted edits and multi_edit for several related edits across '
          'files. Run commands to verify nothing is broken. Make minimal, '
          'safe changes and explain what you did.',
      tools: [..._readTools, ..._editTools, ..._shellTools],
      isDefault: true,
    ),
    SubAgent(
      id: 'test',
      name: 'Test',
      description: 'Writes and runs tests. Reads code, creates test files, and '
          'runs the test suite to verify behaviour.',
      icon: SubAgentIcons.test,
      systemPrompt: 'You are a testing agent. Read the relevant source to '
          'understand expected behaviour, then write focused tests. '
          'Use write_file for new test files and str_replace_file for edits. '
          'Run the test suite with run_command to verify tests pass, and fix '
          'any failures. Report which tests you added and their results.',
      tools: [..._readTools, ..._editTools, ..._shellTools],
      isDefault: true,
    ),
  ];

  static SubAgent byId(String id) =>
      all.firstWhere((a) => a.id == id, orElse: () => all.first);
}
