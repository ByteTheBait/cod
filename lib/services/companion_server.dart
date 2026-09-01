import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/config.dart';
import '../models/task.dart';
import '../models/tool.dart';
import '../services/agent_service.dart';
import '../state/providers.dart';

const _port = 8765;

class CompanionServer {
  final Ref _ref;
  HttpServer? _server;
  final _clients = <WebSocket>{};

  CompanionServer(this._ref);

  String _cachedIp = '127.0.0.1';

  int get connectedCount => _clients.length;
  String get wsUrl => 'ws://$_cachedIp:$_port';

  Future<String> _findLocalIp() async {
    try {
      final ifaces = await NetworkInterface.list();
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<void> start() async {
    try {
      _cachedIp = await _findLocalIp();
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _server!.listen(_handleRequest);
    } catch (_) {}
  }

  Future<void> stop() async {
    for (final ws in _clients) {
      await ws.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  void _handleRequest(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    _clients.add(ws);

    // Send current task list on connect
    _sendTo(ws, {'type': 'tasks', 'tasks': _taskList()});

    ws.listen(
      (data) => _handleMessage(ws, data as String),
      onDone: () => _clients.remove(ws),
      onError: (_) => _clients.remove(ws),
    );
  }

  void _handleMessage(WebSocket ws, String data) async {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = msg['type'] as String?;
    switch (type) {
      case 'list_tasks':
        _sendTo(ws, {'type': 'tasks', 'tasks': _taskList()});

      case 'create_task':
        final title = msg['title'] as String? ?? '';
        final desc = msg['description'] as String? ?? '';
        if (title.isNotEmpty) {
          await _ref.read(tasksProvider.notifier).add(title: title, description: desc);
        }

      case 'delete_task':
        final id = msg['taskId'] as String?;
        if (id != null) await _ref.read(tasksProvider.notifier).delete(id);

      case 'run_task':
        final taskId = msg['taskId'] as String?;
        if (taskId != null) _runTask(taskId);
    }
  }

  void _runTask(String taskId) async {
    final tasks = _ref.read(tasksProvider);
    final task = tasks.where((t) => t.id == taskId).firstOrNull;
    if (task == null) return;

    final config = _ref.read(configProvider);
    await _ref.read(tasksProvider.notifier).cycleStatusTo(taskId, TaskStatus.inProgress);

    final system =
        'You are an autonomous task-completion agent. '
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
      maxIterations: config.agentMaxIterations,
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

  // ── Broadcast helpers ──────────────────────────────────────────────────────

  void broadcastTaskList() {
    broadcast({'type': 'tasks', 'tasks': _taskList()});
  }

  void broadcastTaskUpdated(Task task) {
    broadcast({'type': 'task_updated', 'task': task.toJson()});
  }

  void broadcastTaskDeleted(String id) {
    broadcast({'type': 'task_deleted', 'taskId': id});
  }

  void broadcastAgentEvent(String taskId, AgentEvent event) {
    final Map<String, dynamic>? msg = switch (event) {
      AgentText(:final text) =>
        {'type': 'agent_text', 'taskId': taskId, 'text': text},
      AgentToolStart(:final call) =>
        {'type': 'agent_tool_start', 'taskId': taskId, 'name': call.name,
         'input': call.input.toString()},
      AgentToolDone(:final toolName, :final result) =>
        {'type': 'agent_tool_done', 'taskId': taskId, 'name': toolName, 'result': result},
      AgentCommandOutput(:final line) =>
        {'type': 'agent_command_output', 'taskId': taskId, 'line': line},
      AgentComplete() => {'type': 'agent_complete', 'taskId': taskId},
      AgentError(:final message) =>
        {'type': 'agent_error', 'taskId': taskId, 'message': message},
    };
    if (msg != null) broadcast(msg);
  }

  void broadcast(Map<String, dynamic> msg) {
    final encoded = jsonEncode(msg);
    for (final ws in List.of(_clients)) {
      try {
        ws.add(encoded);
      } catch (_) {
        _clients.remove(ws);
      }
    }
  }

  void _sendTo(WebSocket ws, Map<String, dynamic> msg) {
    try {
      ws.add(jsonEncode(msg));
    } catch (_) {}
  }

  List<Map<String, dynamic>> _taskList() =>
      _ref.read(tasksProvider).map((t) => t.toJson()).toList();
}
