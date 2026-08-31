import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/calendar_model.dart';
import '../models/config.dart';
import '../models/message.dart';
import '../llm/provider.dart';
import '../services/gcal_service.dart';
import '../services/gmail_service.dart';
import 'providers.dart';

class CalendarState {
  final bool connected;
  final bool loadingEvents;
  final bool loadingSuggestions;
  final List<CalendarEvent> events;
  final List<CalendarSuggestion> suggestions;
  final DateTime focusedDay;
  final DateTime selectedDay;
  // Chat
  final List<Message> chatMessages;
  final bool chatStreaming;
  final String? error;

  CalendarState({
    this.connected = false,
    this.loadingEvents = false,
    this.loadingSuggestions = false,
    this.events = const [],
    this.suggestions = const [],
    DateTime? focusedDay,
    DateTime? selectedDay,
    this.chatMessages = const [],
    this.chatStreaming = false,
    this.error,
  })  : focusedDay = focusedDay ?? DateTime.now(),
        selectedDay = selectedDay ?? DateTime.now();

  List<CalendarEvent> eventsForDay(DateTime day) => events
      .where((e) =>
          e.start.year == day.year &&
          e.start.month == day.month &&
          e.start.day == day.day)
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  CalendarState copyWith({
    bool? connected,
    bool? loadingEvents,
    bool? loadingSuggestions,
    List<CalendarEvent>? events,
    List<CalendarSuggestion>? suggestions,
    DateTime? focusedDay,
    DateTime? selectedDay,
    List<Message>? chatMessages,
    bool? chatStreaming,
    String? error,
    bool clearError = false,
  }) =>
      CalendarState(
        connected: connected ?? this.connected,
        loadingEvents: loadingEvents ?? this.loadingEvents,
        loadingSuggestions: loadingSuggestions ?? this.loadingSuggestions,
        events: events ?? this.events,
        suggestions: suggestions ?? this.suggestions,
        focusedDay: focusedDay ?? this.focusedDay,
        selectedDay: selectedDay ?? this.selectedDay,
        chatMessages: chatMessages ?? this.chatMessages,
        chatStreaming: chatStreaming ?? this.chatStreaming,
        error: clearError ? null : (error ?? this.error),
      );
}

class CalendarNotifier extends Notifier<CalendarState> {
  @override
  CalendarState build() {
    Future.microtask(_init);
    return CalendarState();
  }

  Future<void> _init() async {
    final connected = await GmailService.instance.isConnected;
    state = state.copyWith(connected: connected);
    if (connected) await loadEvents();
  }

  Future<void> loadEvents() async {
    state = state.copyWith(loadingEvents: true, clearError: true);
    try {
      final events = await GCalService.instance.listEvents();
      state = state.copyWith(events: events, loadingEvents: false);
    } catch (e) {
      state = state.copyWith(loadingEvents: false, error: e.toString());
    }
  }

  void setDay(DateTime focused, DateTime selected) => state =
      state.copyWith(focusedDay: focused, selectedDay: selected);

  Future<void> addEvent(CalendarEvent event) async {
    final created = await GCalService.instance.createEvent(event);
    state = state.copyWith(events: [...state.events, created]);
  }

  Future<void> deleteEvent(String id) async {
    await GCalService.instance.deleteEvent(id);
    state = state.copyWith(
        events: state.events.where((e) => e.id != id).toList());
  }

  void markConnected() {
    state = state.copyWith(connected: true);
    loadEvents();
  }

  // ── Suggestions ────────────────────────────────────────────────────────────

  Future<void> refreshSuggestions() async {
    if (!state.connected) return;
    state = state.copyWith(loadingSuggestions: true);
    final config = ref.read(configProvider);
    final registry = ref.read(llmRegistryProvider);
    final provider = registry[config.activeProviderId] ?? registry.values.first;
    try {
      final upcoming = state.events
          .where((e) => e.start.isAfter(DateTime.now()))
          .take(10)
          .map((e) => '${e.timeLabel}  ${e.title}')
          .join('\n');

      List<String> emailSnippets = [];
      try {
        final threads = await GmailService.instance.listThreads(maxResults: 8);
        for (final t in threads.take(6)) {
          if (t.subject.isNotEmpty) emailSnippets.add(t.subject);
        }
      } catch (_) {}

      final prompt = '''
You are a calendar assistant. Analyse these upcoming events and recent email subjects, then return a JSON array of 3–5 suggestions.

Upcoming events (next 60 days):
${upcoming.isEmpty ? 'None' : upcoming}

Recent email subjects:
${emailSnippets.isEmpty ? 'None' : emailSnippets.join('\n')}

Return ONLY a raw JSON array (no markdown fences), each item has:
  "title": short action phrase
  "detail": one-sentence explanation
  "type": one of "info", "add", "reply"
  "event": (optional, only for type "add") object with "title", "start" (ISO8601), "end" (ISO8601)
''';

      final raw = await provider.complete(
        config: config,
        prompt: prompt,
        maxTokens: 1024,
        model: config.modelFor(Feature.calendar),
      );
      final cleaned = raw
          .replaceAll(RegExp(r'```json\s*'), '')
          .replaceAll(RegExp(r'```\s*'), '')
          .trim();
      final list = jsonDecode(cleaned) as List<dynamic>;
      final suggestions = list
          .map((e) => CalendarSuggestion.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(suggestions: suggestions, loadingSuggestions: false);
    } catch (e) {
      state = state.copyWith(loadingSuggestions: false, error: e.toString());
    }
  }

  // ── Calendar chat ──────────────────────────────────────────────────────────

  Future<void> sendChatMessage(String text) async {
    if (text.isEmpty || state.chatStreaming) return;
    final config = ref.read(configProvider);
    final registry = ref.read(llmRegistryProvider);
    final provider = registry[config.activeProviderId] ?? registry.values.first;

    final userMsg = Message.user(text);
    state = state.copyWith(chatMessages: [...state.chatMessages, userMsg]);

    final upcomingEvents = state.events
        .where((e) => e.start.isAfter(DateTime.now()))
        .take(20)
        .map((e) => '${e.start.toIso8601String().substring(0, 16)}  ${e.title}')
        .join('\n');

    final systemPrompt = 'You are a helpful calendar assistant. '
        "The user's upcoming events:\n$upcomingEvents\n\n"
        'Answer concisely. If suggesting a new event, describe it clearly.';

    final placeholder = Message.assistant('', isStreaming: true);
    state = state.copyWith(
      chatMessages: [...state.chatMessages, placeholder],
      chatStreaming: true,
    );

    String accumulated = '';
    try {
      final history = state.chatMessages
          .where((m) => !m.isStreaming)
          .map((m) => Message(role: m.role, content: m.content))
          .toList();

      await for (final chunk in provider.stream(
        messages: [
          Message(role: MessageRole.system, content: systemPrompt),
          ...history,
        ],
        model: config.modelFor(Feature.calendar),
        apiKey: config.active.apiKey,
        baseUrl: config.active.baseUrl,
        maxTokens: 1024,
      )) {
        accumulated += chunk;
        final msgs = List<Message>.from(state.chatMessages);
        msgs[msgs.length - 1] = Message.assistant(accumulated, isStreaming: true);
        state = state.copyWith(chatMessages: msgs);
      }
    } catch (e) {
      accumulated = '_Error: ${e}_';
    }

    final msgs = List<Message>.from(state.chatMessages);
    msgs[msgs.length - 1] = Message.assistant(accumulated);
    state = state.copyWith(chatMessages: msgs, chatStreaming: false);
  }
}
