import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/config.dart';
import '../models/task.dart';
import '../models/tool.dart';
import '../services/agent_service.dart';
import '../state/providers.dart';

const _prefSessionId = 'minnow_session_id';

class MinnowSync {
  final Ref _ref;
  String _sessionId = '';
  RealtimeChannel? _channel;

  MinnowSync(this._ref);

  SupabaseClient get _db => Supabase.instance.client;

  String get sessionId => _sessionId;
  String get qrData => 'minnow://session/$_sessionId';

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    _sessionId = prefs.getString(_prefSessionId) ?? '';
    if (_sessionId.isEmpty) {
      _sessionId = const Uuid().v4();
      await prefs.setString(_prefSessionId, _sessionId);
    }

    _channel = _db
        .channel('session-$_sessionId')
        .onBroadcast(event: 'create_task', callback: _handleCommand)
        .onBroadcast(event: 'delete_task', callback: _handleCommand)
        .onBroadcast(event: 'run_task', callback: _handleCommand);
    await _channel!.subscribe();

    // Sync existing tasks to Supabase after a short delay for TasksNotifier to load
    Future.delayed(const Duration(milliseconds: 800), () {
      syncAllTasks(_ref.read(tasksProvider));
    });
  }

  Future<void> dispose() async {
    await _channel?.unsubscribe();
    _channel = null;
  }

  // ── Task sync to Supabase ─────────────────────────────────────────────────

  void syncAllTasks(List<Task> tasks) {
    if (tasks.isEmpty) return;
    final rows = tasks.map(_toRow).toList();
    _db.from('tasks').upsert(rows).then((_) {}).catchError((_) {});
  }

  void syncTask(Task task) {
    _db.from('tasks').upsert(_toRow(task)).then((_) {}).catchError((_) {});
  }

  void deleteTask(String id) {
    _db.from('tasks').delete().eq('id', id).then((_) {}).catchError((_) {});
  }

  Map<String, dynamic> _toRow(Task t) => {
        'id': t.id,
        'session_id': _sessionId,
        'title': t.title,
        'description': t.description,
        'status': t.status.name,
        'has_unread': t.hasUnread,
        'updated_at': t.updatedAt.toIso8601String(),
      };

  // ── Agent event broadcast ─────────────────────────────────────────────────

  void broadcastAgentEvent(String taskId, AgentEvent event) {
    final Map<String, dynamic>? payload = switch (event) {
      AgentText(:final text) =>
        {'type': 'agent_text', 'taskId': taskId, 'text': text},
      AgentToolStart(:final call) => {
          'type': 'agent_tool_start',
          'taskId': taskId,
          'name': call.name,
          'input': call.input.toString(),
        },
      AgentToolDone(:final toolName, :final result) => {
          'type': 'agent_tool_done',
          'taskId': taskId,
          'name': toolName,
          'result': result,
        },
      AgentCommandOutput(:final line) =>
        {'type': 'agent_command_output', 'taskId': taskId, 'line': line},
      AgentComplete() => {'type': 'agent_complete', 'taskId': taskId},
      AgentError(:final message) =>
        {'type': 'agent_error', 'taskId': taskId, 'message': message},
    };
    if (payload != null) {
      _channel
          ?.sendBroadcastMessage(event: payload['type'] as String, payload: payload)
          .catchError((_) {});
    }
  }

  // ── Incoming command handler ──────────────────────────────────────────────

  void _handleCommand(Map<String, dynamic> payload) async {
    final type = payload['type'] as String?;
    switch (type) {
      case 'create_task':
        final title = payload['title'] as String? ?? '';
        final desc = payload['description'] as String? ?? '';
        if (title.isNotEmpty) {
          await _ref.read(tasksProvider.notifier).add(title: title, description: desc);
        }
      case 'delete_task':
        final id = payload['taskId'] as String?;
        if (id != null) await _ref.read(tasksProvider.notifier).delete(id);
      case 'run_task':
        final taskId = payload['taskId'] as String?;
        if (taskId != null) _runTask(taskId);
    }
  }

  void _runTask(String taskId) async {
    final tasks = _ref.read(tasksProvider);
    final task = tasks.where((t) => t.id == taskId).firstOrNull;
    if (task == null) return;

    final config = _ref.read(configProvider);
    await _ref.read(tasksProvider.notifier).cycleStatusTo(taskId, TaskStatus.inProgress);

    final system = 'You are an autonomous task-completion agent. '
        'Task: "${task.title}". '
        '${task.description.isNotEmpty ? 'Description: "${task.description}". ' : ''}'
        'Complete the task using the tools available, then call mark_complete.';

    final service = AgentService();
    await for (final event in service.run(
      initialPrompt: task.title,
      tools: AgentService.taskTools,
      model: config.modelFor(Feature.tasks),
      apiKey: config.active.apiKey,
      providerId: config.activeProviderId,
      baseUrl: config.active.baseUrl,
      system: system,
    )) {
      broadcastAgentEvent(taskId, event);
      if (event is AgentComplete) {
        await _ref.read(tasksProvider.notifier).cycleStatusTo(taskId, TaskStatus.done);
      }
      if (event case AgentToolDone(:final toolName) when toolName == 'mark_complete') {
        await _ref.read(tasksProvider.notifier).cycleStatusTo(taskId, TaskStatus.done);
      }
    }
  }
}
