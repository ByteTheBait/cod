import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../services/sandbox_service.dart';

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

  const CodeState({
    this.workingDir = '',
    this.entries = const [],
    this.history = const [],
    this.isRunning = false,
    this.sandboxType,
    this.requestedSandboxType,
    this.containerStatus = ContainerStatus.idle,
    this.sandboxImage = 'ubuntu:24.04',
    this.sandboxError,
    this.openFiles = const [],
    this.activeFileIndex,
    this.sessions = const [],
    this.activeSessionId,
  });

  CodeState copyWith({
    String? workingDir,
    List<CodeEntry>? entries,
    List<Map<String, dynamic>>? history,
    bool? isRunning,
    SandboxType? sandboxType,
    SandboxType? requestedSandboxType,
    ContainerStatus? containerStatus,
    String? sandboxImage,
    String? sandboxError,
    bool clearSandboxError = false,
    List<CodeFile>? openFiles,
    Object? activeFileIndex = _unset,
    List<CodeSession>? sessions,
    Object? activeSessionId = _unset,
  }) =>
      CodeState(
        workingDir: workingDir ?? this.workingDir,
        entries: entries ?? this.entries,
        history: history ?? this.history,
        isRunning: isRunning ?? this.isRunning,
        sandboxType: sandboxType ?? this.sandboxType,
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
      );
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class CodeNotifier extends Notifier<CodeState> {
  final _sandbox = SandboxService();

  @override
  CodeState build() {
    ref.onDispose(() => _sandbox.dispose());
    Future.microtask(_detectSandbox);
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

  void updateHistory(List<Map<String, dynamic>> messages) {
    state = state.copyWith(history: messages);
  }

  Future<void> clearConversation() async {
    state = state.copyWith(entries: [], history: []);
    await _save();
  }

  Future<void> setWorkingDir(String dir) => _setWorkingDir(dir);

  Future<void> _setWorkingDir(String dir) async {
    if (_sandbox.status == ContainerStatus.running) await _sandbox.stop();
    state = state.copyWith(
      workingDir: dir,
      entries: [],
      history: [],
      openFiles: [],
      activeFileIndex: null,
      sessions: const [],
      activeSessionId: null,
      clearSandboxError: true,
      containerStatus: ContainerStatus.idle,
    );
    if (dir.isEmpty) return;
    await _loadSession(dir);

    state = state.copyWith(containerStatus: ContainerStatus.starting);
    try {
      // Set the sandbox mode based on user request or detection
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

  void showAgentTab() => state = state.copyWith(activeFileIndex: null);

  void showFileTab(int index) => state = state.copyWith(activeFileIndex: index);
}


