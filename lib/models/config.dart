import 'package:flutter/material.dart';

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

class ProviderConfig {
  final String id;
  final String name;
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
    String? apiKey,
    String? baseUrl,
    String? selectedModel,
    Map<String, String>? featureModels,
  }) =>
      ProviderConfig(
        id: id,
        name: name,
        apiKey: apiKey ?? this.apiKey,
        baseUrl: baseUrl ?? this.baseUrl,
        selectedModel: selectedModel ?? this.selectedModel,
        models: models,
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

  const AppConfig({
    required this.activeProviderId,
    required this.providers,
    this.daemonMode = DaemonMode.manual,
    this.nightlyTime = '23:00',
    this.taskTtlDays = 2,
    this.agentMaxIterations = 20,
    this.daemonMaxIterations = 5,
  });

  ProviderConfig get active =>
      providers[activeProviderId] ?? providers.values.first;

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
  }) =>
      AppConfig(
        activeProviderId: activeProviderId ?? this.activeProviderId,
        providers: providers ?? this.providers,
        daemonMode: daemonMode ?? this.daemonMode,
        nightlyTime: nightlyTime ?? this.nightlyTime,
        taskTtlDays: taskTtlDays ?? this.taskTtlDays,
        agentMaxIterations: agentMaxIterations ?? this.agentMaxIterations,
        daemonMaxIterations: daemonMaxIterations ?? this.daemonMaxIterations,
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
            baseUrl: 'http://localhost:11434',
            selectedModel: 'llama3.2',
            models: ['llama3.2', 'mistral', 'codellama', 'gemma2'],
          ),
          'custom': const ProviderConfig(
            id: 'custom',
            name: 'Custom',
            baseUrl: 'https://api.openai.com/v1',
            selectedModel: 'gpt-4o',
            models: ['gpt-4o', 'gpt-4o-mini', 'gpt-4-turbo'],
          ),
        },
      );
}
