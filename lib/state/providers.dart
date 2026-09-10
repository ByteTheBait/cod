import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../llm/provider.dart';
import '../llm/factory.dart';
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
import 'tab_index.dart';

/// The set of LLM providers the active config defines. Because [providerFor]
/// routes by protocol, this is NOT limited to a hardcoded id list — every
/// configured provider (built-in or user-added) gets an entry, so you can add
/// unlimited providers for each compatible protocol.
final llmRegistryProvider =
    Provider<Map<String, LLMProvider>>((ref) {
  final config = ref.watch(configProvider);
  return {
    for (final p in config.providers.values) p.id: providerFor(p),
  };
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

/// The currently selected bottom-navigation tab index. Exposed so any screen
/// (e.g. Calendar's "Go to Settings") can switch tabs programmatically.
final tabIndexProvider = NotifierProvider<TabIndexNotifier, int>(TabIndexNotifier.new);
