import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../llm/provider.dart';
import '../llm/claude.dart';
import '../llm/gemini.dart';
import '../llm/groq.dart';
import '../llm/ollama.dart';
import '../llm/custom.dart';
import '../models/config.dart';
import '../models/task.dart';
import '../services/minnow_sync.dart';
import 'sessions.dart';
import 'tasks.dart';
import 'config.dart';
import 'email.dart';
import 'code.dart';
import 'calendar.dart';
import 'update.dart';

final llmRegistryProvider = Provider<Map<String, LLMProvider>>((_) => {
      'claude': ClaudeProvider(),
      'gemini': GeminiProvider(),
      'groq': GroqProvider(),
      'ollama': OllamaProvider(),
      'custom': CustomProvider(),
    });

final sessionsProvider =
    NotifierProvider<SessionsNotifier, SessionsState>(SessionsNotifier.new);

final tasksProvider =
    NotifierProvider<TasksNotifier, List<Task>>(TasksNotifier.new);

final configProvider =
    NotifierProvider<ConfigNotifier, AppConfig>(ConfigNotifier.new);

final emailProvider =
    NotifierProvider<EmailNotifier, EmailState>(EmailNotifier.new);

final codeProvider =
    NotifierProvider<CodeNotifier, CodeState>(CodeNotifier.new);

final calendarProvider =
    NotifierProvider<CalendarNotifier, CalendarState>(CalendarNotifier.new);

final updateProvider =
    NotifierProvider<UpdateNotifier, UpdateState>(UpdateNotifier.new);

final minnowSyncProvider = Provider<MinnowSync>((ref) {
  final sync = MinnowSync(ref);
  ref.onDispose(sync.dispose);
  return sync;
});
