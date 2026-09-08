import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/tool.dart';
import '../services/background_service.dart';
import '../services/sandbox_service.dart';

export '../models/tool.dart' show CodeMode, CodeModeX;
export '../services/sandbox_service.dart' show SandboxType, ContainerStatus;

// ── Entry types (agent conversation) ─────────────────────────────────────────

enum CodeEntryType { user, assistantText, toolCall, toolResult, toolOutput, error }

class CodeEntry {
  final CodeEntryType type;
  final String content;
  final String? label;
  final DateTime timestamp;

  CodeEntry({
    required this.type,
    required this.content,
    this.label,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory CodeEntry.user(String text) =>
      CodeEntry(type: CodeEntryType.user, content: text);
  factory CodeEntry.assistant(String text) =>
      CodeEntry(type: CodeEntryType.assistantText, content: text);
  factory CodeEntry.toolCall(String name, String input) =>
      CodeEntry(type: CodeEntryType.toolCall, content: input, label: name);
  factory CodeEntry.toolResult(String name, String result) =>
      CodeEntry(type: CodeEntryType.toolResult, content: result, label: name);
  factory CodeEntry.toolOutput(String name, String output) =>
      CodeEntry(type: CodeEntryType.toolOutput, content: output, label: name);
  factory CodeEntry.error(String msg) =>
      CodeEntry(type: CodeEntryType.error, content: msg);

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'content': content,
        if (label != null) 'label': label,
        'ts': timestamp.millisecondsSinceEpoch,
      };

  factory CodeEntry.fromJson(Map<String, dynamic> j) => CodeEntry(
        type: CodeEntryType.values.firstWhere(
            (e) => e.name == (j['type'] as String),
            orElse: () => CodeEntryType.assistantText),
        content: j['content'] as String,
        label: j['label'] as String?,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
      );
}

// ── Open file tab ─────────────────────────────────────────────────────────────

class CodeFile {
  final String path;
  final String name;
  final String content;

  const CodeFile({required this.path, required this.name, required this.content});
}

// ── Code workspace (a tabbed code session) ────────────────────────────────────

/// A single code "tab" in the Code screen. Each workspace has its own working
/// directory, conversation, open files, and sessions. This lets you run
/// multiple independent code agents in one app.
class CodeWorkspace {
  final String id;
  final String title;
  final String workingDir;
  final List<CodeEntry> entries;
  final List<Map<String, dynamic>> history;
  final List<CodeFile> openFiles;
  final int? activeFileIndex;
  final List<CodeSession> sessions;
  final String? activeSessionId;
  final String? subAgentId;
  final CodeMode mode;
  final int estimatedTokens;

  const CodeWorkspace({
    required this.id,
    required this.title,
    this.workingDir = '',
    this.entries = const [],
    this.history = const [],
    this.openFiles = const [],
    this.activeFileIndex,
    this.sessions = const [],
    this.activeSessionId,
    this.subAgentId,
    this.mode = CodeMode.yolo,
    this.estimatedTokens = 0,
  });

  CodeWorkspace copyWith({
    String? title,
    String? workingDir,
    List<CodeEntry>? entries,
    List<Map<String, dynamic>>? history,
    List<CodeFile>? openFiles,
    Object? activeFileIndex = _unset,
    List<CodeSession>? sessions,
    Object? activeSessionId = _unset,
    Object? subAgentId = _unset,
    CodeMode? mode,
    int? estimatedTokens,
  }) =>
      CodeWorkspace(
        id: id,
        title: title ?? this.title,
        workingDir: workingDir ?? this.workingDir,
        entries: entries ?? this.entries,
        history: history ?? this.history,
        openFiles: openFiles ?? this.openFiles,
        activeFileIndex: identical(activeFileIndex, _unset)
            ? this.activeFileIndex
            : activeFileIndex as int?,
        sessions: sessions ?? this.sessions,
        activeSessionId: identical(activeSessionId, _unset)
            ? this.activeSessionId
            : activeSessionId as String?,
        subAgentId: identical(subAgentId, _unset)
            ? this.subAgentId
            : subAgentId as String?,
        mode: mode ?? this.mode,
        estimatedTokens: estimatedTokens ?? this.estimatedTokens,
      );
}

// ── Code session (a saved agent conversation for a working dir) ───────────────

class CodeSession {
  final String id;
  final String title;
  final DateTime updatedAt;
  final List<CodeEntry> entries;
  final List<Map<String, dynamic>> history;

  const CodeSession({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.entries,
    required this.history,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(),
        'history': history,
      };

  factory CodeSession.fromJson(Map<String, dynamic> j) => CodeSession(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Session',
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ??
            DateTime.now(),
        entries: (j['entries'] as List? ?? [])
            .map((e) => CodeEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        history: (j['history'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            [],
      );
}

// Sentinel so copyWith can distinguish "set to null" from "leave unchanged"
const _unset = Object();

// ── State ─────────────────────────────────────────────────────────────────────

class CodeState {
  final String workingDir;
  final List<CodeEntry> entries;
  final List<Map<String, dynamic>> history; // LLM message history for multi-turn
  final bool isRunning;
  final CodeMode mode; // agent behavioural mode
  final String? subAgentId; // active subagent, null = full agent
  // Sandbox
  final SandboxType? sandboxType;
  final SandboxType? requestedSandboxType;
  final ContainerStatus containerStatus;
  final String sandboxImage;
  final String? sandboxError;
  // File tabs — null activeFileIndex = Agent tab
  final List<CodeFile> openFiles;
  final int? activeFileIndex;
  // Session history for the current working dir
  final List<CodeSession> sessions;
  final String? activeSessionId;
  // Recently opened folders (most recent first), for quick switching.
  final List<String> recentFolders;
  // Estimated token count of the current conversation history.
  final int estimatedTokens;
  // Multiple code workspaces (tabs). The active workspace's state is mirrored
  // in the fields above; the rest live here.
  final List<CodeWorkspace> workspaces;
  final String? activeWorkspaceId;

  const CodeState({
    this.workingDir = '',
    this.entries = const [],
    this.history = const [],
    this.isRunning = false,
    this.mode = CodeMode.yolo,
    this.subAgentId,
    this.sandboxType,
    this.requestedSandboxType,
    this.containerStatus = ContainerStatus.idle,
    this.sandboxImage = 'ubuntu:24.04',
    this.sandboxError,
    this.openFiles = const [],
    this.activeFileIndex,
    this.sessions = const [],
    this.activeSessionId,
    this.recentFolders = const [],
    this.estimatedTokens = 0,
    this.workspaces = const [],
    this.activeWorkspaceId,
  });

  CodeState copyWith({
    String? workingDir,
    List<CodeEntry>? entries,
    List<Map<String, dynamic>>? history,
    bool? isRunning,
    CodeMode? mode,
    Object? subAgentId = _unset,
    Object? sandboxType = _unset,
    SandboxType? requestedSandboxType,
    ContainerStatus? containerStatus,
    String? sandboxImage,
    String? sandboxError,
    bool clearSandboxError = false,
    List<CodeFile>? openFiles,
    Object? activeFileIndex = _unset,
    List<CodeSession>? sessions,
    Object? activeSessionId = _unset,
    List<String>? recentFolders,
    int? estimatedTokens,
    List<CodeWorkspace>? workspaces,
    Object? activeWorkspaceId = _unset,
  }) =>
      CodeState(
        workingDir: workingDir ?? this.workingDir,
        entries: entries ?? this.entries,
        history: history ?? this.history,
        isRunning: isRunning ?? this.isRunning,
        mode: mode ?? this.mode,
        subAgentId: identical(subAgentId, _unset)
            ? this.subAgentId
            : subAgentId as String?,
        sandboxType: identical(sandboxType, _unset)
            ? this.sandboxType
            : sandboxType as SandboxType?,
        requestedSandboxType: requestedSandboxType ?? this.requestedSandboxType,
        containerStatus: containerStatus ?? this.containerStatus,
        sandboxImage: sandboxImage ?? this.sandboxImage,
        sandboxError: clearSandboxError ? null : (sandboxError ?? this.sandboxError),
        openFiles: openFiles ?? this.openFiles,
        activeFileIndex: identical(activeFileIndex, _unset)
            ? this.activeFileIndex
            : activeFileIndex as int?,
        sessions: sessions ?? this.sessions,
        activeSessionId: identical(activeSessionId, _unset)
            ? this.activeSessionId
            : activeSessionId as String?,
        recentFolders: recentFolders ?? this.recentFolders,
        estimatedTokens: estimatedTokens ?? this.estimatedTokens,
        workspaces: workspaces ?? this.workspaces,
        activeWorkspaceId: identical(activeWorkspaceId, _unset)
            ? this.activeWorkspaceId
            : activeWorkspaceId as String?,
      );
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class CodeNotifier extends Notifier<CodeState> {
  final _sandbox = SandboxService();

  @override
  CodeState build() {
    ref.onDispose(() {
      _sandbox.dispose();
      BackgroundProcessManager.instance.dispose();
    });
    Future.microtask(_detectSandbox);
    Future.microtask(_loadRecentFolders);
    return const CodeState();
  }

  bool get canUseDocker => _sandbox.canUseDocker;

  Future<void> _detectSandbox() async {
    final type = await _sandbox.detect();
    
    // If user requested a specific type, check if it's compatible
    final requestedType = state.requestedSandboxType;
    if (requestedType != null) {
      if (requestedType == SandboxType.docker && type == SandboxType.restricted) {
        // Requested docker but not available, fall back to restricted
        state = state.copyWith(
          sandboxType: SandboxType.restricted,
        );
      } else {
        // Use requested type or detected type
        state = state.copyWith(
          sandboxType: requestedType == SandboxType.docker ? type : requestedType,
        );
      }
    } else {
      state = state.copyWith(sandboxType: type);
    }
  }

  Future<void> setSandboxType(SandboxType? type) async {
    if (type == state.requestedSandboxType) return;
    
    // If switching to restricted, always works
    // If switching to docker, check if available
    if (type == SandboxType.docker && _sandbox.type == SandboxType.restricted) {
      // Docker not available
      return;
    }
    
    state = state.copyWith(
      requestedSandboxType: type,
    );
    
    // Restart sandbox with new type if working dir is set
    if (state.workingDir.isNotEmpty) {
      await restartSandbox();
    }
  }

  void setSandboxTypeSync(SandboxType? type) {
    if (type == state.requestedSandboxType) return;
    
    // Check if requested type is available
    if (type == SandboxType.docker && _sandbox.type == SandboxType.restricted) {
      return; // Docker not available
    }
    
    state = state.copyWith(
      requestedSandboxType: type,
    );
    
    // Restart sandbox with new type if working dir is set
    if (state.workingDir.isNotEmpty) {
      restartSandbox();
    }
  }

  Future<void> restartSandbox() {
    return _setWorkingDir(state.workingDir);
  }

  Future<String> Function(String) get commandRunner =>
      (cmd) => _sandbox.exec(cmd,
          workingDir: state.workingDir.isNotEmpty ? state.workingDir : null);

  Stream<String> Function(String) get commandStreamRunner =>
      (cmd) => _sandbox.execStream(cmd,
          workingDir: state.workingDir.isNotEmpty ? state.workingDir : null);

  // ── Persistence ────────────────────────────────────────────────────────────

  Future<File> _sessionFile(String dir) async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/cod/code_sessions');
    await d.create(recursive: true);
    final key = dir.replaceAll('/', '_').replaceAll(' ', '_');
    return File('${d.path}/$key.json');
  }

  Future<void> _save() async {
    final dir = state.workingDir;
    if (dir.isEmpty) return;
    try {
      // Update the active session with the current entries/history.
      final sessions = state.sessions.map((s) {
        if (s.id != state.activeSessionId) return s;
        return CodeSession(
          id: s.id,
          title: s.title,
          updatedAt: DateTime.now(),
          entries: state.entries,
          history: state.history,
        );
      }).toList();
      final f = await _sessionFile(dir);
      await f.writeAsString(jsonEncode(sessions.map((s) => s.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> _loadSession(String dir) async {
    try {
      final f = await _sessionFile(dir);
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is List) {
        // New format — list of CodeSession objects.
        final sessions = raw
            .map((e) => CodeSession.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        if (sessions.isEmpty) return;
        final active = sessions.first;
        state = state.copyWith(
          sessions: sessions,
          activeSessionId: active.id,
          entries: active.entries,
          history: active.history,
        );
      } else if (raw is Map) {
        // Legacy format — a single session object.
        final entries = (raw['entries'] as List)
            .map((e) => CodeEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        final history = (raw['history'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            [];
        final session = CodeSession(
          id: 'legacy',
          title: 'Session',
          updatedAt: DateTime.now(),
          entries: entries,
          history: history,
        );
        state = state.copyWith(
          sessions: [session],
          activeSessionId: session.id,
          entries: entries,
          history: history,
        );
      }
    } catch (_) {}
  }

  // ── Session management ─────────────────────────────────────────────────────

  /// Start a fresh session for the current working dir, saving the current one.
  Future<void> newSession() async {
    if (state.workingDir.isEmpty) return;
    await _save();
    final session = CodeSession(
      id: const Uuid().v4(),
      title: 'Session ${state.sessions.length + 1}',
      updatedAt: DateTime.now(),
      entries: const [],
      history: const [],
    );
    state = state.copyWith(
      sessions: [session, ...state.sessions],
      activeSessionId: session.id,
      entries: const [],
      history: const [],
      openFiles: const [],
      activeFileIndex: null,
    );
    await _save();
  }

  /// Switch to an existing session for the current working dir.
  Future<void> switchSession(String id) async {
    final session = state.sessions.where((s) => s.id == id).firstOrNull;
    if (session == null) return;
    await _save();
    state = state.copyWith(
      activeSessionId: session.id,
      entries: session.entries,
      history: session.history,
      openFiles: const [],
      activeFileIndex: null,
    );
  }

  /// Delete a session (and its persisted file entry).
  Future<void> deleteSession(String id) async {
    final sessions = state.sessions.where((s) => s.id != id).toList();
    final wasActive = state.activeSessionId == id;
    final nextActive = wasActive
        ? (sessions.isNotEmpty ? sessions.first.id : null)
        : state.activeSessionId;
    state = state.copyWith(
      sessions: sessions,
      activeSessionId: nextActive,
      entries: wasActive
          ? (sessions.isNotEmpty ? sessions.first.entries : const [])
          : state.entries,
      history: wasActive
          ? (sessions.isNotEmpty ? sessions.first.history : const [])
          : state.history,
    );
    await _save();
  }

  // ── Agent conversation ─────────────────────────────────────────────────────

  void addEntry(CodeEntry entry) =>
      state = state.copyWith(entries: [...state.entries, entry]);

  void appendCommandOutput(String line) {
    final entries = state.entries;
    if (entries.isNotEmpty && entries.last.type == CodeEntryType.toolOutput) {
      final last = entries.last;
      final updated = CodeEntry(
        type: CodeEntryType.toolOutput,
        content: '${last.content}\n$line',
        label: last.label,
        timestamp: last.timestamp,
      );
      state = state.copyWith(
          entries: [...entries.sublist(0, entries.length - 1), updated]);
    } else {
      state = state.copyWith(
          entries: [...entries, CodeEntry.toolOutput('run_command', line)]);
    }
  }

  void finalizeCommandOutput(String toolName, String result) {
    final entries = state.entries;
    if (entries.isNotEmpty && entries.last.type == CodeEntryType.toolOutput) {
      final updated = CodeEntry.toolResult(toolName, result);
      state = state.copyWith(
          entries: [...entries.sublist(0, entries.length - 1), updated]);
    } else {
      state = state.copyWith(
          entries: [...entries, CodeEntry.toolResult(toolName, result)]);
    }
  }

  void setRunning(bool v) {
    state = state.copyWith(isRunning: v);
    if (!v) _save();
  }

  void setMode(CodeMode mode) {
    if (mode == state.mode) return;
    state = state.copyWith(mode: mode);
  }

  /// Set the active subagent. Pass null to use the full agent.
  void setSubAgent(String? id) {
    if (id == state.subAgentId) return;
    state = state.copyWith(subAgentId: id);
    _syncActiveWorkspace();
  }

  // ── Workspaces (tabbed code) ────────────────────────────────────────────────

  /// Snapshot the current active workspace's state into the workspaces list.
  void _syncActiveWorkspace() {
    final id = state.activeWorkspaceId;
    if (id == null) return;
    final ws = CodeWorkspace(
      id: id,
      title: _workspaceTitle(id),
      workingDir: state.workingDir,
      entries: state.entries,
      history: state.history,
      openFiles: state.openFiles,
      activeFileIndex: state.activeFileIndex,
      sessions: state.sessions,
      activeSessionId: state.activeSessionId,
      subAgentId: state.subAgentId,
      mode: state.mode,
      estimatedTokens: state.estimatedTokens,
    );
    state = state.copyWith(
      workspaces: [
        for (final w in state.workspaces) w.id == id ? ws : w,
      ],
    );
  }

  String _workspaceTitle(String id) {
    for (final w in state.workspaces) {
      if (w.id == id) return w.title;
    }
    return 'Code';
  }

  /// Create a new empty workspace and switch to it.
  void newWorkspace() {
    // If there's no active workspace yet but the current view has content
    // (e.g. a folder was opened before any tab was created), capture it as
    // the first workspace so it isn't lost when we switch to the new tab.
    if (state.activeWorkspaceId == null) {
      final firstId = const Uuid().v4();
      final first = CodeWorkspace(
        id: firstId,
        title: 'Code 1',
        workingDir: state.workingDir,
        entries: state.entries,
        history: state.history,
        openFiles: state.openFiles,
        activeFileIndex: state.activeFileIndex,
        sessions: state.sessions,
        activeSessionId: state.activeSessionId,
        subAgentId: state.subAgentId,
        mode: state.mode,
        estimatedTokens: state.estimatedTokens,
      );
      state = state.copyWith(
        workspaces: [first],
        activeWorkspaceId: firstId,
      );
    } else {
      _syncActiveWorkspace();
    }

    final id = const Uuid().v4();
    final ws = CodeWorkspace(id: id, title: 'Code ${state.workspaces.length + 1}');
    state = state.copyWith(
      workspaces: [...state.workspaces, ws],
      activeWorkspaceId: id,
      workingDir: '',
      entries: const [],
      history: const [],
      openFiles: const [],
      activeFileIndex: null,
      sessions: const [],
      activeSessionId: null,
      subAgentId: null,
      estimatedTokens: 0,
      clearSandboxError: true,
      containerStatus: ContainerStatus.idle,
    );
  }

  /// Switch to an existing workspace, restoring its state.
  void switchWorkspace(String id) {
    final ws = state.workspaces.where((w) => w.id == id).firstOrNull;
    if (ws == null || ws.id == state.activeWorkspaceId) return;
    _syncActiveWorkspace();
    state = state.copyWith(
      activeWorkspaceId: id,
      workingDir: ws.workingDir,
      entries: ws.entries,
      history: ws.history,
      openFiles: ws.openFiles,
      activeFileIndex: ws.activeFileIndex,
      sessions: ws.sessions,
      activeSessionId: ws.activeSessionId,
      subAgentId: ws.subAgentId,
      mode: ws.mode,
      estimatedTokens: ws.estimatedTokens,
      clearSandboxError: true,
      containerStatus: ContainerStatus.idle,
    );
    // Restart the sandbox for the new workspace's directory without touching
    // the restored conversation state.
    if (ws.workingDir.isNotEmpty) {
      _startSandboxFor(ws.workingDir);
    }
  }

  /// Close a workspace. If it's the active one, switch to another.
  void closeWorkspace(String id) {
    final remaining = state.workspaces.where((w) => w.id != id).toList();
    if (remaining.isEmpty) {
      // Closing the last workspace resets to a fresh one.
      state = state.copyWith(
        workspaces: const [],
        activeWorkspaceId: null,
        workingDir: '',
        entries: const [],
        history: const [],
        openFiles: const [],
        activeFileIndex: null,
        sessions: const [],
        activeSessionId: null,
        subAgentId: null,
        estimatedTokens: 0,
        clearSandboxError: true,
        containerStatus: ContainerStatus.idle,
      );
      return;
    }
    if (state.activeWorkspaceId == id) {
      final next = remaining.first;
      state = state.copyWith(
        workspaces: remaining,
        activeWorkspaceId: next.id,
        workingDir: next.workingDir,
        entries: next.entries,
        history: next.history,
        openFiles: next.openFiles,
        activeFileIndex: next.activeFileIndex,
        sessions: next.sessions,
        activeSessionId: next.activeSessionId,
        subAgentId: next.subAgentId,
        mode: next.mode,
        estimatedTokens: next.estimatedTokens,
        clearSandboxError: true,
        containerStatus: ContainerStatus.idle,
      );
      if (next.workingDir.isNotEmpty) _startSandboxFor(next.workingDir);
    } else {
      state = state.copyWith(workspaces: remaining);
    }
  }

  void updateHistory(List<Map<String, dynamic>> messages) {
    state = state.copyWith(
      history: messages,
      estimatedTokens: _estimateTokens(messages),
    );
  }

  /// Rough token estimate for a message list (≈4 chars per token).
  int _estimateTokens(List<Map<String, dynamic>> messages) {
    var chars = 0;
    for (final m in messages) {
      final content = m['content'];
      if (content is String) {
        chars += content.length;
      } else if (content is List) {
        for (final block in content) {
          final b = block as Map<String, dynamic>;
          final text = b['text'] as String?;
          if (text != null) chars += text.length;
          final input = b['input'];
          if (input is Map) chars += jsonEncode(input).length;
        }
      }
    }
    return (chars / 4).round();
  }

  /// Compact the conversation history by keeping only the most recent
  /// [keepMessages] messages (plus the first system/user prompt). This trims
  /// the context window when it grows too large.
  void compactHistory({int keepMessages = 12}) {
    final history = state.history;
    if (history.length <= keepMessages) return;
    // Keep the first message (usually the initial prompt) plus the last N.
    final first = history.first;
    final tail = history.sublist(history.length - keepMessages);
    final compacted = [first, ...tail];
    state = state.copyWith(
      history: compacted,
      estimatedTokens: _estimateTokens(compacted),
    );
    // Also trim the visible entries to match (keep the last ~2x messages).
    final entries = state.entries;
    if (entries.length > keepMessages * 2) {
      state = state.copyWith(
        entries: entries.sublist(entries.length - keepMessages * 2),
      );
    }
    _save();
  }

  Future<void> clearConversation() async {
    state = state.copyWith(entries: [], history: []);
    await _save();
  }

  static const _prefRecentFolders = 'recent_folders';
  static const _maxRecentFolders = 8;

  Future<void> setWorkingDir(String dir) => _setWorkingDir(dir);

  /// Set the working directory from a raw path string (e.g. pasted or from a
  /// CLI arg). Expands `~`, resolves relative paths against the current dir,
  /// and validates the directory exists. Returns the resolved path, or null
  /// if it couldn't be resolved.
  Future<String?> setWorkingDirFromPath(String raw) async {
    var path = raw.trim();
    if (path.isEmpty) return null;
    if (path == '~') {
      path = Platform.environment['HOME'] ?? path;
    } else if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'];
      if (home != null) path = '$home${path.substring(1)}';
    }
    if (!path.startsWith('/')) {
      // Resolve relative to the current working dir, or the process cwd.
      final base = state.workingDir.isNotEmpty
          ? state.workingDir
          : Directory.current.path;
      path = '$base/$path';
    }
    final dir = Directory(path);
    if (!await dir.exists()) return null;
    await _setWorkingDir(dir.absolute.path);
    return dir.absolute.path;
  }

  /// Load recently opened folders from disk.
  Future<void> _loadRecentFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_prefRecentFolders) ?? const [];
      state = state.copyWith(recentFolders: list);
    } catch (_) {}
  }

  Future<void> _persistRecentFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefRecentFolders, state.recentFolders);
    } catch (_) {}
  }

  /// Remove a folder from the recent list (does not change the working dir).
  Future<void> removeRecentFolder(String dir) async {
    state = state.copyWith(
        recentFolders: state.recentFolders.where((d) => d != dir).toList());
    await _persistRecentFolders();
  }

  Future<void> _setWorkingDir(String dir) async {
    if (_sandbox.status == ContainerStatus.running) await _sandbox.stop();
    // Record the folder in the recent list (most recent first, deduped).
    final recent = [
      dir,
      ...state.recentFolders.where((d) => d != dir),
    ].take(_maxRecentFolders).toList();
    state = state.copyWith(
      workingDir: dir,
      entries: [],
      history: [],
      openFiles: [],
      activeFileIndex: null,
      sessions: const [],
      activeSessionId: null,
      recentFolders: recent,
      clearSandboxError: true,
      containerStatus: ContainerStatus.idle,
    );
    await _persistRecentFolders();
    if (dir.isEmpty) return;
    await _loadSession(dir);
    await _startSandboxFor(dir);
  }

  /// Start (or restart) the sandbox for [dir] without touching the
  /// conversation state. Used when switching between workspaces so the
  /// restored entries/history are preserved.
  Future<void> _startSandboxFor(String dir) async {
    state = state.copyWith(containerStatus: ContainerStatus.starting);
    try {
      final desiredMode = state.requestedSandboxType ?? state.sandboxType ?? SandboxType.restricted;
      _sandbox.setMode(desiredMode);
      await _sandbox.start(workingDir: dir, image: state.sandboxImage);
      state = state.copyWith(containerStatus: ContainerStatus.running);
    } catch (e) {
      state = state.copyWith(
        containerStatus: ContainerStatus.error,
        sandboxError: e.toString(),
      );
    }
  }

  // ── File tabs ──────────────────────────────────────────────────────────────

  Future<void> openFile(String path) async {
    // Switch to existing tab if already open
    final existing = state.openFiles.indexWhere((f) => f.path == path);
    if (existing >= 0) {
      state = state.copyWith(activeFileIndex: existing);
      return;
    }

    final file = File(path);
    if (!await file.exists()) return;

    String content;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > 512 * 1024) {
        content = '(File too large to display inline — ${bytes.length ~/ 1024} KB)';
      } else {
        content = utf8.decode(bytes, allowMalformed: true);
      }
    } catch (e) {
      content = 'Error reading file: $e';
    }

    final name = path.split('/').last;
    final files = [...state.openFiles, CodeFile(path: path, name: name, content: content)];
    state = state.copyWith(openFiles: files, activeFileIndex: files.length - 1);
  }

  void closeFile(int index) {
    final files = List<CodeFile>.from(state.openFiles)..removeAt(index);
    int? newIndex = state.activeFileIndex;
    if (newIndex != null) {
      if (newIndex > index) newIndex = newIndex - 1;
      if (newIndex >= files.length) newIndex = files.isEmpty ? null : files.length - 1;
      if (newIndex == index && files.isNotEmpty) newIndex = (index - 1).clamp(0, files.length - 1);
    }
    state = state.copyWith(openFiles: files, activeFileIndex: newIndex);
  }

  /// Save edited content back to disk and update the open file tab.
  /// Returns an error string, or null on success.
  Future<String?> saveFile(String path, String content) async {
    final file = File(path);
    try {
      await file.writeAsString(content);
    } catch (e) {
      return 'Could not save: $e';
    }
    // Update the open file tab's content.
    state = state.copyWith(
      openFiles: [
        for (final f in state.openFiles)
          f.path == path
              ? CodeFile(path: f.path, name: f.name, content: content)
              : f,
      ],
    );
    return null;
  }

  void showAgentTab() => state = state.copyWith(activeFileIndex: null);

  void showFileTab(int index) => state = state.copyWith(activeFileIndex: index);
}


