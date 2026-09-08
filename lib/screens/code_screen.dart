import 'dart:async';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import '../models/command.dart';
import '../models/config.dart';
import '../models/subagent.dart';
import '../models/tool.dart';
import '../services/agent_service.dart';
import '../state/code.dart';
import '../state/providers.dart';
import '../widgets/ai_input_field.dart';
import '../widgets/command_palette.dart';
import '../widgets/file_tree.dart';
import '../widgets/provider_badge.dart';

class CodeScreen extends ConsumerStatefulWidget {
  const CodeScreen({super.key});

  @override
  ConsumerState<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends ConsumerState<CodeScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  double _sidebarWidth = 220;
  StreamSubscription<AgentEvent>? _agentSub;
  bool _inStreamingCommand = false;

  @override
  void initState() {
    super.initState();
    _registerCommands();
  }

  void _registerCommands() {
    final reg = CommandRegistry.instance;
    reg.register(Command(
      id: 'new_session',
      title: 'New code session',
      icon: Icons.add,
      shortcut: 'cmd+n',
      run: () => ref.read(codeProvider.notifier).newSession(),
    ));
    reg.register(Command(
      id: 'run_agent',
      title: 'Run agent',
      icon: Icons.play_arrow,
      shortcut: 'cmd+enter',
      run: () {
        if (!ref.read(codeProvider).isRunning) _send();
      },
    ));
    reg.register(Command(
      id: 'open_folder',
      title: 'Open folder',
      icon: Icons.folder_open_outlined,
      shortcut: 'cmd+o',
      run: _showFolderMenu,
    ));
    reg.register(Command(
      id: 'clear_conversation',
      title: 'Clear conversation',
      icon: Icons.delete_outline,
      shortcut: 'cmd+shift+backspace',
      run: () => ref.read(codeProvider.notifier).clearConversation(),
    ));
    reg.register(Command(
      id: 'compact_context',
      title: 'Compact context',
      icon: Icons.compress,
      subtitle: 'Trim the conversation to the most recent messages',
      run: () => ref.read(codeProvider.notifier).compactHistory(),
    ));
    reg.register(Command(
      id: 'new_workspace',
      title: 'New code tab',
      icon: Icons.add_box_outlined,
      subtitle: 'Open a fresh, independent code workspace',
      run: () => ref.read(codeProvider.notifier).newWorkspace(),
    ));
  }

  @override
  void dispose() {
    _agentSub?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _stop() {
    _agentSub?.cancel();
    _agentSub = null;
    _inStreamingCommand = false;
    ref.read(codeProvider.notifier).setRunning(false);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Open folder',
    );
    if (path != null && mounted) {
      await ref.read(codeProvider.notifier).setWorkingDir(path);
    }
  }

  /// Show a menu of quick ways to open a folder: recent folders, paste a
  /// path, or browse with the native picker.
  void _showFolderMenu() {
    final recent = ref.read(codeProvider).recentFolders;
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _FolderMenuSheet(
        recentFolders: recent,
        onBrowse: () {
          Navigator.pop(ctx);
          _pickFolder();
        },
        onOpenPath: (path) async {
          Navigator.pop(ctx);
          final resolved =
              await ref.read(codeProvider.notifier).setWorkingDirFromPath(path);
          if (resolved == null) {
            _showSnack('Could not open folder: "$path"');
          }
        },
        onRemoveRecent: (dir) =>
            ref.read(codeProvider.notifier).removeRecentFolder(dir),
      ),
    );
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || ref.read(codeProvider).isRunning) return;
    _inputCtrl.clear();

    final config = ref.read(configProvider);
    if (config.active.apiKey.isEmpty && config.activeProviderId != 'ollama') {
      _showSnack('Set a Claude API key in Settings first.');
      return;
    }

    // Switch to agent tab so the user sees the response
    ref.read(codeProvider.notifier).showAgentTab();

    final notifier = ref.read(codeProvider.notifier);
    final workingDir = ref.read(codeProvider).workingDir;
    final mode = ref.read(codeProvider).mode;
    final subAgentId = ref.read(codeProvider).subAgentId;
    notifier.addEntry(CodeEntry.user(text));
    notifier.setRunning(true);
    _scrollToBottom();

    // If a subagent is active, use its system prompt and tool set.
    final SubAgent? subAgent =
        subAgentId == null ? null : config.subAgentById(subAgentId);
    final system = subAgent != null
        ? _subAgentSystemPrompt(workingDir, subAgent)
        : _systemPrompt(workingDir, mode);

    // Restrict tools based on mode (or the subagent's tool set).
    final tools =
        subAgent != null ? AgentService.toolsFor(subAgent) : _toolsFor(mode);

    final history = ref.read(codeProvider).history;
    final service = AgentService();
    _inStreamingCommand = false;

    _agentSub = service
        .run(
      initialPrompt: text,
      tools: tools,
      model: config.modelFor(Feature.code),
      apiKey: config.active.apiKey,
      providerId: config.activeProviderId,
      protocol: config.active.protocol,
      baseUrl: config.active.baseUrl,
      system: system,
      workingDir: workingDir.isNotEmpty ? workingDir : null,
      history: history,
      maxIterations: config.agentMaxIterations,
      onMessagesUpdate: (msgs) =>
          ref.read(codeProvider.notifier).updateHistory(msgs),
      commandRunner: ref.read(codeProvider.notifier).commandRunner,
      commandStreamRunner: ref.read(codeProvider.notifier).commandStreamRunner,
      onToolApprove: mode.requiresApproval ? _approveTool : null,
      delegateRunner: (subagentRef, task) =>
          _runDelegated(subagentRef, task, config, workingDir),
      parallelDelegateRunner: (delegations) =>
          _runDelegatedParallel(delegations, config, workingDir),
    )
        .listen(
      (event) {
        switch (event) {
          case AgentText(:final text):
            if (text.isNotEmpty) notifier.addEntry(CodeEntry.assistant(text));
          case AgentToolStart(:final call):
            notifier.addEntry(
                CodeEntry.toolCall(call.name, _summarise(call.input)));
            _inStreamingCommand = call.name == 'run_command';
          case AgentCommandOutput(:final line):
            notifier.appendCommandOutput(line);
          case AgentToolDone(:final toolName, :final result):
            if (_inStreamingCommand) {
              notifier.finalizeCommandOutput(toolName, result);
              _inStreamingCommand = false;
            } else {
              notifier.addEntry(CodeEntry.toolResult(toolName, result));
            }
          case AgentComplete():
            break;
          case AgentError(:final message):
            notifier.addEntry(CodeEntry.error(message));
        }
        _scrollToBottom();
      },
      onDone: () {
        _agentSub = null;
        notifier.setRunning(false);
        _scrollToBottom();
      },
      onError: (e) {
        _agentSub = null;
        notifier.addEntry(CodeEntry.error('$e'));
        notifier.setRunning(false);
        _scrollToBottom();
      },
    );
  }

  String _systemPrompt(String workingDir, CodeMode mode) {
    final modeClause = switch (mode) {
      CodeMode.yolo =>
        'Fully autonomous mode: carry out the request end-to-end '
            'without asking the user. Use tools as needed.',
      CodeMode.ask =>
        'Every tool call must be approved by the user. The UI will '
            'pause and ask before running each tool — you do NOT need to ask in '
            'text. Just propose the next tool and the system will confirm.',
      CodeMode.plan => 'Work in a plan-first way. Present a clear, numbered plan '
          'before executing. The UI will pause for approval before each tool, so '
          'do not ask in text — just propose the next step and the system will '
          'confirm. Do one step at a time.',
      CodeMode.edit => 'File editing mode only. You may read, search, and edit '
          'files, but you cannot run shell commands or access the web.',
    };

    final base = workingDir.isNotEmpty
        ? 'You are an expert coding assistant with access to file system and shell tools.\n'
            'Working directory: $workingDir\n'
            'Be concise. Always read a file with read_file before modifying it. '
            'When editing existing files use str_replace_file — it is safer and only changes what you intend. '
            'Only use write_file to create brand-new files. '
            'For several related edits across files, use multi_edit in a single call. '
            'Use background_start for long-running commands (servers, watchers, builds) and poll with background_status.'
        : 'You are an expert coding assistant. Be concise and think step-by-step. '
            'When editing existing files use str_replace_file. Only use write_file for new files. '
            'For several related edits across files, use multi_edit in a single call.';

    return '$base\n$modeClause';
  }

  String _subAgentSystemPrompt(String workingDir, SubAgent agent) {
    final base = workingDir.isNotEmpty
        ? 'You are an expert coding assistant with access to file system and shell tools.\n'
            'Working directory: $workingDir\n'
            'Be concise. Always read a file with read_file before modifying it. '
            'When editing existing files use str_replace_file — it is safer and only changes what you intend. '
            'Only use write_file to create brand-new files. '
            'For several related edits across files, use multi_edit in a single call. '
            'Use background_start for long-running commands (servers, watchers, builds) and poll with background_status.'
        : 'You are an expert coding assistant. Be concise and think step-by-step. '
            'When editing existing files use str_replace_file. Only use write_file for new files. '
            'For several related edits across files, use multi_edit in a single call.';
    return '$base\n${agent.systemPrompt}';
  }

  /// Run a sub-agent to completion and return its final summary. Used by the
  /// main agent's `delegate` tool. The sub-agent uses its own model, system
  /// prompt, and tool set, and streams its progress into the conversation.
  Future<String> _runDelegated(
    String subagentRef,
    String task,
    AppConfig config,
    String workingDir,
  ) async {
    // Resolve the sub-agent by id or name.
    SubAgent? agent;
    for (final a in config.subAgents) {
      if (a.id == subagentRef ||
          a.name.toLowerCase() == subagentRef.toLowerCase()) {
        agent = a;
        break;
      }
    }
    if (agent == null) {
      return 'Unknown sub-agent: "$subagentRef". Available: '
          '${config.subAgents.map((a) => a.name).join(', ')}.';
    }

    final notifier = ref.read(codeProvider.notifier);
    notifier.addEntry(CodeEntry.toolCall('delegate', '${agent.name} ← $task'));

    final service = AgentService();
    final system = _subAgentSystemPrompt(workingDir, agent);
    final tools = AgentService.toolsFor(agent);
    final model = config.modelForSubAgent(agent);

    final summary = StringBuffer();
    var runningText = '';
    var toolEntryActive = false;

    void flushText() {
      if (runningText.trim().isNotEmpty) {
        notifier.addEntry(CodeEntry.assistant(runningText.trim()));
        runningText = '';
      }
    }

    await for (final event in service.run(
      initialPrompt: task,
      tools: tools,
      model: model,
      apiKey: config.active.apiKey,
      providerId: config.activeProviderId,
      protocol: config.active.protocol,
      baseUrl: config.active.baseUrl,
      system: system,
      workingDir: workingDir.isNotEmpty ? workingDir : null,
      maxIterations: config.agentMaxIterations,
      commandRunner: notifier.commandRunner,
      commandStreamRunner: notifier.commandStreamRunner,
    )) {
      switch (event) {
        case AgentText(:final text):
          if (text.isNotEmpty) {
            runningText += text + '\n';
            summary.writeln(text);
          }
        case AgentToolStart(:final call):
          flushText();
          if (!toolEntryActive) {
            notifier.addEntry(CodeEntry.toolCall(
                'delegate', '${agent.name} running ${call.name}'));
            toolEntryActive = true;
          }
        case AgentCommandOutput():
          break;
        case AgentToolDone(:final toolName, :final result):
          flushText();
          if (toolName == 'mark_complete') {
            summary.writeln(result);
          }
        case AgentComplete():
          break;
        case AgentError(:final message):
          flushText();
          summary.writeln('Error: $message');
      }
    }
    flushText();

    final result = summary.toString().trim();
    notifier.addEntry(CodeEntry.toolResult(
        'delegate', result.isEmpty ? '(no output)' : result));
    return result.isEmpty ? '(no output)' : result;
  }

  /// Run several sub-agents concurrently and combine their summaries.
  Future<String> _runDelegatedParallel(
    List<(String, String)> delegations,
    AppConfig config,
    String workingDir,
  ) async {
    if (delegations.isEmpty) return 'No delegations provided.';

    final notifier = ref.read(codeProvider.notifier);
    notifier.addEntry(CodeEntry.toolCall(
        'delegate_parallel', '${delegations.length} sub-agents in parallel'));

    // Run all delegations concurrently.
    final futures = delegations.map((d) async {
      final (subagentRef, task) = d;
      return _runDelegated(subagentRef, task, config, workingDir);
    }).toList();

    final results = await Future.wait(futures);

    final buf = StringBuffer();
    for (var i = 0; i < delegations.length; i++) {
      buf.writeln('### ${delegations[i].$1}');
      buf.writeln(results[i]);
      buf.writeln();
    }
    final combined = buf.toString().trim();
    notifier.addEntry(CodeEntry.toolResult(
        'delegate_parallel', combined.isEmpty ? '(no output)' : combined));
    return combined.isEmpty ? '(no output)' : combined;
  }

  List<Tool> _toolsFor(CodeMode mode) {
    if (!mode.editOnly) return AgentService.codeTools;
    const allowed = {
      'read_file',
      'str_replace_file',
      'multi_edit',
      'write_file',
      'list_directory',
      'search_files',
      'create_directory',
    };
    return AgentService.codeTools
        .where((t) => allowed.contains(t.name))
        .toList();
  }

  static const _shellTools = {
    'run_command',
    'background_start',
    'background_status',
    'background_list',
    'background_kill',
  };

  Future<bool> _approveTool(ToolCall call) async {
    if (!mounted) return false;
    final mode = ref.read(codeProvider).mode;

    // In plan mode, only require confirmation for state-changing / shell tools.
    // Read-only tools are harmless and run automatically to keep the plan flowing.
    if (mode == CodeMode.plan && !_isStateChanging(call)) return true;

    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ApproveToolDialog(call: call, mode: mode),
    );
    return approved ?? false;
  }

  static bool _isStateChanging(ToolCall call) {
    if (_shellTools.contains(call.name)) return true;
    return switch (call.name) {
      'str_replace_file' ||
      'multi_edit' ||
      'write_file' ||
      'create_directory' =>
        true,
      _ => false,
    };
  }

  String _summarise(Map<String, dynamic> input) {
    if (input.containsKey('path')) return '"${input['path']}"';
    if (input.containsKey('command')) return '"${input['command']}"';
    if (input.containsKey('pattern'))
      return '"${input['pattern']}" in ${input['directory'] ?? '.'}';
    if (input.containsKey('edits')) {
      final edits = input['edits'] as List;
      return '${edits.length} edit(s) across ${edits.map((e) => (e as Map)['path']).toSet().length} file(s)';
    }
    if (input.containsKey('id')) return 'job "${input['id']}"';
    return input.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final codeState = ref.watch(codeProvider);
    final config = ref.watch(configProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Code'),
        actions: [
          _SubAgentMenu(state: codeState, subAgents: config.subAgents),
          _ModeMenu(state: codeState),
          if (codeState.workingDir.isNotEmpty) _SessionMenu(state: codeState),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ProviderBadge(
              providerId: config.activeProviderId,
              modelId: config.modelFor(Feature.code),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Clear conversation',
            onPressed: () =>
                ref.read(codeProvider.notifier).clearConversation(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Sandbox status strip
          _SandboxBar(state: codeState),
          // Main split area
          Expanded(
            child: Row(
              children: [
                // ── Left: file explorer ───────────────────────────────────
                SizedBox(
                  width: _sidebarWidth,
                  child: _FilePanel(
                    workingDir: codeState.workingDir,
                    selectedPath: codeState.activeFileIndex != null
                        ? codeState.openFiles[codeState.activeFileIndex!].path
                        : null,
                    onPickFolder: _showFolderMenu,
                    onFileTap: (path) =>
                        ref.read(codeProvider.notifier).openFile(path),
                  ),
                ),
                // ── Draggable divider ─────────────────────────────────────
                MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) => setState(() {
                      _sidebarWidth =
                          (_sidebarWidth + d.delta.dx).clamp(120.0, 480.0);
                    }),
                    child: Container(
                      width: 4,
                      color: cs.surfaceContainerHigh,
                    ),
                  ),
                ),
                // ── Right: tab bar + content ──────────────────────────────
                Expanded(
                  child: Column(
                    children: [
                      _WorkspaceBar(state: codeState),
                      _TabBar(state: codeState),
                      Expanded(
                        child: codeState.activeFileIndex == null
                            ? _AgentPanel(
                                entries: codeState.entries,
                                scrollCtrl: _scrollCtrl,
                                workingDir: codeState.workingDir,
                              )
                            : _FileViewerPanel(
                                file: codeState
                                    .openFiles[codeState.activeFileIndex!],
                              ),
                      ),
                      // Input always visible; always targets agent
                      _InputBar(
                        ctrl: _inputCtrl,
                        running: codeState.isRunning,
                        onSend: _send,
                        onStop: _stop,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Session history menu ─────────────────────────────────────────────────────

class _SessionMenu extends ConsumerWidget {
  final CodeState state;
  const _SessionMenu({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(codeProvider.notifier);

    return PopupMenuButton<String>(
      tooltip: 'Session history',
      icon: Icon(Icons.history, size: 20, color: cs.onSurface.withValues(alpha: 0.7)),
      onSelected: (value) {
        switch (value) {
          case '__new__':
            notifier.newSession();
          case '__clear__':
            notifier.clearConversation();
          default:
            notifier.switchSession(value);
        }
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem(
          value: '__new__',
          child: Row(
            children: [
              Icon(Icons.add, size: 18),
              SizedBox(width: 8),
              Text('New session'),
            ],
          ),
        ),
        if (state.sessions.isNotEmpty) const PopupMenuDivider(),
        ...state.sessions.map((s) {
          final isActive = s.id == state.activeSessionId;
          return PopupMenuItem(
            value: s.id,
            child: Row(
              children: [
                Icon(
                  isActive
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 16,
                  color: isActive ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                if (isActive)
                  Text(' · ${s.entries.length}',
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurface.withValues(alpha: 0.4))),
              ],
            ),
          );
        }),
        if (state.sessions.isNotEmpty) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: '__clear__',
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 18, color: cs.error),
                const SizedBox(width: 8),
                Text('Clear current', style: TextStyle(color: cs.error)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ── Sub-agent menu ───────────────────────────────────────────────────────────

class _SubAgentMenu extends ConsumerWidget {
  final CodeState state;
  final List<SubAgent> subAgents;
  const _SubAgentMenu({required this.state, required this.subAgents});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final activeId = state.subAgentId;
    final active = activeId == null
        ? null
        : subAgents.where((a) => a.id == activeId).firstOrNull;

    return PopupMenuButton<String?>(
      tooltip: 'Sub-agent',
      onSelected: (id) => ref.read(codeProvider.notifier).setSubAgent(id),
      itemBuilder: (ctx) => [
        PopupMenuItem<String?>(
          value: null,
          child: Row(
            children: [
              Icon(Icons.smart_toy_outlined,
                  size: 18,
                  color: activeId == null
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: 0.6)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Full agent',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: activeId == null
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: activeId == null ? cs.primary : cs.onSurface,
                        )),
                    const SizedBox(height: 1),
                    Text('All tools — files, shell, and web.',
                        style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: 0.5))),
                  ],
                ),
              ),
              if (activeId == null)
                Icon(Icons.check, size: 15, color: cs.primary),
            ],
          ),
        ),
        if (subAgents.isNotEmpty) const PopupMenuDivider(),
        for (final a in subAgents)
          PopupMenuItem<String?>(
            value: a.id,
            child: Row(
              children: [
                Icon(a.iconData,
                    size: 18,
                    color: a.id == activeId
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.6)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: a.id == activeId
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: a.id == activeId ? cs.primary : cs.onSurface,
                          )),
                      const SizedBox(height: 1),
                      Text(a.description,
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurface.withValues(alpha: 0.5)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                if (a.id == activeId)
                  Icon(Icons.check, size: 15, color: cs.primary),
              ],
            ),
          ),
      ],
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active != null
              ? active.icon == SubAgentIcons.explore
                  ? Colors.teal.withValues(alpha: 0.12)
                  : cs.primary.withValues(alpha: 0.12)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active?.iconData ?? Icons.smart_toy_outlined,
                size: 13,
                color: active != null
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.6)),
            const SizedBox(width: 5),
            Text(
              active?.name ?? 'Agent',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color:
                    active != null ? cs.primary : cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down,
                size: 14,
                color: (active != null
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.6))
                    .withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}

// ── Mode menu ────────────────────────────────────────────────────────────────

class _ModeMenu extends ConsumerWidget {
  final CodeState state;
  const _ModeMenu({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final mode = state.mode;

    return PopupMenuButton<CodeMode>(
      tooltip: 'Agent mode',
      onSelected: (m) => ref.read(codeProvider.notifier).setMode(m),
      itemBuilder: (ctx) => [
        for (final m in CodeMode.values)
          PopupMenuItem<CodeMode>(
            value: m,
            child: Row(
              children: [
                Icon(m.icon,
                    size: 18,
                    color:
                        m == mode ? cs.primary : cs.onSurface.withValues(alpha: 0.6)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                m == mode ? FontWeight.w700 : FontWeight.w500,
                            color: m == mode ? cs.primary : cs.onSurface,
                          )),
                      const SizedBox(height: 1),
                      Text(m.description,
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurface.withValues(alpha: 0.5))),
                    ],
                  ),
                ),
                if (m == mode) Icon(Icons.check, size: 15, color: cs.primary),
              ],
            ),
          ),
      ],
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: mode == CodeMode.ask || mode == CodeMode.plan
              ? Colors.amber.withValues(alpha: 0.12)
              : mode == CodeMode.edit
                  ? cs.primary.withValues(alpha: 0.12)
                  : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(mode.icon,
                size: 13,
                color: mode == CodeMode.ask || mode == CodeMode.plan
                    ? Colors.amber.shade400
                    : cs.primary),
            const SizedBox(width: 5),
            Text(
              mode.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: mode == CodeMode.ask || mode == CodeMode.plan
                    ? Colors.amber.shade400
                    : cs.primary,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down,
                size: 14,
                color: (mode == CodeMode.ask || mode == CodeMode.plan
                        ? Colors.amber.shade400
                        : cs.primary)
                    .withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}

// ── Tool approval dialog ─────────────────────────────────────────────────────

class _ApproveToolDialog extends StatelessWidget {
  final ToolCall call;
  final CodeMode mode;
  const _ApproveToolDialog({required this.call, required this.mode});

  String get _title => 'Approve ${call.name}?';
  String get _command => call.input['command'] as String? ?? '';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: Colors.grey.shade900.withValues(alpha: 0.98),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Row(
        children: [
          const Icon(Icons.help_outline, color: Color(0xFF3B82F6), size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The agent wants to run the **${call.name}** tool. Review the '
            'arguments before allowing it.',
            style:
                TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.8)),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _command.isNotEmpty ? _command : _prettifyInput(call.input),
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: Color(0xFF98C379)),
            ),
          ),
          if (mode == CodeMode.plan) ...[
            const SizedBox(height: 10),
            Text(
              'Plan mode: read-only tools run automatically; state-changing '
              'and shell tools require approval.',
              style:
                  TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.5)),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Decline', style: TextStyle(color: cs.error)),
        ),
        const Spacer(),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: cs.primary,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Allow'),
        ),
      ],
    );
  }

  String _prettifyInput(Map<String, dynamic> input) {
    if (input.containsKey('old_string') || input.containsKey('new_string')) {
      final path = input['path'];
      final oldLen = (input['old_string'] as String?)?.length ?? 0;
      final newLen = (input['new_string'] as String?)?.length ?? 0;
      return '$path  ·  $oldLen → $newLen chars';
    }
    if (input.containsKey('edits')) {
      final edits = input['edits'] as List;
      return '${edits.length} edit(s) across '
          '${edits.map((e) => (e as Map)['path']).toSet().length} file(s)';
    }
    return input.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  }
}

// ── File explorer panel ───────────────────────────────────────────────────────

class _FilePanel extends StatelessWidget {
  final String workingDir;
  final String? selectedPath;
  final VoidCallback onPickFolder;
  final void Function(String) onFileTap;

  const _FilePanel({
    required this.workingDir,
    required this.onPickFolder,
    required this.onFileTap,
    this.selectedPath,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final folderName =
        workingDir.isEmpty ? 'No folder' : workingDir.split('/').last;

    return Container(
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: folder name + open button
          InkWell(
            onTap: onPickFolder,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined,
                      size: 14, color: cs.primary.withValues(alpha: 0.7)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      folderName.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface.withValues(alpha: 0.55),
                        letterSpacing: 0.8,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'Open folder',
                    child: Icon(Icons.drive_folder_upload_outlined,
                        size: 16, color: cs.onSurface.withValues(alpha: 0.4)),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // Tree
          Expanded(
            child: FileTree(
              workingDir: workingDir,
              selectedPath: selectedPath,
              onFileTap: onFileTap,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Folder open menu ─────────────────────────────────────────────────────────

class _FolderMenuSheet extends StatefulWidget {
  final List<String> recentFolders;
  final VoidCallback onBrowse;
  final Future<void> Function(String path) onOpenPath;
  final void Function(String dir) onRemoveRecent;

  const _FolderMenuSheet({
    required this.recentFolders,
    required this.onBrowse,
    required this.onOpenPath,
    required this.onRemoveRecent,
  });

  @override
  State<_FolderMenuSheet> createState() => _FolderMenuSheetState();
}

class _FolderMenuSheetState extends State<_FolderMenuSheet> {
  final _pathCtrl = TextEditingController();

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Open folder',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          // Paste a path
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Paste a path, e.g. ~/projects/app',
                    prefixIcon: Icon(Icons.link, size: 18),
                  ),
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) widget.onOpenPath(v.trim());
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final v = _pathCtrl.text.trim();
                  if (v.isNotEmpty) widget.onOpenPath(v);
                },
                style: FilledButton.styleFrom(backgroundColor: cs.primary),
                child: const Text('Open'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Supports ~, relative paths, and absolute paths.',
            style:
                TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 16),
          // Browse
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_open_outlined, color: cs.primary),
            title: const Text('Browse…', style: TextStyle(fontSize: 14)),
            subtitle: Text('Use the native folder picker',
                style: TextStyle(
                    fontSize: 11, color: cs.onSurface.withValues(alpha: 0.5))),
            onTap: widget.onBrowse,
          ),
          if (widget.recentFolders.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Text('Recent',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: cs.onSurface.withValues(alpha: 0.45))),
            const SizedBox(height: 4),
            ...widget.recentFolders.map((dir) {
              final name = dir.split('/').last;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(Icons.folder_outlined,
                    size: 18, color: cs.primary.withValues(alpha: 0.7)),
                title: Text(name,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(dir,
                    style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: cs.onSurface.withValues(alpha: 0.4)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: Icon(Icons.close,
                      size: 14, color: cs.onSurface.withValues(alpha: 0.35)),
                  tooltip: 'Remove from recent',
                  onPressed: () => widget.onRemoveRecent(dir),
                ),
                onTap: () => widget.onOpenPath(dir),
              );
            }),
          ],
        ],
      ),
    );
  }
}

// ── Workspace bar (tabbed code) ─────────────────────────────────────────────

class _WorkspaceBar extends ConsumerWidget {
  final CodeState state;
  const _WorkspaceBar({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(codeProvider.notifier);
    final workspaces = state.workspaces;

    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.surfaceContainerHigh)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          // Workspace tabs. If none exist yet, show a single tab for the
          // current (unsaved) view so the bar is never empty.
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: workspaces.isEmpty
                  ? [
                      _WorkspaceTab(
                        title: 'Code 1',
                        isActive: true,
                        onTap: () {},
                        onClose: () {},
                      ),
                    ]
                  : [
                      for (final ws in workspaces)
                        _WorkspaceTab(
                          title: ws.title,
                          isActive: ws.id == state.activeWorkspaceId,
                          onTap: () => notifier.switchWorkspace(ws.id),
                          onClose: () => notifier.closeWorkspace(ws.id),
                        ),
                    ],
            ),
          ),
          // New workspace button
          IconButton(
            icon: Icon(Icons.add, size: 16, color: cs.primary),
            tooltip: 'New code tab',
            onPressed: notifier.newWorkspace,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _WorkspaceTab extends StatelessWidget {
  final String title;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _WorkspaceTab({
    required this.title,
    required this.isActive,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 160),
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive ? cs.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.code,
                size: 12,
                color: isActive ? cs.primary : cs.onSurface.withValues(alpha: 0.45)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  color:
                      isActive ? cs.onSurface : cs.onSurface.withValues(alpha: 0.5),
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onClose,
              child: Icon(Icons.close,
                  size: 12, color: cs.onSurface.withValues(alpha: 0.4)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tab bar ───────────────────────────────────────────────────────────────────

class _TabBar extends ConsumerWidget {
  final CodeState state;
  const _TabBar({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(codeProvider.notifier);
    final isAgentActive = state.activeFileIndex == null;

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.surfaceContainerHigh)),
      ),
      child: Row(
        children: [
          // Agent tab (always first)
          _Tab(
            label: 'Agent',
            icon: Icons.smart_toy_outlined,
            isActive: isAgentActive,
            onTap: notifier.showAgentTab,
          ),
          // File tabs
          ...state.openFiles.asMap().entries.map((e) {
            final isActive = state.activeFileIndex == e.key;
            return _Tab(
              label: e.value.name,
              icon: Icons.insert_drive_file_outlined,
              isActive: isActive,
              onTap: () => notifier.showFileTab(e.key),
              onClose: () => notifier.closeFile(e.key),
            );
          }),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  const _Tab({
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onTap,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive ? cs.surface : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: isActive ? cs.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 12,
                color: isActive ? cs.primary : cs.onSurface.withValues(alpha: 0.45)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color:
                      isActive ? cs.onSurface : cs.onSurface.withValues(alpha: 0.5),
                  fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onClose != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onClose,
                child: Icon(Icons.close,
                    size: 12, color: cs.onSurface.withValues(alpha: 0.4)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Sandbox status strip ──────────────────────────────────────────────────────

class _SandboxBar extends ConsumerWidget {
  final CodeState state;
  const _SandboxBar({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    if (state.sandboxType == null) return const SizedBox.shrink();

    final isDocker = state.sandboxType == SandboxType.docker;
    final (icon, label, color) = switch (state.containerStatus) {
      ContainerStatus.idle => (
          Icons.circle_outlined,
          isDocker
              ? 'Docker ready — set a folder to start container'
              : 'Restricted mode',
          cs.onSurface.withValues(alpha: 0.3)
        ),
      ContainerStatus.starting => (
          Icons.hourglass_empty,
          'Starting container…',
          Colors.amber.shade400
        ),
      ContainerStatus.running => isDocker
          ? (
              Icons.circle,
              '🐳  ${state.sandboxImage}  ·  isolated',
              Colors.green.shade400
            )
          : (
              Icons.shield_outlined,
              'Restricted sandbox  ·  sanitized env',
              Colors.green.shade400
            ),
      ContainerStatus.error => (
          Icons.warning_amber_outlined,
          'Sandbox error',
          cs.error
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: cs.surfaceContainer,
      child: Row(
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              state.sandboxError != null
                  ? 'Error: ${state.sandboxError}'
                  : label,
              style: TextStyle(
                fontSize: 11,
                color: state.sandboxError != null ? cs.error : color,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (state.containerStatus == ContainerStatus.error ||
              (state.containerStatus == ContainerStatus.idle &&
                  state.workingDir.isNotEmpty))
            GestureDetector(
              onTap: () => ref.read(codeProvider.notifier).restartSandbox(),
              child: Text('retry',
                  style: TextStyle(fontSize: 11, color: cs.primary)),
            ),
          if (state.estimatedTokens > 0) ...[
            const SizedBox(width: 12),
            _ContextChip(tokens: state.estimatedTokens),
          ],
        ],
      ),
    );
  }
}

/// A small chip showing the estimated context size. Tapping it compacts the
/// conversation when it's getting large.
class _ContextChip extends ConsumerWidget {
  final int tokens;
  const _ContextChip({required this.tokens});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final color = tokens > 100000
        ? Colors.red.shade400
        : tokens > 50000
            ? Colors.amber.shade400
            : cs.onSurface.withValues(alpha: 0.4);
    return GestureDetector(
      onTap: () => ref.read(codeProvider.notifier).compactHistory(),
      child: Tooltip(
        message:
            'Estimated context: ${tokens ~/ 1000}k tokens. Tap to compact.',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.data_usage, size: 10, color: color),
              const SizedBox(width: 3),
              Text(
                '${(tokens / 1000).toStringAsFixed(1)}k',
                style: TextStyle(
                    fontSize: 10, fontFamily: 'monospace', color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Agent conversation panel ──────────────────────────────────────────────────

class _AgentPanel extends StatelessWidget {
  final List<CodeEntry> entries;
  final ScrollController scrollCtrl;
  final String workingDir;

  const _AgentPanel({
    required this.entries,
    required this.scrollCtrl,
    required this.workingDir,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return _EmptyAgent(workingDir: workingDir);
    return ListView.builder(
      controller: scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      itemCount: entries.length,
      itemBuilder: (_, i) => _EntryTile(entry: entries[i]),
    );
  }
}

class _EmptyAgent extends StatelessWidget {
  final String workingDir;
  const _EmptyAgent({required this.workingDir});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final suggestions = [
      'List the files in this project',
      'Explain the main entry point',
      'Find all TODO comments',
      'Run the tests and fix any failures',
      'Summarise recent git changes',
    ];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.smart_toy_outlined,
            size: 36, color: cs.primary.withValues(alpha: 0.35)),
        const SizedBox(height: 12),
        Text(
          workingDir.isNotEmpty ? workingDir.split('/').last : 'Code agent',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 20),
        ...suggestions.map((s) => _SuggestionTile(text: s)),
      ],
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  final String text;
  const _SuggestionTile({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.surfaceContainerHigh),
      ),
      child: Row(
        children: [
          Icon(Icons.arrow_forward,
              size: 13, color: cs.primary.withValues(alpha: 0.5)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6))),
          ),
        ],
      ),
    );
  }
}

// ── File viewer panel (syntax highlighted) ───────────────────────────────────

class _FileViewerPanel extends ConsumerStatefulWidget {
  final CodeFile file;
  const _FileViewerPanel({required this.file});

  @override
  ConsumerState<_FileViewerPanel> createState() => _FileViewerPanelState();
}

class _FileViewerPanelState extends ConsumerState<_FileViewerPanel> {
  // Atom One Dark palette
  static const _bg = Color(0xFF282C34);
  static const _gutterBg = Color(0xFF21252B);
  static const _baseColor = Color(0xFFABB2BF);
  static const _gutterColor = Color(0xFF4B5263);

  static const _theme = <String, TextStyle>{
    'hljs-comment':
        TextStyle(color: Color(0xFF5C6370), fontStyle: FontStyle.italic),
    'hljs-quote': TextStyle(color: Color(0xFF5C6370)),
    'hljs-keyword': TextStyle(color: Color(0xFFC678DD)),
    'hljs-selector-tag': TextStyle(color: Color(0xFFC678DD)),
    'hljs-literal': TextStyle(color: Color(0xFF56B6C2)),
    'hljs-string': TextStyle(color: Color(0xFF98C379)),
    'hljs-addition': TextStyle(color: Color(0xFF98C379)),
    'hljs-number': TextStyle(color: Color(0xFFD19A66)),
    'hljs-variable': TextStyle(color: Color(0xFFE06C75)),
    'hljs-template-variable': TextStyle(color: Color(0xFFE06C75)),
    'hljs-deletion': TextStyle(color: Color(0xFFE06C75)),
    'hljs-name': TextStyle(color: Color(0xFFE06C75)),
    'hljs-tag': TextStyle(color: Color(0xFFE06C75)),
    'hljs-attr': TextStyle(color: Color(0xFFD19A66)),
    'hljs-attribute': TextStyle(color: Color(0xFFD19A66)),
    'hljs-type': TextStyle(color: Color(0xFFE5C07B)),
    'hljs-built_in': TextStyle(color: Color(0xFFE5C07B)),
    'hljs-class': TextStyle(color: Color(0xFFE5C07B)),
    'hljs-title': TextStyle(color: Color(0xFF61AFEF)),
    'hljs-function': TextStyle(color: Color(0xFF61AFEF)),
    'hljs-section': TextStyle(color: Color(0xFF61AFEF)),
    'hljs-operator': TextStyle(color: Color(0xFF56B6C2)),
    'hljs-property': TextStyle(color: Color(0xFF56B6C2)),
    'hljs-regexp': TextStyle(color: Color(0xFF98C379)),
    'hljs-symbol': TextStyle(color: Color(0xFF56B6C2)),
    'hljs-bullet': TextStyle(color: Color(0xFFE06C75)),
    'hljs-meta': TextStyle(color: Color(0xFF5C6370)),
    'hljs-link': TextStyle(
        color: Color(0xFF56B6C2), decoration: TextDecoration.underline),
    'hljs-emphasis': TextStyle(fontStyle: FontStyle.italic),
    'hljs-strong': TextStyle(fontWeight: FontWeight.bold),
    'hljs-params': TextStyle(color: Color(0xFFABB2BF)),
    'hljs-punctuation': TextStyle(color: Color(0xFFABB2BF)),
    'hljs-selector-class': TextStyle(color: Color(0xFFE5C07B)),
    'hljs-selector-id': TextStyle(color: Color(0xFFE06C75)),
    'hljs-selector-attr': TextStyle(color: Color(0xFF56B6C2)),
  };

  static const _baseStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    color: _baseColor,
    height: 1.0,
  );

  List<List<InlineSpan>>? _lines;
  double _maxLineChars = 80;
  bool _editing = false;
  bool _wrap = false;
  late TextEditingController _editCtrl;

  @override
  void initState() {
    super.initState();
    _parse();
    _editCtrl = TextEditingController(text: widget.file.content);
  }

  @override
  void didUpdateWidget(_FileViewerPanel old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) {
      _parse();
      _editCtrl.text = widget.file.content;
      _editing = false;
    }
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final notifier = ref.read(codeProvider.notifier);
    final err = await notifier.saveFile(widget.file.path, _editCtrl.text);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() => _editing = false);
    _parse();
  }

  Future<void> _parse() async {
    if (mounted) setState(() => _lines = null);
    final content = widget.file.content;
    final lang = _langForFile(widget.file.name);

    await Future.microtask(() {
      List<List<InlineSpan>> lines;
      try {
        final result = highlight.parse(content, language: lang);
        final flat = <InlineSpan>[];
        if (result.nodes != null) {
          _flattenNodes(result.nodes!, flat, null);
        } else {
          flat.add(TextSpan(text: content, style: _baseStyle));
        }
        lines = _splitIntoLines(flat);
      } catch (_) {
        lines = content
            .split('\n')
            .map((l) => <InlineSpan>[TextSpan(text: l, style: _baseStyle)])
            .toList();
      }

      double maxChars = 0;
      for (final line in lines) {
        double len = 0;
        for (final span in line) {
          if (span is TextSpan) len += (span.text?.length ?? 0);
        }
        if (len > maxChars) maxChars = len;
      }

      if (mounted) {
        setState(() {
          _lines = lines;
          _maxLineChars = maxChars;
        });
      }
    });
  }

  static void _flattenNodes(
    List<Node> nodes,
    List<InlineSpan> out,
    TextStyle? parent,
  ) {
    for (final node in nodes) {
      final style = node.className != null
          ? (_theme['hljs-${node.className}']
                  ?.copyWith(fontFamily: 'monospace', fontSize: 13) ??
              parent)
          : parent;
      if (node.value != null) {
        out.add(TextSpan(text: node.value, style: style ?? _baseStyle));
      }
      if (node.children != null) {
        _flattenNodes(node.children!, out, style);
      }
    }
  }

  static List<List<InlineSpan>> _splitIntoLines(List<InlineSpan> spans) {
    final lines = <List<InlineSpan>>[];
    var current = <InlineSpan>[];
    for (final span in spans) {
      if (span is! TextSpan || span.text == null) continue;
      final parts = span.text!.split('\n');
      for (int i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) {
          current.add(TextSpan(text: parts[i], style: span.style));
        }
        if (i < parts.length - 1) {
          lines.add(current);
          current = [];
        }
      }
    }
    lines.add(current);
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;

    return Column(
      children: [
        // Breadcrumb
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          color: _gutterBg,
          child: Text(
            widget.file.path,
            style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Color(0xFF636D83)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Code / editor
        Expanded(
          child: _editing
              ? _EditorView(
                  controller: _editCtrl,
                  wrap: _wrap,
                  onSave: _save,
                  onCancel: () => setState(() {
                    _editing = false;
                    _editCtrl.text = widget.file.content;
                  }),
                )
              : lines == null
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : _CodeView(
                      lines: lines,
                      maxLineChars: _maxLineChars,
                      content: widget.file.content,
                      wrap: _wrap,
                    ),
        ),
        // Footer
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: _gutterBg,
          child: Row(
            children: [
              Text(
                '${lines?.length ?? 0} lines',
                style: const TextStyle(fontSize: 11, color: _gutterColor),
              ),
              const SizedBox(width: 16),
              Text(
                widget.file.name.contains('.')
                    ? '.${widget.file.name.split('.').last}'
                    : 'plain',
                style: const TextStyle(fontSize: 11, color: _gutterColor),
              ),
              const Spacer(),
              // Wrap toggle
              GestureDetector(
                onTap: () => setState(() => _wrap = !_wrap),
                child: Row(
                  children: [
                    Icon(Icons.wrap_text,
                        size: 12,
                        color: _wrap ? const Color(0xFF61AFEF) : _gutterColor),
                    const SizedBox(width: 4),
                    Text('wrap',
                        style: TextStyle(
                            fontSize: 11,
                            color: _wrap
                                ? const Color(0xFF61AFEF)
                                : _gutterColor)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Edit / save toggle
              if (_editing)
                GestureDetector(
                  onTap: _save,
                  child: const Row(
                    children: [
                      Icon(Icons.save_outlined,
                          size: 12, color: Color(0xFF98C379)),
                      SizedBox(width: 4),
                      Text('save',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF98C379))),
                    ],
                  ),
                )
              else
                GestureDetector(
                  onTap: () => setState(() => _editing = true),
                  child: const Row(
                    children: [
                      Icon(Icons.edit_outlined,
                          size: 12, color: Color(0xFF61AFEF)),
                      SizedBox(width: 4),
                      Text('edit',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF61AFEF))),
                    ],
                  ),
                ),
              const SizedBox(width: 16),
              GestureDetector(
                onTap: () =>
                    Clipboard.setData(ClipboardData(text: widget.file.content)),
                child: const Row(
                  children: [
                    Icon(Icons.copy, size: 12, color: _gutterColor),
                    SizedBox(width: 4),
                    Text('copy',
                        style: TextStyle(fontSize: 11, color: _gutterColor)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CodeView extends StatelessWidget {
  final List<List<InlineSpan>> lines;
  final double maxLineChars;
  final String content;
  final bool wrap;

  const _CodeView({
    required this.lines,
    required this.maxLineChars,
    required this.content,
    this.wrap = false,
  });

  @override
  Widget build(BuildContext context) {
    final lineCount = lines.length;
    final gutterWidth = '${lineCount}'.length * 9.0 + 20.0;
    // 7.8px per monospace char at 13px; generous padding
    final contentWidth = max(gutterWidth + maxLineChars * 7.8 + 48, 600.0);

    return Container(
      color: _FileViewerPanelState._bg,
      child: Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: wrap ? Axis.vertical : Axis.horizontal,
          child: SizedBox(
            width: wrap ? null : contentWidth,
            child: ListView.builder(
              itemCount: lineCount,
              itemExtent: 20.0,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (_, i) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Gutter
                  Container(
                    width: gutterWidth,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    color: _FileViewerPanelState._gutterBg,
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: _FileViewerPanelState._gutterColor,
                        height: 1,
                      ),
                    ),
                  ),
                  // Code
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: _FileViewerPanelState._baseStyle,
                        children: lines[i].isEmpty
                            ? const [TextSpan(text: '​')]
                            : lines[i],
                      ),
                      maxLines: wrap ? null : 1,
                      softWrap: wrap,
                      overflow: wrap ? TextOverflow.clip : TextOverflow.visible,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A plain-text editor for a file, with optional wrapping and save/cancel.
class _EditorView extends StatelessWidget {
  final TextEditingController controller;
  final bool wrap;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  const _EditorView({
    required this.controller,
    required this.wrap,
    required this.onSave,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _FileViewerPanelState._bg,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: controller,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: _FileViewerPanelState._baseColor,
                  height: 1.4,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  filled: false,
                  hintText: 'Edit the file…',
                  hintStyle: TextStyle(color: Color(0xFF4B5263)),
                ),
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: _FileViewerPanelState._gutterBg,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel',
                      style: TextStyle(fontSize: 12, color: Color(0xFFE06C75))),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onSave,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF98C379),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  ),
                  child: const Text('Save',
                      style: TextStyle(fontSize: 12, color: Color(0xFF282C34))),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _langForFile(String name) {
  if (!name.contains('.')) return 'plaintext';
  return switch (name.split('.').last.toLowerCase()) {
    'dart' => 'dart',
    'py' => 'python',
    'js' || 'mjs' || 'cjs' => 'javascript',
    'ts' => 'typescript',
    'jsx' || 'tsx' => 'javascript',
    'go' => 'go',
    'rs' => 'rust',
    'c' || 'h' => 'c',
    'cpp' || 'cc' || 'cxx' || 'hpp' => 'cpp',
    'swift' => 'swift',
    'kt' || 'kts' => 'kotlin',
    'java' => 'java',
    'rb' => 'ruby',
    'php' => 'php',
    'sh' || 'bash' || 'zsh' => 'bash',
    'json' || 'jsonc' => 'json',
    'yaml' || 'yml' => 'yaml',
    'xml' || 'html' || 'htm' || 'svg' => 'xml',
    'css' => 'css',
    'scss' || 'sass' => 'scss',
    'sql' => 'sql',
    'md' || 'mdx' => 'markdown',
    _ => 'plaintext',
  };
}

// ── Entry tiles (agent output) ────────────────────────────────────────────────

class _EntryTile extends StatefulWidget {
  final CodeEntry entry;
  const _EntryTile({required this.entry});

  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final e = widget.entry;

    return switch (e.type) {
      CodeEntryType.user => Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.65),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.85),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Text(e.content,
                style:
                    TextStyle(color: cs.onPrimary, fontSize: 13, height: 1.4)),
          ),
        ),
      CodeEntryType.assistantText => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: MarkdownBody(
            data: e.content,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(fontSize: 13, color: cs.onSurface, height: 1.55),
              code: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  backgroundColor: cs.surfaceContainerHigh,
                  color: cs.primary.withValues(alpha: 0.9)),
              codeblockDecoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      CodeEntryType.toolCall => Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF3B82F6).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 13, color: Color(0xFF3B82F6)),
              const SizedBox(width: 6),
              Text(e.label ?? '',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF3B82F6),
                      fontFamily: 'monospace')),
              const SizedBox(width: 6),
              Expanded(
                child: Text(e.content,
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                        fontFamily: 'monospace'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      CodeEntryType.toolOutput => Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.terminal, size: 11, color: Color(0xFF4B9EF8)),
                const SizedBox(width: 5),
                Text('${e.label ?? 'run_command'}  · live output',
                    style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF4B9EF8),
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace')),
              ]),
              const SizedBox(height: 6),
              Text(
                e.content,
                style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Color(0xFFCDD6F4),
                    height: 1.5),
              ),
            ],
          ),
        ),
      CodeEntryType.toolResult => GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.surfaceContainerHigh),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 13, color: Colors.green.shade400),
                    const SizedBox(width: 5),
                    Text(e.label ?? '',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.green.shade400)),
                    const Spacer(),
                    Text(
                      _expanded
                          ? '${e.content.split('\n').length} lines ▲'
                          : '${e.content.split('\n').length} lines ▼',
                      style: TextStyle(
                          fontSize: 10, color: cs.onSurface.withValues(alpha: 0.3)),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () =>
                          Clipboard.setData(ClipboardData(text: e.content)),
                      child: Icon(Icons.copy,
                          size: 12, color: cs.onSurface.withValues(alpha: 0.3)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _expanded
                      ? e.content
                      : e.content.split('\n').take(3).join('\n'),
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: cs.onSurface.withValues(alpha: 0.65),
                      height: 1.4),
                ),
              ],
            ),
          ),
        ),
      CodeEntryType.error => Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(e.content,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.error, fontSize: 12)),
        ),
    };
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController ctrl;
  final bool running;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _InputBar({
    required this.ctrl,
    required this.running,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.surfaceContainerHigh)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: AiInputField(
              controller: ctrl,
              hintText: 'Ask the agent…',
              hintStyle: const TextStyle(color: Colors.white24),
              onSend: running ? null : onSend,
            ),
          ),
          const SizedBox(width: 8),
          running
              ? IconButton.filled(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_rounded),
                  style: IconButton.styleFrom(
                    backgroundColor: cs.error,
                    foregroundColor: cs.onError,
                  ),
                )
              : IconButton.filled(
                  onPressed: onSend,
                  icon: const Icon(Icons.arrow_upward),
                  style: IconButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                  ),
                ),
        ],
      ),
    );
  }
}
