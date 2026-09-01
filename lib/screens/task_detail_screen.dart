import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/config.dart';
import '../models/message.dart';
import '../models/task.dart';
import '../models/tool.dart';
import '../services/agent_service.dart';
import '../state/providers.dart';
import '../widgets/message_bubble.dart';
import '../widgets/provider_badge.dart';

class TaskDetailScreen extends ConsumerStatefulWidget {
  final String taskId;
  final bool autoRun;
  const TaskDetailScreen({super.key, required this.taskId, this.autoRun = false});

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _streaming = false;
  bool _agentRunning = false;
  final List<_AgentEntry> _agentLog = [];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this,
        initialIndex: widget.autoRun ? 1 : 0);
    ref.read(tasksProvider.notifier).markRead(widget.taskId);
    if (widget.autoRun) {
      Future.microtask(_runAgent);
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
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

  Task? _task() => ref
      .read(tasksProvider)
      .where((t) => t.id == widget.taskId)
      .firstOrNull;

  Future<void> _runAgent() async {
    final task = _task();
    if (task == null || _agentRunning) return;
    final config = ref.read(configProvider);
    if (config.active.apiKey.isEmpty && config.activeProviderId != 'ollama') return;

    setState(() { _agentRunning = true; _agentLog.clear(); });

    final skillDef = SkillDef.of(task.skill);
    final prompt = 'Complete this task:\n'
        'Title: ${task.title}\n'
        '${task.description.isNotEmpty ? 'Description: ${task.description}\n' : ''}'
        'Status: ${task.status.label}';

    final service = AgentService();
    await for (final event in service.run(
      initialPrompt: prompt,
      tools: skillDef.tools,
      model: config.modelFor(Feature.tasks),
      apiKey: config.active.apiKey,
      providerId: config.activeProviderId,
      baseUrl: config.active.baseUrl,
      system: skillDef.system,
      maxIterations: config.agentMaxIterations,
    )) {
      switch (event) {
        case AgentText(:final text):
          if (text.isNotEmpty) {
            setState(() => _agentLog.add(_AgentEntry.text(text)));
          }
        case AgentToolStart(:final call):
          final label = '${call.name}(${_inputSummary(call.input)})';
          setState(() => _agentLog.add(_AgentEntry.toolCall(label)));
        case AgentCommandOutput():
          break; // task agent doesn't stream command output
        case AgentToolDone(:final toolName, :final result):
          setState(() => _agentLog.add(_AgentEntry.toolResult(toolName, result)));
          if (toolName == 'mark_complete') {
            ref.read(tasksProvider.notifier).cycleStatusTo(
                widget.taskId, TaskStatus.done);
          }
        case AgentComplete():
          break;
        case AgentError(:final message):
          setState(() => _agentLog.add(_AgentEntry.error(message)));
      }
    }

    setState(() => _agentRunning = false);
  }

  String _inputSummary(Map<String, dynamic> input) {
    if (input.containsKey('path')) return '"${input['path']}"';
    if (input.containsKey('command')) return '"${input['command']}"';
    if (input.containsKey('summary')) return '"${input['summary']}"';
    return input.keys.join(', ');
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _streaming) return;
    _ctrl.clear();

    final config = ref.read(configProvider);
    final llm = ref.read(llmRegistryProvider)[config.activeProviderId];
    if (llm == null) return;

    final tasksNotifier = ref.read(tasksProvider.notifier);
    final task = _task();
    if (task == null) return;

    final systemMsg = Message.system(
      'You are an AI assistant helping with a task.\n'
      'Task: ${task.title}\n'
      '${task.description.isNotEmpty ? 'Description: ${task.description}\n' : ''}'
      'Status: ${task.status.label}\n'
      'Be concise and helpful.',
    );

    await tasksNotifier.addThreadMessage(widget.taskId, Message.user(text));
    _scrollToBottom();

    final placeholder = Message.assistant('', isStreaming: true);
    await tasksNotifier.addThreadMessage(widget.taskId, placeholder);
    setState(() => _streaming = true);
    _scrollToBottom();

    final history = [
      systemMsg,
      ..._task()!.thread.where((m) => !m.isStreaming).toList(),
    ];

    String accumulated = '';
    try {
      await for (final chunk in llm.stream(
        messages: history,
        model: config.modelFor(Feature.tasks),
        apiKey: config.active.apiKey,
        baseUrl: config.active.baseUrl.isNotEmpty ? config.active.baseUrl : null,
      )) {
        accumulated += chunk;
        tasksNotifier.updateThreadStreaming(widget.taskId, accumulated);
        _scrollToBottom();
      }
    } catch (e) {
      accumulated = '_Error: ${e}_';
      tasksNotifier.updateThreadStreaming(widget.taskId, accumulated);
    }

    await tasksNotifier.finalizeThreadStreaming(widget.taskId);
    setState(() => _streaming = false);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(tasksProvider);
    final task = tasks.where((t) => t.id == widget.taskId).firstOrNull;
    final config = ref.watch(configProvider);
    final cs = Theme.of(context).colorScheme;

    if (task == null) return const Scaffold(body: Center(child: Text('Task not found')));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.title,
                style: const TextStyle(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
            ProviderBadge(
              providerId: config.activeProviderId,
              modelId: config.active.selectedModel,
              compact: true,
            ),
          ],
        ),
        actions: [
          GestureDetector(
            onTap: () => ref.read(tasksProvider.notifier).cycleStatus(widget.taskId),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _StatusLabel(status: task.status),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: 'Chat'),
            Tab(text: 'Agent'),
          ],
          indicatorColor: cs.primary,
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurface.withOpacity(0.45),
        ),
      ),
      body: Column(
        children: [
          if (task.description.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              color: cs.surfaceContainerLow,
              child: Text(
                task.description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withOpacity(0.55)),
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                // ── Chat tab ────────────────────────────────────────────────
                Column(
                  children: [
                    Expanded(
                      child: task.thread.isEmpty
                          ? _EmptyThread(taskTitle: task.title)
                          : ListView.builder(
                              controller: _scrollCtrl,
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                              itemCount: task.thread.length,
                              itemBuilder: (_, i) =>
                                  MessageBubble(message: task.thread[i]),
                            ),
                    ),
                    _InputBar(ctrl: _ctrl, streaming: _streaming, onSend: _send),
                  ],
                ),
                // ── Agent tab ───────────────────────────────────────────────
                _AgentTab(
                  log: _agentLog,
                  running: _agentRunning,
                  onRun: _runAgent,
                  taskTitle: task.title,
                  skill: task.skill,
                  onSkillChanged: (s) => ref
                      .read(tasksProvider.notifier)
                      .updateSkill(task.id, s),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  final TaskStatus status;
  const _StatusLabel({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (status) {
      TaskStatus.todo => (Colors.grey.shade500, Icons.radio_button_unchecked),
      TaskStatus.inProgress => (Colors.amber.shade400, Icons.pending_outlined),
      TaskStatus.done => (Colors.green.shade400, Icons.check_circle_outline),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          status.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _EmptyThread extends StatelessWidget {
  final String taskTitle;
  const _EmptyThread({required this.taskTitle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_outlined, size: 36, color: cs.primary.withOpacity(0.4)),
            const SizedBox(height: 12),
            Text(
              'Ask about this task',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: cs.onSurface.withOpacity(0.6),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController ctrl;
  final bool streaming;
  final VoidCallback onSend;

  const _InputBar({required this.ctrl, required this.streaming, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(12, 8, 12, MediaQuery.of(context).padding.bottom + 8),
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
              decoration: const InputDecoration(
                hintText: 'Ask the AI about this task...',
                hintStyle: TextStyle(color: Colors.white24),
              ),
            ),
          ),
          const SizedBox(width: 8),
          streaming
              ? SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                    ),
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

// ── Agent tab ─────────────────────────────────────────────────────────────────

enum _AgentEntryType { text, toolCall, toolResult, error }

class _AgentEntry {
  final _AgentEntryType type;
  final String content;
  final String? label;
  _AgentEntry({required this.type, required this.content, this.label});
  factory _AgentEntry.text(String t) => _AgentEntry(type: _AgentEntryType.text, content: t);
  factory _AgentEntry.toolCall(String label) =>
      _AgentEntry(type: _AgentEntryType.toolCall, content: label, label: label);
  factory _AgentEntry.toolResult(String name, String result) =>
      _AgentEntry(type: _AgentEntryType.toolResult, content: result, label: name);
  factory _AgentEntry.error(String msg) =>
      _AgentEntry(type: _AgentEntryType.error, content: msg);
}

class _AgentTab extends StatelessWidget {
  final List<_AgentEntry> log;
  final bool running;
  final VoidCallback onRun;
  final String taskTitle;
  final TaskSkill skill;
  final void Function(TaskSkill) onSkillChanged;

  const _AgentTab({
    required this.log,
    required this.running,
    required this.onRun,
    required this.taskTitle,
    required this.skill,
    required this.onSkillChanged,
  });

  void _showSkillPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SkillPickerSheet(current: skill, onPick: onSkillChanged),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: cs.surfaceContainerLow,
          child: Row(
            children: [
              GestureDetector(
                onTap: running ? null : () => _showSkillPicker(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: skill.color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: skill.color.withOpacity(0.35)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(skill.icon, size: 13, color: skill.color),
                      const SizedBox(width: 5),
                      Text(
                        skill.label,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: skill.color),
                      ),
                      if (!running) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.expand_more, size: 13, color: skill.color.withOpacity(0.7)),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  running ? 'Agent is working…' : skill.label == 'Research'
                      ? 'Searches the web and synthesizes findings.'
                      : skill.label == 'Code'
                          ? 'Reads, writes, and runs code.'
                          : skill.label == 'Write'
                              ? 'Creates and edits documents.'
                              : 'Uses all available tools.',
                  style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.5)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: running ? null : onRun,
                icon: running
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.onPrimary))
                    : const Icon(Icons.play_arrow, size: 16),
                label: Text(running ? 'Running' : 'Run'),
                style: FilledButton.styleFrom(
                  backgroundColor: cs.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: log.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.smart_toy_outlined,
                          size: 40, color: cs.primary.withOpacity(0.35)),
                      const SizedBox(height: 12),
                      Text('Tap Run agent to let the AI work on this task.',
                          style: TextStyle(
                              color: cs.onSurface.withOpacity(0.45), fontSize: 13)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: log.length,
                  itemBuilder: (_, i) => _AgentEntryTile(entry: log[i]),
                ),
        ),
      ],
    );
  }
}

class _SkillPickerSheet extends StatelessWidget {
  final TaskSkill current;
  final void Function(TaskSkill) onPick;
  const _SkillPickerSheet({required this.current, required this.onPick});

  static const _descriptions = {
    TaskSkill.general: 'All tools — file access, shell, and web search.',
    TaskSkill.research: 'Web search + save findings. Good for information gathering.',
    TaskSkill.code: 'File and shell tools. No web access.',
    TaskSkill.write: 'Read and write documents. Focused on text output.',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Skill', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          ...TaskSkill.values.map((s) {
            final isActive = s == current;
            return GestureDetector(
              onTap: () {
                onPick(s);
                Navigator.pop(context);
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isActive ? s.color.withOpacity(0.12) : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isActive ? s.color.withOpacity(0.5) : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(s.icon, size: 18, color: s.color),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.label,
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: isActive ? s.color : cs.onSurface)),
                          const SizedBox(height: 2),
                          Text(_descriptions[s]!,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurface.withOpacity(0.5))),
                        ],
                      ),
                    ),
                    if (isActive) Icon(Icons.check, size: 16, color: s.color),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _AgentEntryTile extends StatelessWidget {
  final _AgentEntry entry;
  const _AgentEntryTile({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (entry.type) {
      _AgentEntryType.text => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(entry.content,
              style: TextStyle(
                  fontSize: 13, color: cs.onSurface.withOpacity(0.85), height: 1.5)),
        ),
      _AgentEntryType.toolCall => Container(
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
              Expanded(
                child: Text(entry.content,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace', color: Color(0xFF3B82F6)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: cs.primary.withOpacity(0.5)),
              ),
            ],
          ),
        ),
      _AgentEntryType.toolResult => Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.check, size: 12, color: Colors.green.shade400),
                  const SizedBox(width: 4),
                  Text(entry.label ?? '',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.green.shade400,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                entry.content.length > 300
                    ? '${entry.content.substring(0, 300)}…'
                    : entry.content,
                style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurface.withOpacity(0.6),
                    height: 1.4),
              ),
            ],
          ),
        ),
      _AgentEntryType.error => Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.error.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(entry.content,
              style: TextStyle(color: cs.error, fontSize: 12)),
        ),
    };
  }
}
