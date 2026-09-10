import 'package:flutter/material.dart';
import 'command.dart';
import 'subagent.dart';

/// The distinct AI features in the app. Each can use a different model from
/// the same active provider.
enum Feature { chat, email, calendar, code, tasks }

extension FeatureX on Feature {
  String get label => switch (this) {
        Feature.chat => 'Chat',
        Feature.email => 'Email',
        Feature.calendar => 'Calendar',
        Feature.code => 'Code',
        Feature.tasks => 'Tasks',
      };

  IconData get icon => switch (this) {
        Feature.chat => Icons.chat_bubble_outline,
        Feature.email => Icons.mail_outline,
        Feature.calendar => Icons.calendar_month_outlined,
        Feature.code => Icons.code_outlined,
        Feature.tasks => Icons.checklist_outlined,
      };
}

enum DaemonMode { manual, responsive, hourly, nightly }

extension DaemonModeX on DaemonMode {
  String get label => switch (this) {
        DaemonMode.manual => 'Manual',
        DaemonMode.responsive => 'Every 5 min',
        DaemonMode.hourly => 'Hourly',
        DaemonMode.nightly => 'Nightly',
      };

  Duration? get interval => switch (this) {
        DaemonMode.manual => null,
        DaemonMode.responsive => const Duration(minutes: 5),
        DaemonMode.hourly => const Duration(hours: 1),
        DaemonMode.nightly => null,
      };
}

/// Wire protocol an [LLMProvider] speaks. Any number of providers can be added
/// and each is routed by protocol rather than by a fixed id, so the app is not
/// limited to a hardcoded set — you can add unlimited providers for each
/// compatible protocol.
enum ProviderProtocol { anthropic, openai, gemini }

extension ProviderProtocolX on ProviderProtocol {
  String get label => switch (this) {
        ProviderProtocol.anthropic => 'Anthropic-compatible',
        ProviderProtocol.openai => 'OpenAI-compatible',
        ProviderProtocol.gemini => 'Gemini-compatible',
      };

  /// The default API base URL template for this protocol, or null when the
  /// provider must supply one.
  String? get defaultBaseUrl => switch (this) {
        ProviderProtocol.anthropic => 'https://api.anthropic.com',
        ProviderProtocol.openai => 'https://api.openai.com/v1',
        ProviderProtocol.gemini => 'https://generativelanguage.googleapis.com',
      };

  /// A stable identity used for badges/colour selection, so provider colouring
  /// doesn't require knowing every provider id up front.
  String get badgeKey => switch (this) {
        ProviderProtocol.anthropic => 'claude',
        ProviderProtocol.openai => 'custom',
        ProviderProtocol.gemini => 'gemini',
      };
}

class ProviderConfig {
  final String id;
  final String name;
  final ProviderProtocol protocol;
  final String apiKey;
  final String baseUrl;
  final String selectedModel;
  final List<String> models;
  /// Per-feature model overrides. Keys are [Feature] names. Falls back to
  /// [selectedModel] when a feature has no override.
  final Map<String, String> featureModels;

  const ProviderConfig({
    required this.id,
    required this.name,
    this.protocol = ProviderProtocol.openai,
    this.apiKey = '',
    this.baseUrl = '',
    required this.selectedModel,
    required this.models,
    this.featureModels = const {},
  });

  /// The model to use for a given feature.
  String modelFor(Feature feature) =>
      featureModels[feature.name] ?? selectedModel;

  ProviderConfig copyWith({
    String? name,
    ProviderProtocol? protocol,
    String? apiKey,
    String? baseUrl,
    String? selectedModel,
    List<String>? models,
    Map<String, String>? featureModels,
  }) =>
      ProviderConfig(
        id: id,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        apiKey: apiKey ?? this.apiKey,
        baseUrl: baseUrl ?? this.baseUrl,
        selectedModel: selectedModel ?? this.selectedModel,
        models: models ?? this.models,
        featureModels: featureModels ?? this.featureModels,
      );
}

class AppConfig {
  final String activeProviderId;
  final Map<String, ProviderConfig> providers;
  final DaemonMode daemonMode;
  final String nightlyTime;
  // 0 = never expire
  final int taskTtlDays;
  /// Max tool-use iterations the agent loop runs before giving up.
  final int agentMaxIterations;
  /// Max iterations the daemon runs per task before stopping.
  final int daemonMaxIterations;
  /// User-defined subagents (in addition to the built-in defaults).
  final List<SubAgent> customSubAgents;
  /// User-rebound keyboard shortcuts (keyed by shortcut id).
  final Map<String, String> shortcuts;
  /// Whether the Minnow companion sync (Supabase, using the public anon key)
  /// is enabled. Defaults to true to preserve existing behaviour, but if the
  /// Supabase project does not have strict Row-Level-Security with per-user
  /// policies, the anon key can read/write any user's tasks. Set false to
  /// disable remote sync and rely on local storage only.
  final bool minnowSyncEnabled;
  /// Whether to use the dark theme. Defaults to true.
  final bool darkMode;
  /// Whether the user has seen the first-run onboarding. Defaults to false.
  final bool hasSeenOnboarding;

  const AppConfig({
    required this.activeProviderId,
    required this.providers,
    this.daemonMode = DaemonMode.manual,
    this.nightlyTime = '23:00',
    this.taskTtlDays = 2,
    this.agentMaxIterations = 20,
    this.daemonMaxIterations = 5,
    this.customSubAgents = const [],
    this.shortcuts = const {},
    this.minnowSyncEnabled = true,
    this.darkMode = true,
    this.hasSeenOnboarding = false,
  });

  /// The key combination for a shortcut id, or its default if not rebound.
  String shortcutKey(String id) {
    final custom = shortcuts[id];
    if (custom != null && custom.isNotEmpty) return custom;
    for (final s in ShortcutDefaults.all) {
      if (s.id == id) return s.effectiveKey;
    }
    return '';
  }

  /// All subagents available to the code agent: built-in defaults first,
  /// then any user-defined ones.
  List<SubAgent> get subAgents => [...SubAgentDefaults.all, ...customSubAgents];

  SubAgent subAgentById(String id) {
    for (final a in subAgents) {
      if (a.id == id) return a;
    }
    return SubAgentDefaults.byId(id);
  }

  /// The model a subagent should use. Falls back to the Code feature's model
  /// for the active provider when the subagent has no explicit override.
  String modelForSubAgent(SubAgent agent) =>
      agent.model?.isNotEmpty == true ? agent.model! : modelFor(Feature.code);

  /// The active provider, or a safe fallback when the map is empty or the id
  /// is missing. Never throws — callers (e.g. the daemon, LLM registry) rely
  /// on this being non-null even in a degraded/empty config.
  ProviderConfig get active {
    final byId = providers[activeProviderId];
    if (byId != null) return byId;
    if (providers.isNotEmpty) return providers.values.first;
    return const ProviderConfig(
      id: '',
      name: 'Unconfigured',
      selectedModel: '',
      models: [],
    );
  }

  /// The model to use for a given feature, from the active provider.
  String modelFor(Feature feature) => active.modelFor(feature);

  AppConfig copyWith({
    String? activeProviderId,
    Map<String, ProviderConfig>? providers,
    DaemonMode? daemonMode,
    String? nightlyTime,
    int? taskTtlDays,
    int? agentMaxIterations,
    int? daemonMaxIterations,
    List<SubAgent>? customSubAgents,
    Map<String, String>? shortcuts,
    bool? minnowSyncEnabled,
    bool? darkMode,
    bool? hasSeenOnboarding,
  }) =>
      AppConfig(
        activeProviderId: activeProviderId ?? this.activeProviderId,
        providers: providers ?? this.providers,
        daemonMode: daemonMode ?? this.daemonMode,
        nightlyTime: nightlyTime ?? this.nightlyTime,
        taskTtlDays: taskTtlDays ?? this.taskTtlDays,
        agentMaxIterations: agentMaxIterations ?? this.agentMaxIterations,
        daemonMaxIterations: daemonMaxIterations ?? this.daemonMaxIterations,
        customSubAgents: customSubAgents ?? this.customSubAgents,
        shortcuts: shortcuts ?? this.shortcuts,
        minnowSyncEnabled: minnowSyncEnabled ?? this.minnowSyncEnabled,
        darkMode: darkMode ?? this.darkMode,
        hasSeenOnboarding: hasSeenOnboarding ?? this.hasSeenOnboarding,
      );

  static AppConfig get defaults => AppConfig(
        activeProviderId: 'claude',
        daemonMode: DaemonMode.manual,
        nightlyTime: '23:00',
        taskTtlDays: 2,
        providers: {
          'claude': const ProviderConfig(
            id: 'claude',
            name: 'Claude',
            protocol: ProviderProtocol.anthropic,
            baseUrl: 'https://api.anthropic.com',
            selectedModel: 'claude-sonnet-4-6',
            models: [
              'claude-sonnet-4-6',
              'claude-opus-4-8',
              'claude-haiku-4-5-20251001',
            ],
          ),
          'gemini': const ProviderConfig(
            id: 'gemini',
            name: 'Gemini',
            protocol: ProviderProtocol.gemini,
            baseUrl: 'https://generativelanguage.googleapis.com',
            selectedModel: 'gemini-2.0-flash',
            models: [
              'gemini-2.0-flash',
              'gemini-1.5-pro',
              'gemini-1.5-flash',
            ],
          ),
          'groq': const ProviderConfig(
            id: 'groq',
            name: 'Groq',
            protocol: ProviderProtocol.openai,
            baseUrl: 'https://api.groq.com/openai/v1',
            selectedModel: 'llama-3.3-70b-versatile',
            models: [
              'llama-3.3-70b-versatile',
              'llama-3.1-8b-instant',
              'mixtral-8x7b-32768',
            ],
          ),
          'ollama': const ProviderConfig(
            id: 'ollama',
            name: 'Ollama',
            protocol: ProviderProtocol.openai,
            baseUrl: 'http://localhost:11434',
            selectedModel: 'llama3.2',
            models: ['llama3.2', 'mistral', 'codellama', 'gemma2'],
          ),
          'custom': const ProviderConfig(
            id: 'custom',
            name: 'Custom',
            protocol: ProviderProtocol.openai,
            baseUrl: 'https://api.openai.com/v1',
            selectedModel: 'gpt-4o',
            models: ['gpt-4o', 'gpt-4o-mini', 'gpt-4-turbo'],
          ),
        },
      );
}
