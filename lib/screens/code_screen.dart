import 'dart:async';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import '../models/config.dart';
import '../models/tool.dart';
import '../services/agent_service.dart';
import '../services/sandbox_service.dart';
import '../state/code.dart';
import '../state/providers.dart';
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
    notifier.addEntry(CodeEntry.user(text));
    notifier.setRunning(true);
    _scrollToBottom();

    final system = workingDir.isNotEmpty
        ? 'You are an expert coding assistant with access to file system and shell tools.\n'
          'Working directory: $workingDir\n'
          'Be concise. Always read a file with read_file before modifying it. '
          'When editing existing files use str_replace_file — it is safer and only changes what you intend. '
          'Only use write_file to create brand-new files.'
        : 'You are an expert coding assistant. Be concise and think step-by-step. '
          'When editing existing files use str_replace_file. Only use write_file for new files.';

    final history = ref.read(codeProvider).history;
    final service = AgentService();
    _inStreamingCommand = false;

    _agentSub = service.run(
      initialPrompt: text,
      tools: AgentService.codeTools,
      model: config.modelFor(Feature.code),
      apiKey: config.active.apiKey,
      providerId: config.activeProviderId,
      baseUrl: config.active.baseUrl,
      system: system,
      workingDir: workingDir.isNotEmpty ? workingDir : null,
      history: history,
      maxIterations: config.agentMaxIterations,
      onMessagesUpdate: (msgs) =>
          ref.read(codeProvider.notifier).updateHistory(msgs),
      commandRunner: ref.read(codeProvider.notifier).commandRunner,
      commandStreamRunner: ref.read(codeProvider.notifier).commandStreamRunner,
    ).listen(
      (event) {
        switch (event) {
          case AgentText(:final text):
            if (text.isNotEmpty) notifier.addEntry(CodeEntry.assistant(text));
          case AgentToolStart(:final call):
            notifier.addEntry(CodeEntry.toolCall(call.name, _summarise(call.input)));
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

  String _summarise(Map<String, dynamic> input) {
    if (input.containsKey('path')) return '"${input['path']}"';
    if (input.containsKey('command')) return '"${input['command']}"';
    if (input.containsKey('pattern')) return '"${input['pattern']}" in ${input['directory'] ?? '.'}';
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
          if (codeState.workingDir.isNotEmpty)
            _SessionMenu(state: codeState),
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
            onPressed: () => ref.read(codeProvider.notifier).clearConversation(),
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
                    onPickFolder: _pickFolder,
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
      icon: Icon(Icons.history, size: 20, color: cs.onSurface.withOpacity(0.7)),
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
                  isActive ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16,
                  color: isActive ? cs.primary : cs.onSurface.withOpacity(0.4),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                if (isActive)
                  Text(' · ${s.entries.length}',
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurface.withOpacity(0.4))),
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
    final folderName = workingDir.isEmpty
        ? 'No folder'
        : workingDir.split('/').last;

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
                      size: 14, color: cs.primary.withOpacity(0.7)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      folderName.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface.withOpacity(0.55),
                        letterSpacing: 0.8,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'Open folder',
                    child: Icon(Icons.drive_folder_upload_outlined,
                        size: 16, color: cs.onSurface.withOpacity(0.4)),
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
                color: isActive
                    ? cs.primary
                    : cs.onSurface.withOpacity(0.45)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isActive
                      ? cs.onSurface
                      : cs.onSurface.withOpacity(0.5),
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
                    size: 12, color: cs.onSurface.withOpacity(0.4)),
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
      ContainerStatus.idle =>
        (Icons.circle_outlined,
         isDocker ? 'Docker ready — set a folder to start container' : 'Restricted mode',
         cs.onSurface.withOpacity(0.3)),
      ContainerStatus.starting =>
        (Icons.hourglass_empty, 'Starting container…', Colors.amber.shade400),
      ContainerStatus.running => isDocker
          ? (Icons.circle, '🐳  ${state.sandboxImage}  ·  isolated', Colors.green.shade400)
          : (Icons.shield_outlined, 'Restricted sandbox  ·  sanitised env', Colors.green.shade400),
      ContainerStatus.error =>
        (Icons.warning_amber_outlined, 'Sandbox error', cs.error),
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
              state.sandboxError != null ? 'Error: ${state.sandboxError}' : label,
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
        ],
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
        Icon(Icons.smart_toy_outlined, size: 36, color: cs.primary.withOpacity(0.35)),
        const SizedBox(height: 12),
        Text(
          workingDir.isNotEmpty ? workingDir.split('/').last : 'Code agent',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.onSurface.withOpacity(0.6),
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
          Icon(Icons.arrow_forward, size: 13, color: cs.primary.withOpacity(0.5)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.6))),
          ),
        ],
      ),
    );
  }
}

// ── File viewer panel (syntax highlighted) ───────────────────────────────────

class _FileViewerPanel extends StatefulWidget {
  final CodeFile file;
  const _FileViewerPanel({required this.file});

  @override
  State<_FileViewerPanel> createState() => _FileViewerPanelState();
}

class _FileViewerPanelState extends State<_FileViewerPanel> {
  // Atom One Dark palette
  static const _bg = Color(0xFF282C34);
  static const _gutterBg = Color(0xFF21252B);
  static const _baseColor = Color(0xFFABB2BF);
  static const _gutterColor = Color(0xFF4B5263);

  static const _theme = <String, TextStyle>{
    'hljs-comment':       TextStyle(color: Color(0xFF5C6370), fontStyle: FontStyle.italic),
    'hljs-quote':         TextStyle(color: Color(0xFF5C6370)),
    'hljs-keyword':       TextStyle(color: Color(0xFFC678DD)),
    'hljs-selector-tag':  TextStyle(color: Color(0xFFC678DD)),
    'hljs-literal':       TextStyle(color: Color(0xFF56B6C2)),
    'hljs-string':        TextStyle(color: Color(0xFF98C379)),
    'hljs-addition':      TextStyle(color: Color(0xFF98C379)),
    'hljs-number':        TextStyle(color: Color(0xFFD19A66)),
    'hljs-variable':      TextStyle(color: Color(0xFFE06C75)),
    'hljs-template-variable': TextStyle(color: Color(0xFFE06C75)),
    'hljs-deletion':      TextStyle(color: Color(0xFFE06C75)),
    'hljs-name':          TextStyle(color: Color(0xFFE06C75)),
    'hljs-tag':           TextStyle(color: Color(0xFFE06C75)),
    'hljs-attr':          TextStyle(color: Color(0xFFD19A66)),
    'hljs-attribute':     TextStyle(color: Color(0xFFD19A66)),
    'hljs-type':          TextStyle(color: Color(0xFFE5C07B)),
    'hljs-built_in':      TextStyle(color: Color(0xFFE5C07B)),
    'hljs-class':         TextStyle(color: Color(0xFFE5C07B)),
    'hljs-title':         TextStyle(color: Color(0xFF61AFEF)),
    'hljs-function':      TextStyle(color: Color(0xFF61AFEF)),
    'hljs-section':       TextStyle(color: Color(0xFF61AFEF)),
    'hljs-operator':      TextStyle(color: Color(0xFF56B6C2)),
    'hljs-property':      TextStyle(color: Color(0xFF56B6C2)),
    'hljs-regexp':        TextStyle(color: Color(0xFF98C379)),
    'hljs-symbol':        TextStyle(color: Color(0xFF56B6C2)),
    'hljs-bullet':        TextStyle(color: Color(0xFFE06C75)),
    'hljs-meta':          TextStyle(color: Color(0xFF5C6370)),
    'hljs-link':          TextStyle(color: Color(0xFF56B6C2), decoration: TextDecoration.underline),
    'hljs-emphasis':      TextStyle(fontStyle: FontStyle.italic),
    'hljs-strong':        TextStyle(fontWeight: FontWeight.bold),
    'hljs-params':        TextStyle(color: Color(0xFFABB2BF)),
    'hljs-punctuation':   TextStyle(color: Color(0xFFABB2BF)),
    'hljs-selector-class':TextStyle(color: Color(0xFFE5C07B)),
    'hljs-selector-id':   TextStyle(color: Color(0xFFE06C75)),
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

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(_FileViewerPanel old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) _parse();
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
    final cs = Theme.of(context).colorScheme;
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
                fontSize: 11, fontFamily: 'monospace', color: Color(0xFF636D83)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Code
        Expanded(
          child: lines == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _CodeView(
                  lines: lines,
                  maxLineChars: _maxLineChars,
                  content: widget.file.content,
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
              GestureDetector(
                onTap: () =>
                    Clipboard.setData(ClipboardData(text: widget.file.content)),
                child: const Row(
                  children: [
                    Icon(Icons.copy, size: 12, color: _gutterColor),
                    SizedBox(width: 4),
                    Text('copy', style: TextStyle(fontSize: 11, color: _gutterColor)),
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

  const _CodeView({
    required this.lines,
    required this.maxLineChars,
    required this.content,
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
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            child: ListView.builder(
              itemCount: lineCount,
              itemExtent: 20.0,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (_, i) => Row(
                crossAxisAlignment: CrossAxisAlignment.center,
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
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
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
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
            decoration: BoxDecoration(
              color: cs.primary.withOpacity(0.85),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Text(e.content,
                style: TextStyle(color: cs.onPrimary, fontSize: 13, height: 1.4)),
          ),
        ),
      CodeEntryType.assistantText => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: MarkdownBody(
            data: e.content,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(
                  fontSize: 13, color: cs.onSurface, height: 1.55),
              code: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  backgroundColor: cs.surfaceContainerHigh,
                  color: cs.primary.withOpacity(0.9)),
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
            color: const Color(0xFF3B82F6).withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.2)),
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
                        color: cs.onSurface.withOpacity(0.55),
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
            border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.15)),
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
                          fontSize: 10, color: cs.onSurface.withOpacity(0.3)),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => Clipboard.setData(ClipboardData(text: e.content)),
                      child: Icon(Icons.copy,
                          size: 12, color: cs.onSurface.withOpacity(0.3)),
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
                      color: cs.onSurface.withOpacity(0.65),
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
            color: Theme.of(context).colorScheme.error.withOpacity(0.1),
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
            child: TextField(
              controller: ctrl,
              maxLines: 4,
              minLines: 1,
              onSubmitted: running ? null : (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Ask the agent…',
                hintStyle: TextStyle(color: Colors.white24),
              ),
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
