import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../llm/agent_llm.dart';
import '../llm/provider.dart';
import '../models/config.dart';
import '../models/subagent.dart';
import '../models/task.dart';
import '../models/tool.dart';
import 'background_service.dart';
import '../utils/security.dart';
import 'package:http/http.dart' as http;

const int _maxFileBytes = 32768;

/// Tools the agent is allowed to run — anything else is refused. This is a
/// belt-and-braces safety net for the "restricted" sandbox: it never runs
/// arbitrary binaries, only a curated allow-list, so a typo or an LLM
/// hallucination can't reach the system. Extend this list deliberately.
const _allowedCommands = {
  'ls', 'cat', 'head', 'tail', 'grep', 'find', 'wc', 'sort', 'uniq',
  'sed', 'awk', 'diff', 'echo', 'pwd', 'which', 'env', 'mkdir', 'touch',
  'cp', 'mv', 'chmod', 'chown', 'df', 'du', 'file', 'tar', 'unzip', 'zip',
  'curl', 'wget', 'git', 'dart', 'flutter', 'dartfmt',
};

/// Detect destructive / high-risk shell commands. Returns a human-readable
/// reason, or null if the command is (heuristically) acceptable.
///
/// This is a safety net, not a security boundary — the true boundary for the
/// agent is the Docker sandbox. Blocking here prevents the most obvious
/// foot-guns and LLM hallucinated `rm -rf` / drive-wipe sequences even when
/// the sandbox is unavailable.
String? _whyBlocked(String command) {
  final normalized = command
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .join(' ');

  final lower = normalized.toLowerCase();

  // Clear the environment of secrets is already handled at exec time; here we
  // refuse commands that trivially exfiltrate the whole env or home.
  if (RegExp(r'(env|printenv|cat\s+[~/]?\.(env|zshrc|bashrc|profile)\b)').hasMatch(lower)) {
    return 'refuses to dump environment variables / dotfiles';
  }
  // Fork bomb + obvious process/disk/network destruction.
  if (lower.contains(':{():|:&};:') ||
      RegExp(r'\b(reboot|shutdown|poweroff|halt)\b').hasMatch(lower)) {
    return 'system control / fork-bomb sequence';
  }
  // `rm` with recursive+force (any spacing/flag order) or pointed at a system
  // root. `rm -rf file` from within a *working dir* is allowed — only root &
  // force combos are refused here.
  if (RegExp(r'\brm\b').hasMatch(lower) &&
      (RegExp(r'-(\w*r[ro]*\w*f|r[ro]*\w*f|\w*f\w*r[ro]*\w*f)').hasMatch(normalized) ||
       RegExp(r'/(root|home|usr|bin|sbin|etc|var|tmp)\b|\b(/?(\w+)?/)?[/*]$').hasMatch(normalized))) {
    return '`rm` recursive-force onto a system path';
  }
  // Drive/partition wipes and low-level block writes.
  if (RegExp(r'\b(mkfs|fdisk|gdisk|cfdisk|parted|shred|wipefs)\b').hasMatch(lower) ||
      RegExp(r'\bdd\b.+\bof=/dev/').hasMatch(lower) ||
      RegExp(r'\bcat\b.+\b>\s*/dev/').hasMatch(lower)) {
    return 'drive / partition low-level operation';
  }
  // Escape the sandbox via shell-outs inside the agent (defense in depth).
  if (RegExp(r'(\bnsenter\b|\bdocker\s+run\b|\bchroot\b|\bvault\b)').hasMatch(lower)) {
    return 'sandbox escape / container control';
  }
  return null;
}

/// Allow-list + block-list guard. Returns a refusal message, or null if the
/// command may run.
String? _commandGuard(String command) {
  final blocked = _whyBlocked(command);
  if (blocked != null) return blocked;

  final bin = command.trim().split(RegExp(r'\s+')).first
      .split('/').last
      .replaceAll(RegExp(r'^[.,]'), '')
      .split(';')[0];
  if (!_allowedCommands.contains(bin) && !bin.contains('.')) {
    return 'refuses unknown command "$bin" (not in the allow-list).';
  }
  return null;
}

/// A background daemon service that continuously monitors and executes tasks
class TaskDaemon {
  final List<Duration> _intervals = [];
  final StreamController<String> _statusStream = StreamController<String>.broadcast();
  Timer? _timer;
  bool _running = false;

  Stream<String> get statusStream => _statusStream.stream;

  Stream<String> start({
    required String initialPrompt,
    required List<Tool> tools,
    required String model,
    required String apiKey,
    required String providerId,
    String? baseUrl,
    String? system,
    String? workingDir,
    Duration interval = const Duration(seconds: 10),
    int maxIterations = 5,
  }) async* {
    if (_running) {
      throw StateError('Daemon is already running');
    }

    _running = true;
    _intervals.clear();
    _intervals.add(interval);

    _statusStream.add('Daemon started with interval: $interval');
    yield* _executeIteration(
      initialPrompt: initialPrompt,
      tools: tools,
      model: model,
      apiKey: apiKey,
      providerId: providerId,
      baseUrl: baseUrl,
      system: system,
      workingDir: workingDir,
    );

    // Continue with periodic execution
    for (int i = 1; i <= maxIterations; i++) {
      await Future.delayed(interval);
      if (!_running) break;
      
      _statusStream.add('Iteration $i starting...');
      yield* _executeIteration(
        initialPrompt: initialPrompt,
        tools: tools,
        model: model,
        apiKey: apiKey,
        providerId: providerId,
        baseUrl: baseUrl,
        system: system,
        workingDir: workingDir,
      );
      _statusStream.add('Iteration $i completed');
    }

    _statusStream.add('Daemon stopped');
  }

  Stream<String> _executeIteration({
    required String initialPrompt,
    required List<Tool> tools,
    required String model,
    required String apiKey,
    required String providerId,
    String? baseUrl,
    String? system,
    String? workingDir,
  }) async* {
    try {
      final agentService = AgentService();
      final stream = agentService.run(
        initialPrompt: initialPrompt,
        tools: tools,
        model: model,
        apiKey: apiKey,
        providerId: providerId,
        baseUrl: baseUrl,
        system: system,
        workingDir: workingDir,
      );

      await for (final event in stream) {
        if (event is AgentText) {
          yield event.text;
        } else if (event is AgentComplete) {
          yield 'Task completed';
        } else if (event is AgentError) {
          yield 'Error: ${event.message}';
        } else if (event is AgentToolDone) {
          yield 'Tool ${event.toolName} done: ${event.result.substring(0, event.result.length.clamp(0, 100))}';
        } else if (event is AgentToolStart) {
          yield 'Starting tool: ${event.call.name}';
        }
      }
    } catch (e) {
      yield 'Daemon iteration error: $e';
    }
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _statusStream.close();
  }

  bool get isRunning => _running;
}

class SkillDef {
  final List<Tool> tools;
  final String system;

  const SkillDef({required this.tools, required this.system});

  static SkillDef of(TaskSkill skill) => _defs[skill]!;

  static late final _defs = {
    TaskSkill.general: SkillDef(
      tools: AgentService.taskTools,
      system: 'You are an autonomous task-completion agent. '
          'Use tools to complete the task. Be methodical and thorough. '
          'Always read a file with read_file before modifying it. '
          'When editing existing files use str_replace_file. Only use write_file for new files. '
          'For several related edits across files, use multi_edit in a single call. '
          'Use background_start for long-running commands and poll with background_status. '
          'When done, call mark_complete with a summary.',
    ),
    TaskSkill.research: SkillDef(
      tools: AgentService.researchTools,
      system: 'You are a research assistant. '
          'Search the web thoroughly using multiple queries to gather information from diverse sources. '
          'Cross-reference facts, note conflicting information, and synthesize findings into clear, structured output. '
          'Save your research findings to a file if the task requires a written deliverable. '
          'When done, call mark_complete with a brief summary of what you found.',
    ),
    TaskSkill.code: SkillDef(
      tools: AgentService.codeTaskTools,
      system: 'You are an expert software engineer. '
          'Read relevant files before making changes. '
          'Use str_replace_file for targeted edits, write_file only for new files. '
          'For several related edits across files, use multi_edit in a single call. '
          'Use background_start for long-running commands (servers, watchers, builds) and poll with background_status. '
          'Run commands to test your changes where appropriate. '
          'Be precise — make minimal, correct changes. '
          'When done, call mark_complete with a summary of the changes made.',
    ),
    TaskSkill.write: SkillDef(
      tools: AgentService.writeTools,
      system: 'You are a skilled writer and editor. '
          'Read existing content before editing. '
          'Write clearly, concisely, and in the appropriate tone for the context. '
          'Prefer str_replace_file for editing existing documents. '
          'For several related edits across files, use multi_edit in a single call. '
          'When done, call mark_complete with a brief description of what was written or changed.',
    ),
  };
}

class AgentService {
  static final List<Tool> codeTools = [
    Tool(
      name: 'read_file',
      description: 'Read the contents of a file.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'File path (relative to working dir or absolute).'},
        },
        'required': ['path'],
      },
    ),
    Tool(
      name: 'str_replace_file',
      description: 'Edit an existing file by replacing an exact string. '
          'Reads the file first, replaces the first occurrence of old_string with new_string, and saves. '
          'Prefer this over write_file when modifying existing files — it is safer and only changes what you intend.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'File path (relative to working dir or absolute).'},
          'old_string': {'type': 'string', 'description': 'Exact text to find. Must be unique in the file.'},
          'new_string': {'type': 'string', 'description': 'Text to replace it with.'},
        },
        'required': ['path', 'old_string', 'new_string'],
      },
    ),
    Tool(
      name: 'multi_edit',
      description: 'Apply multiple targeted string replacements across one or more files in a single call. '
          'Each edit replaces the first occurrence of old_string with new_string in the given file. '
          'All edits are validated first — if any old_string is not found, no file is changed. '
          'Use this instead of calling str_replace_file repeatedly when you have several related edits.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'edits': {
            'type': 'array',
            'description': 'A list of edits to apply.',
            'items': {
              'type': 'object',
              'properties': {
                'path': {'type': 'string', 'description': 'File path (relative to working dir or absolute).'},
                'old_string': {'type': 'string', 'description': 'Exact text to find. Must be unique in the file.'},
                'new_string': {'type': 'string', 'description': 'Text to replace it with.'},
              },
              'required': ['path', 'old_string', 'new_string'],
            },
          },
        },
        'required': ['edits'],
      },
    ),
    Tool(
      name: 'write_file',
      description: 'Write (or overwrite) a file with given content. '
          'Use only for new files or complete rewrites. '
          'For modifying existing files, use str_replace_file instead.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
        },
        'required': ['path', 'content'],
      },
    ),
    Tool(
      name: 'list_directory',
      description: 'List files and subdirectories at a path.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Directory path. Defaults to working directory.'},
        },
        'required': [],
      },
    ),
    Tool(
      name: 'run_command',
      description: 'Run a shell command in the working directory. Output is returned. Timeout: 30s.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
        },
        'required': ['command'],
      },
    ),
    Tool(
      name: 'search_files',
      description: 'Grep for a pattern across files in a directory.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'pattern': {'type': 'string'},
          'directory': {'type': 'string'},
        },
        'required': ['pattern', 'directory'],
      },
    ),
    Tool(
      name: 'create_directory',
      description: 'Create a directory (and any missing parents).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
    ),
    Tool(
      name: 'background_start',
      description: 'Start a long-running shell command in the background and return immediately. '
          'Use for servers, watchers, builds, or anything that would block. '
          'Returns a job id you can poll with background_status.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string', 'description': 'The shell command to run in the background.'},
        },
        'required': ['command'],
      },
    ),
    Tool(
      name: 'background_status',
      description: 'Check the status and accumulated output of a background job started with background_start.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'The job id returned by background_start.'},
        },
        'required': ['id'],
      },
    ),
    Tool(
      name: 'background_list',
      description: 'List all background jobs and whether each is still running.',
      inputSchema: {
        'type': 'object',
        'properties': {},
        'required': [],
      },
    ),
    Tool(
      name: 'background_kill',
      description: 'Send a kill signal to a running background job.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'The job id to kill.'},
        },
        'required': ['id'],
      },
    ),
    Tool(
      name: 'delegate',
      description: 'Hand off a focused task to a specialised sub-agent and '
          'wait for its result. Use this when a task is better handled by a '
          'dedicated agent (e.g. explore, debug, refactor, test, or a custom '
          'one). The sub-agent runs with its own system prompt, tool set, and '
          'model, then returns a summary you can act on.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'subagent': {
            'type': 'string',
            'description': 'The id or name of the sub-agent to delegate to.',
          },
          'task': {
            'type': 'string',
            'description': 'A clear, self-contained description of the task '
                'for the sub-agent to complete.',
          },
        },
        'required': ['subagent', 'task'],
      },
    ),
    Tool(
      name: 'delegate_parallel',
      description: 'Hand off several independent tasks to sub-agents and run '
          'them concurrently, then return all their summaries. Use this to '
          'parallelise work across multiple specialised agents (e.g. explore '
          'several areas at once). Each entry names a sub-agent and a task.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'delegations': {
            'type': 'array',
            'description': 'A list of sub-agent delegations to run in parallel.',
            'items': {
              'type': 'object',
              'properties': {
                'subagent': {
                  'type': 'string',
                  'description': 'The id or name of the sub-agent.',
                },
                'task': {
                  'type': 'string',
                  'description': 'A clear, self-contained task description.',
                },
              },
              'required': ['subagent', 'task'],
            },
          },
        },
        'required': ['delegations'],
      },
    ),
  ];

  static final _markCompleteTool = Tool(
    name: 'mark_complete',
    description: 'Mark this task as done. Call when the task is fully completed.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': 'Brief summary of what was accomplished.'},
      },
      'required': ['summary'],
    },
  );

  static final _webSearchTool = Tool(
    name: 'web_search',
    description: 'Search the web for information using DuckDuckGo.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'The search query.'},
        'numResults': {
          'type': 'integer',
          'description': 'Number of results to return (default: 5, max: 10)',
          'default': 5,
          'maximum': 10,
        },
      },
      'required': ['query'],
    },
  );

  // General: all tools
  static final List<Tool> taskTools = [...codeTools, _markCompleteTool, _webSearchTool];

  // Code: file/shell tools, no web search
  static final List<Tool> codeTaskTools = [...codeTools, _markCompleteTool];

  // Research: web search + read/write files only
  static final List<Tool> researchTools = [
    codeTools.firstWhere((t) => t.name == 'read_file'),
    codeTools.firstWhere((t) => t.name == 'write_file'),
    _webSearchTool,
    _markCompleteTool,
  ];

  // Write: read/write/edit files only
  static final List<Tool> writeTools = [
    codeTools.firstWhere((t) => t.name == 'read_file'),
    codeTools.firstWhere((t) => t.name == 'write_file'),
    codeTools.firstWhere((t) => t.name == 'str_replace_file'),
    codeTools.firstWhere((t) => t.name == 'multi_edit'),
    codeTools.firstWhere((t) => t.name == 'list_directory'),
    _markCompleteTool,
  ];

  /// Build the tool list for a [SubAgent] from its allowed tool names.
  /// Unknown names are ignored so a stale config never breaks the agent.
  static List<Tool> toolsFor(SubAgent agent) {
    final byName = {for (final t in codeTools) t.name: t};
    return agent.tools
        .map((name) => byName[name])
        .whereType<Tool>()
        .toList();
  }

  Stream<AgentEvent> run({
    required String initialPrompt,
    required List<Tool> tools,
    required String model,
    required String apiKey,
    required String providerId,
    ProviderProtocol? protocol,
    String? baseUrl,
    String? system,
    String? workingDir,
    List<Map<String, dynamic>> history = const [],
    void Function(List<Map<String, dynamic>>)? onMessagesUpdate,
    Future<String> Function(String command)? commandRunner,
    Stream<String> Function(String command)? commandStreamRunner,
    /// If provided, called before each tool executes. Return false to skip
    /// the tool without running it (e.g. user declined approval).
    Future<bool> Function(ToolCall call)? onToolApprove,
    /// If provided, called when the agent invokes the `delegate` tool.
    /// Receives the sub-agent id/name and the task description, and should
    /// run the sub-agent and return its final summary.
    Future<String> Function(String subagent, String task)? delegateRunner,
    /// If provided, called when the agent invokes `delegate_parallel`.
    /// Receives a list of (subagent, task) pairs and should run them
    /// concurrently, returning a combined summary.
    Future<String> Function(List<(String, String)> delegations)?
        parallelDelegateRunner,
    int maxIterations = 20,
  }) async* {
    final llm = AgentLLM();
    // Resolve the wire protocol. When not passed explicitly, infer it from
    // the provider id for backward compatibility so existing callers continue
    // to work unchanged.
    final resolvedProtocol = protocol ?? _protocolForLegacyId(providerId);
    final messages = <Map<String, dynamic>>[
      ...history,
      {'role': 'user', 'content': initialPrompt},
    ];

    for (int i = 0; i < maxIterations; i++) {
      AgentLLMResponse response;
      try {
        response = await llm.call(
          messages: messages,
          tools: tools,
          model: model,
          apiKey: apiKey,
          protocol: resolvedProtocol,
          baseUrl: baseUrl,
          system: system,
        );
      } catch (e) {
        // Persist whatever context we have so the next run doesn't start from
        // stale history. This keeps the conversation coherent across retries.
        onMessagesUpdate?.call(List.unmodifiable(messages));
        yield AgentError('LLM error: $e');
        return;
      }

      if (response.text.isNotEmpty) {
        yield AgentText(response.text);
      }

      if (!response.hasToolCalls) {
        onMessagesUpdate?.call(List.unmodifiable(messages));
        yield const AgentComplete();
        return;
      }

      // Append assistant message with content blocks
      final assistantContent = <Map<String, dynamic>>[];
      if (response.text.isNotEmpty) {
        assistantContent.add({'type': 'text', 'text': response.text});
      }
      for (final tc in response.toolCalls) {
        assistantContent.add({
          'type': 'tool_use',
          'id': tc.id,
          'name': tc.name,
          'input': tc.input,
        });
      }
      messages.add({'role': 'assistant', 'content': assistantContent});

      // Execute tools and collect results
      final toolResults = <Map<String, dynamic>>[];
      for (final tc in response.toolCalls) {
        yield AgentToolStart(tc);

        // Ask for approval first if a hook is registered. Skip if declined.
        if (onToolApprove != null && !await onToolApprove(tc)) {
          final denied = 'User declined to run **${tc.name}**. '
              'Explain what you need and adjust, or stop.';
          yield AgentToolDone(tc.name, denied);
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': tc.id,
            'content': denied,
          });
          continue;
        }

        String result;
        if (tc.name == 'run_command') {
          final cmd = tc.input['command'];
          if (cmd is! String || cmd.isEmpty) {
            result = 'Error: run_command requires a non-empty "command" string.';
          } else {
            final buf = StringBuffer();
            final stream = commandStreamRunner != null
                ? commandStreamRunner(cmd)
                : _runCommandStream(cmd, workingDir);
            await for (final line in stream) {
              buf.writeln(line);
              yield AgentCommandOutput(line);
            }
            result = buf.isEmpty ? '(no output)' : buf.toString().trimRight();
          }
        } else if (tc.name == 'delegate') {
          final subagent = tc.input['subagent'];
          final task = tc.input['task'];
          if (delegateRunner != null &&
              subagent is String && subagent.isNotEmpty &&
              task is String && task.isNotEmpty) {
            result = await delegateRunner(subagent, task);
          } else {
            result = 'Delegation is not available in this context.';
          }
        } else if (tc.name == 'delegate_parallel') {
          result = parallelDelegateRunner != null
              ? await parallelDelegateRunner(_parseDelegations(tc.input))
              : 'Parallel delegation is not available in this context.';
        } else {
          result = await _execute(tc, workingDir: workingDir, commandRunner: commandRunner);
        }
        yield AgentToolDone(tc.name, result);
        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': tc.id,
          'content': result,
        });
      }
      messages.add({'role': 'user', 'content': toolResults});
    }

    onMessagesUpdate?.call(List.unmodifiable(messages));
    yield const AgentError('Max iterations reached.');
  }

  /// Backward-compatible inference of wire protocol from a legacy provider id,
  /// so existing callers that only pass `providerId` keep working. New callers
  /// pass `protocol` explicitly, which takes precedence.
  static ProviderProtocol _protocolForLegacyId(String providerId) =>
      switch (providerId) {
        'gemini' => ProviderProtocol.gemini,
        'claude' => ProviderProtocol.anthropic,
        _ => ProviderProtocol.openai,
      };

  /// Parse the `delegations` list from a `delegate_parallel` tool call.
  /// Defensively skips malformed entries (non-map, missing/empty fields) so a
  /// bad LLM response can never crash the agent loop.
  List<(String, String)> _parseDelegations(Map<String, dynamic> input) {
    final raw = input['delegations'];
    if (raw is! List) return const [];
    final out = <(String, String)>[];
    for (final d in raw) {
      if (d is! Map) continue;
      final subagent = d['subagent'];
      final task = d['task'];
      if (subagent is String && subagent.isNotEmpty &&
          task is String && task.isNotEmpty) {
        out.add((subagent, task));
      }
    }
    return out;
  }

  Future<String> _execute(
    ToolCall tc, {
    String? workingDir,
    Future<String> Function(String)? commandRunner,
  }) async {
    try {
      return switch (tc.name) {
        'read_file' => _readFile(tc.input['path'] as String, workingDir),
        'str_replace_file' => _strReplaceFile(
            tc.input['path'] as String,
            tc.input['old_string'] as String,
            tc.input['new_string'] as String,
            workingDir),
        'multi_edit' => _multiEdit(
            tc.input['edits'] as List, workingDir),
        'write_file' => _writeFile(
            tc.input['path'] as String,
            tc.input['content'] as String,
            workingDir),
        'list_directory' => _listDir(
            tc.input['path'] as String? ?? '',
            workingDir),
        'run_command' => commandRunner != null
            ? commandRunner(tc.input['command'] as String)
            : _runCommand(tc.input['command'] as String, workingDir),
        'search_files' => _searchFiles(
            tc.input['pattern'] as String,
            tc.input['directory'] as String,
            workingDir),
        'create_directory' => _createDir(tc.input['path'] as String, workingDir),
        'background_start' => _backgroundStart(
            tc.input['command'] as String, workingDir),
        'background_status' => _backgroundStatus(tc.input['id'] as String),
        'background_list' => _backgroundList(),
        'background_kill' => _backgroundKill(tc.input['id'] as String),
        'mark_complete' => 'Task marked complete: ${tc.input['summary']}',
        'web_search' => _webSearch(
            tc.input['query'] as String,
            (tc.input['numResults'] as int?) ?? 5),
        'delegate' => 'Delegation is not available in this context.',
        'delegate_parallel' => 'Parallel delegation is not available in this context.',
        _ => 'Unknown tool: ${tc.name}',
      };
    } catch (e) {
      return 'Error: $e';
    }
  }

  String _resolve(String path, String? workingDir) {
    if (path.startsWith('/')) return path;
    if (workingDir != null && workingDir.isNotEmpty) {
      return '$workingDir/$path';
    }
    return path;
  }

  Future<String> _readFile(String path, String? workingDir) async {
    final full = _resolve(path, workingDir);
    final f = File(full);
    if (!await f.exists()) return 'File not found: $full';
    final bytes = await f.readAsBytes();
    if (bytes.length > _maxFileBytes) {
      final text = utf8.decode(bytes.sublist(0, _maxFileBytes), allowMalformed: true);
      return '$text\n\n... (truncated — ${bytes.length - _maxFileBytes} bytes omitted)';
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<String> _strReplaceFile(
      String path, String oldString, String newString, String? workingDir) async {
    final full = _resolve(path, workingDir);
    final f = File(full);
    if (!await f.exists()) return 'File not found: $full';
    final original = await f.readAsString();
    if (!original.contains(oldString)) {
      return 'old_string not found in $full — no changes made.';
    }
    await f.writeAsString(original.replaceFirst(oldString, newString));
    return 'Replaced in $full';
  }

  /// Apply multiple targeted edits across one or more files atomically.
  /// Validates every old_string exists before writing anything, so a bad
  /// edit never leaves the files in a half-applied state.
  Future<String> _multiEdit(List<dynamic> rawEdits, String? workingDir) async {
    if (rawEdits.isEmpty) return 'No edits provided.';

    // Resolve and read all target files first.
    final resolved = <String, String>{}; // full path -> original content
    final plan = <({String full, String oldString, String newString})>[];
    for (final raw in rawEdits) {
      final e = raw as Map<String, dynamic>;
      final full = _resolve(e['path'] as String, workingDir);
      final oldString = e['old_string'] as String;
      final newString = e['new_string'] as String;

      if (!resolved.containsKey(full)) {
        final f = File(full);
        if (!await f.exists()) return 'File not found: $full';
        resolved[full] = await f.readAsString();
      }
      if (!resolved[full]!.contains(oldString)) {
        return 'old_string not found in $full — no changes made.';
      }
      plan.add((full: full, oldString: oldString, newString: newString));
    }

    // Apply all edits in memory, then write each file once.
    final updated = Map<String, String>.from(resolved);
    for (final edit in plan) {
      updated[edit.full] =
          updated[edit.full]!.replaceFirst(edit.oldString, edit.newString);
    }
    for (final entry in updated.entries) {
      await File(entry.key).writeAsString(entry.value);
    }
    return 'Applied ${plan.length} edit(s) across ${updated.length} file(s).';
  }

  Future<String> _writeFile(String path, String content, String? workingDir) async {
    final full = _resolve(path, workingDir);
    final f = File(full);
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return 'Wrote ${content.length} chars to $full';
  }

  Future<String> _listDir(String path, String? workingDir) async {
    final full = path.isEmpty ? (workingDir ?? '.') : _resolve(path, workingDir);
    final dir = Directory(full);
    if (!await dir.exists()) return 'Directory not found: $full';
    final entries = await dir.list().toList();
    entries.sort((a, b) {
      final aIsDir = a is Directory;
      final bIsDir = b is Directory;
      if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
      return a.path.compareTo(b.path);
    });
    return entries.map((e) {
      final name = e.path.split('/').last;
      return e is Directory ? '$name/' : name;
    }).join('\n');
  }

  Future<String> _runCommand(String command, String? workingDir) async {
    if (Platform.isIOS || Platform.isAndroid) {
      return 'Shell execution is not supported on this platform.';
    }
    final guard = _commandGuard(command);
    if (guard != null) {
      return 'Blocked: the requested command $guard';
    }
    final redact = currentSecretValues();
    final result = await Process.run(
      'sh',
      ['-c', command],
      workingDirectory: workingDir,
      // Secret scrubbing: never let an agent-run command read cloud
      // credentials from the environment (same policy as the sandbox).
      environment: sanitizedEnvironment(),
      runInShell: false,
    ).timeout(const Duration(seconds: 30));
    final out = redactSecrets((result.stdout as String).trim(), redact);
    final err = redactSecrets((result.stderr as String).trim(), redact);
    final parts = [if (out.isNotEmpty) out, if (err.isNotEmpty) 'stderr:\n$err'];
    final combined = parts.join('\n');
    if (combined.length > _maxFileBytes) {
      return combined.substring(0, _maxFileBytes) + '\n... (truncated)';
    }
    return combined.isEmpty ? '(no output)' : combined;
  }

  Stream<String> _runCommandStream(String command, String? workingDir) async* {
    if (Platform.isIOS || Platform.isAndroid) {
      yield 'Shell execution is not supported on this platform.';
      return;
    }
    final guard = _commandGuard(command);
    if (guard != null) {
      yield 'Blocked: the requested command $guard';
      return;
    }
    final redact = currentSecretValues();
    final process = await Process.start(
      'sh', ['-c', command],
      workingDirectory: workingDir,
      // Secret scrubbing: same policy as the sandbox.
      environment: sanitizedEnvironment(),
      runInShell: false,
    );

    // Guard against a runaway/hung command — kill it after 30s even if it
    // produced no output, so the agent loop can't block forever.
    final killTimer = Timer(const Duration(seconds: 30), () {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });

    try {
      final ctrl = StreamController<String>();
      int pending = 2;
      void done() { if (--pending == 0) ctrl.close(); }
      process.stdout.transform(utf8.decoder).transform(const LineSplitter())
          .listen((l) => ctrl.add(redactSecrets(l, redact)),
              onDone: done, onError: (_) => done(), cancelOnError: false);
      process.stderr.transform(utf8.decoder).transform(const LineSplitter())
          .map((l) => redactSecrets('stderr: $l', redact))
          .listen(ctrl.add, onDone: done, onError: (_) => done(), cancelOnError: false);
      int totalChars = 0;
      await for (final line in ctrl.stream) {
        totalChars += line.length + 1;
        if (totalChars > _maxFileBytes) {
          yield '... (output truncated)';
          break;
        }
        yield line;
      }
      await process.exitCode;
    } finally {
      killTimer.cancel();
    }
  }

  Future<String> _searchFiles(String pattern, String directory, String? workingDir) async {
    final full = _resolve(directory, workingDir);
    final result = await Process.run(
      'grep',
      ['-r', '-n', '--include=*.*', '-l', pattern, full],
      runInShell: false,
    ).timeout(const Duration(seconds: 15));
    final out = (result.stdout as String).trim();
    return out.isEmpty ? 'No matches found.' : out;
  }

  Future<String> _createDir(String path, String? workingDir) async {
    final full = _resolve(path, workingDir);
    await Directory(full).create(recursive: true);
    return 'Created directory: $full';
  }

  Future<String> _backgroundStart(String command, String? workingDir) async {
    try {
      final id = await BackgroundProcessManager.instance
          .start(command, workingDir: workingDir);
      return 'Started background job $id: $command\n'
          'Poll with background_status(id: "$id") to check progress.';
    } catch (e) {
      return 'Error starting background job: $e';
    }
  }

  Future<String> _backgroundStatus(String id) async =>
      BackgroundProcessManager.instance.status(id);

  Future<String> _backgroundList() async =>
      BackgroundProcessManager.instance.list();

  Future<String> _backgroundKill(String id) async =>
      BackgroundProcessManager.instance.kill(id);

  /// Web search using DuckDuckGo Instant Answer API
  /// Returns structured results including instant answers and related topics
  Future<String> _webSearch(String query, int numResults) async {
    // Sanitize numResults to ensure it's reasonable
    final normalizedNumResults = numResults.clamp(1, 10);
    
    try {
      // URL-encode the query
      final encodedQuery = Uri.encodeComponent(query);
      
      // Use DuckDuckGo's Instant Answer API (CORS-friendly, returns JSON)
      final url = Uri.parse('https://api.duckduckgo.com/?q=$encodedQuery&format=json&pretty=1');
      
      // Make the request with a timeout
      final response = await http.get(
        url,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        final formattedResults = StringBuffer();
        
        // Get the main abstract/answer
        final abstractTitle = data['Abstract'] as String?;
        final abstractText = data['AbstractText'] as String?;
        final imageUrl = data['Image'] as String?;
        
        if (abstractTitle != null) {
          formattedResults.writeln('=== ${abstractTitle} ===');
          formattedResults.writeln(abstractText ?? '');
          if (imageUrl != null) {
            formattedResults.writeln('![Image]($imageUrl)');
          }
          formattedResults.writeln();
        } else if (abstractText != null) {
          formattedResults.writeln('Answer: $abstractText');
          formattedResults.writeln();
        }
        
        // Get related topics
        final relatedTopics = data['RelatedTopics'] as List<dynamic>? ?? [];
        
        if (relatedTopics.isNotEmpty && normalizedNumResults > 0) {
          formattedResults.writeln('=== Related Topics ===');
          int count = 0;
          for (final topic in relatedTopics) {
            final text = topic['Text'] as String?;
            
            if (text != null) {
              count++;
              formattedResults.writeln('${count}. $text');
              
              // Try to get the URL from Icon data
              final dataObj = topic['Data'] as List? ?? [];
              if (dataObj.isNotEmpty) {
                final firstData = dataObj[0];
                if (firstData is Map) {
                  final iconData = firstData['Icon'] as Map? ?? {};
                  final link = iconData['32'] ?? iconData['60'] ?? iconData['100'];
                  if (link != null && link is String) {
                    formattedResults.writeln('   → $link');
                  }
                }
              }
            }
            
            if (count >= normalizedNumResults) break;
          }
        } else if (abstractTitle == null) {
          formattedResults.writeln('No instant answer found for this query.');
        } else {
          formattedResults.writeln('No related topics found.');
        }
        
        return formattedResults.toString().trim();
      } else {
        return 'Web search failed with status: ${response.statusCode}';
      }
    } on TimeoutException {
      return 'Web search timed out.';
    } on http.ClientException catch (e) {
      return 'Web search network error: $e';
    } on FormatException {
      return 'Web search returned unexpected format.';
    } on StateError catch (e) {
      return 'Web search data error: $e';
    } catch (e) {
      return 'Web search error: $e';
    }
  }
}

// Standalone helper used by email screen for AI summarize/draft (streaming)
Future<String> fetchEmailAI({
  required String prompt,
  required AppConfig config,
  required LLMProvider provider,
  String? model,
}) async {
  return provider.complete(
    config: config,
    prompt: prompt,
    maxTokens: 2048,
    model: model,
  );
}
