import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import '../models/session.dart';

class SessionsState {
  final List<Session> sessions;
  final String? activeId;

  const SessionsState({this.sessions = const [], this.activeId});

  Session? get active =>
      activeId == null ? null : sessions.where((s) => s.id == activeId).firstOrNull;

  SessionsState copyWith({List<Session>? sessions, String? activeId, bool clearActive = false}) =>
      SessionsState(
        sessions: sessions ?? this.sessions,
        activeId: clearActive ? null : (activeId ?? this.activeId),
      );
}

class SessionsNotifier extends Notifier<SessionsState> {
  @override
  SessionsState build() {
    Future.microtask(_load);
    return const SessionsState();
  }

  Future<Directory> get _dir async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/cod/sessions');
    await d.create(recursive: true);
    return d;
  }

  Future<void> _load() async {
    final dir = await _dir;
    final sessions = <Session>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.json')) {
        try {
          final raw = await e.readAsString();
          sessions.add(Session.fromJson(jsonDecode(raw) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = state.copyWith(sessions: sessions);
  }

  Future<void> _persist(Session s) async {
    final dir = await _dir;
    await File('${dir.path}/${s.id}.json').writeAsString(jsonEncode(s.toJson()));
  }

  Future<Session> create({required String providerId, required String modelId}) async {
    final s = Session(providerId: providerId, modelId: modelId);
    state = state.copyWith(sessions: [s, ...state.sessions], activeId: s.id);
    await _persist(s);
    return s;
  }

  void setActive(String id) => state = state.copyWith(activeId: id);

  void clearActive() => state = state.copyWith(clearActive: true);

  Future<void> addMessage(String sessionId, Message msg) async {
    final sessions = state.sessions.map((s) {
      if (s.id != sessionId) return s;
      s.messages.add(msg);
      s.updatedAt = DateTime.now();
      if (s.title == 'New chat' && msg.role == MessageRole.user) {
        s.title = Session.titleFrom(msg.content);
      }
      return s;
    }).toList();
    state = state.copyWith(sessions: sessions);
    final s = sessions.firstWhere((s) => s.id == sessionId);
    await _persist(s);
  }

  void updateStreaming(String sessionId, String content) {
    final sessions = state.sessions.map((s) {
      if (s.id != sessionId || s.messages.isEmpty) return s;
      s.messages.last.content = content;
      return s;
    }).toList();
    state = state.copyWith(sessions: sessions);
  }

  Future<void> finalizeStreaming(String sessionId) async {
    final sessions = state.sessions.map((s) {
      if (s.id != sessionId || s.messages.isEmpty) return s;
      s.messages.last.isStreaming = false;
      s.updatedAt = DateTime.now();
      return s;
    }).toList();
    state = state.copyWith(sessions: sessions);
    final s = sessions.firstWhere((s) => s.id == sessionId);
    await _persist(s);
  }

  Future<void> delete(String id) async {
    final dir = await _dir;
    final f = File('${dir.path}/$id.json');
    if (await f.exists()) await f.delete();
    final sessions = state.sessions.where((s) => s.id != id).toList();
    final newActive = state.activeId == id ? null : state.activeId;
    state = SessionsState(sessions: sessions, activeId: newActive);
  }

  /// Delete all chat sessions and clear the active selection.
  Future<void> resetAll() async {
    final dir = await _dir;
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.json')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
    state = const SessionsState();
  }
}
