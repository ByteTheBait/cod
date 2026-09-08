import 'dart:async';
import '../models/config.dart';
import '../models/message.dart';
import '../models/task.dart';
import '../models/tool.dart';
import 'agent_service.dart';

class DaemonService {
  DaemonService._();
  static final DaemonService instance = DaemonService._();

  Timer? _timer;
  bool _ticking = false;
  DaemonMode _mode = DaemonMode.manual;

  List<Task> Function()? _tasksReader;
  AppConfig Function()? _configReader;
  Future<void> Function(String taskId, TaskStatus status)? _onComplete;
  Future<void> Function(String taskId, Message message)? _onThreadMessage;

  DateTime? lastRun;

  void init({
    required List<Task> Function() tasksReader,
    required AppConfig Function() configReader,
    required Future<void> Function(String taskId, TaskStatus status) onComplete,
    Future<void> Function(String taskId, Message message)? onThreadMessage,
  }) {
    _tasksReader = tasksReader;
    _configReader = configReader;
    _onComplete = onComplete;
    _onThreadMessage = onThreadMessage;
  }

  void apply(DaemonMode mode, String nightlyTime) {
    _timer?.cancel();
    _timer = null;
    _mode = mode;

    if (mode == DaemonMode.manual) return;

    if (mode == DaemonMode.nightly) {
      _scheduleNightly(nightlyTime);
    } else {
      _timer = Timer.periodic(mode.interval!, (_) => tick());
    }
  }

  void _scheduleNightly(String hhmm) {
    _timer = Timer(_durationUntil(hhmm), () {
      tick();
      _scheduleNightly(hhmm);
    });
  }

  Duration _durationUntil(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return const Duration(hours: 24);
    final h = int.tryParse(parts[0]) ?? 23;
    final m = int.tryParse(parts[1]) ?? 0;
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, h, m);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next.difference(now);
  }

  Future<void> tick() async {
    if (_ticking) return;
    if (_tasksReader == null || _configReader == null || _onComplete == null) return;

    _ticking = true;
    lastRun = DateTime.now();
    try {
      final config = _configReader!();
      if (config.active.apiKey.isEmpty && config.activeProviderId != 'ollama') return;

      final tasks = _tasksReader!();
      for (final task in tasks) {
        if (task.status == TaskStatus.done) continue;
        await _runTask(task, config);
      }
    } finally {
      _ticking = false;
    }
  }

  Future<void> _runTask(Task task, AppConfig config) async {
    final skillDef = SkillDef.of(task.skill);
    final prompt = 'Complete this task:\n'
        'Title: ${task.title}\n'
        '${task.description.isNotEmpty ? 'Description: ${task.description}\n' : ''}'
        'Status: ${task.status.label}';

    // Show the run in the task's chat thread.
    await _onThreadMessage?.call(task.id, Message.user(prompt));

    final service = AgentService();
    var runningText = '';

    void flushText() {
      if (runningText.trim().isNotEmpty) {
        _onThreadMessage?.call(task.id, Message.assistant(runningText.trim()));
        runningText = '';
      }
    }

    await for (final event in service.run(
      initialPrompt: prompt,
      tools: skillDef.tools,
      model: config.modelFor(Feature.tasks),
      apiKey: config.active.apiKey,
      providerId: config.activeProviderId,
      protocol: config.active.protocol,
      baseUrl: config.active.baseUrl,
      system: skillDef.system,
      maxIterations: config.agentMaxIterations,
    )) {
      switch (event) {
        case AgentText(:final text):
          if (text.isNotEmpty) runningText += text + '\n';
        case AgentToolStart(:final call):
          flushText();
          _onThreadMessage?.call(
            task.id,
            Message.assistant('🤖 [agent] running tool: **${call.name}**'),
          );
        case AgentCommandOutput():
          break; // daemon doesn't stream command output to the thread
        case AgentToolDone(:final toolName, :final result):
          flushText();
          if (toolName == 'mark_complete') {
            _onThreadMessage?.call(
              task.id,
              Message.assistant('✅ Done.\n\n$result'),
            );
            await _onComplete!(task.id, TaskStatus.done);
          }
        case AgentComplete():
          break;
        case AgentError(:final message):
          flushText();
          _onThreadMessage?.call(
            task.id,
            Message.assistant('⚠️ Agent error: $message'),
          );
      }
    }

    flushText();
  }

  bool get isRunning => _mode != DaemonMode.manual || _ticking;
  bool get isTicking => _ticking;
  DaemonMode get mode => _mode;

  void dispose() {
    _timer?.cancel();
  }
}
