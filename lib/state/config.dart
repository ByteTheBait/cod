import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/config.dart';
import '../models/subagent.dart';
import '../services/daemon_service.dart';

class ConfigNotifier extends Notifier<AppConfig> {
  @override
  AppConfig build() {
    Future.microtask(_load);
    return AppConfig.defaults;
  }

  static const _prefActiveProvider = 'active_provider';
  static const _prefDaemonMode = 'daemon_mode';
  static const _prefNightlyTime = 'nightly_time';
  static const _prefTaskTtlDays = 'task_ttl_days';
  static const _prefAgentMaxIterations = 'agent_max_iterations';
  static const _prefDaemonMaxIterations = 'daemon_max_iterations';
  static const _prefCustomSubAgents = 'custom_subagents';
  static const _prefShortcuts = 'shortcuts';
  static const _prefCustomProviders = 'custom_providers';
  static const _prefDarkMode = 'dark_mode';
  static const _prefHasSeenOnboarding = 'has_seen_onboarding';
  static String _prefKey(String provider) => 'key_$provider';
  static String _prefModel(String provider) => 'model_$provider';
  static String _prefBaseUrl(String provider) => 'base_$provider';
  static String _prefFeatureModel(String provider, Feature feature) =>
      'feature_model_${provider}_${feature.name}';

  // One-shot migration: copy settings from the old sandboxed plist (used by
  // versions before v1.4.0 which ran with App Sandbox enabled).
  Future<void> _migrateFromSandbox(SharedPreferences prefs) async {
    if (Platform.isIOS || Platform.isAndroid) return;
    final home = Platform.environment['HOME'] ?? '';
    final plist =
        '$home/Library/Containers/com.henry.cod/Data/Library/Preferences/com.henry.cod.plist';
    if (!await File(plist).exists()) return;
    try {
      final r = await Process.run('plutil', ['-convert', 'json', '-o', '-', plist]);
      if (r.exitCode != 0) return;
      final data = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      for (final entry in data.entries) {
        if (entry.value is String) {
          await prefs.setString(entry.key, entry.value as String);
        }
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Migrate old sandboxed settings if this is the first run without sandbox.
    if (prefs.getString(_prefActiveProvider) == null) {
      await _migrateFromSandbox(prefs);
    }
    final activeId = prefs.getString(_prefActiveProvider) ?? 'claude';
    final daemonModeStr = prefs.getString(_prefDaemonMode) ?? 'manual';
    final daemonMode = DaemonMode.values.firstWhere(
      (m) => m.name == daemonModeStr,
      orElse: () => DaemonMode.manual,
    );
    final nightlyTime = prefs.getString(_prefNightlyTime) ?? '23:00';
    final taskTtlDays = prefs.getInt(_prefTaskTtlDays) ?? 2;
    final agentMaxIterations = prefs.getInt(_prefAgentMaxIterations) ?? 20;
    final daemonMaxIterations = prefs.getInt(_prefDaemonMaxIterations) ?? 5;
    final customSubAgents = _loadCustomSubAgents(prefs);
    final shortcuts = _loadShortcuts(prefs);
    final darkMode = prefs.getBool(_prefDarkMode) ?? true;
    final hasSeenOnboarding = prefs.getBool(_prefHasSeenOnboarding) ?? false;
    final providers = Map<String, ProviderConfig>.from(state.providers);
    // Restore user-defined providers (protocol + endpoint + models + key),
    // merged over defaults so built-ins still pick up their persisted values.
    for (final p in _loadCustomProviders(prefs)) {
      providers[p.id] = p;
    }
    for (final id in providers.keys) {
      final key = prefs.getString(_prefKey(id)) ?? '';
      final model = prefs.getString(_prefModel(id)) ?? providers[id]!.selectedModel;
      final base = prefs.getString(_prefBaseUrl(id)) ?? providers[id]!.baseUrl;
      final featureModels = <String, String>{};
      for (final f in Feature.values) {
        final fm = prefs.getString(_prefFeatureModel(id, f));
        if (fm != null && fm.isNotEmpty) featureModels[f.name] = fm;
      }
      providers[id] = providers[id]!.copyWith(
        apiKey: key,
        selectedModel: model,
        baseUrl: base,
        featureModels: featureModels,
      );
    }
    state = AppConfig(
      activeProviderId: activeId,
      providers: providers,
      daemonMode: daemonMode,
      nightlyTime: nightlyTime,
      taskTtlDays: taskTtlDays,
      agentMaxIterations: agentMaxIterations,
      daemonMaxIterations: daemonMaxIterations,
      customSubAgents: customSubAgents,
      shortcuts: shortcuts,
      darkMode: darkMode,
      hasSeenOnboarding: hasSeenOnboarding,
    );
    DaemonService.instance.apply(daemonMode, nightlyTime);
  }

  Map<String, String> _loadShortcuts(SharedPreferences prefs) {
    final raw = prefs.getString(_prefShortcuts);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return const {};
    }
  }

  Future<void> _persistShortcuts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefShortcuts, jsonEncode(state.shortcuts));
  }

  /// Rebind a keyboard shortcut. Pass an empty [key] to reset to default.
  Future<void> setShortcut(String id, String key) async {
    final shortcuts = Map<String, String>.from(state.shortcuts);
    if (key.isEmpty) {
      shortcuts.remove(id);
    } else {
      shortcuts[id] = key;
    }
    state = state.copyWith(shortcuts: shortcuts);
    await _persistShortcuts();
  }

  List<SubAgent> _loadCustomSubAgents(SharedPreferences prefs) {
    final raw = prefs.getString(_prefCustomSubAgents);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SubAgent.fromJson(e as Map<String, dynamic>))
          .where((a) => !a.isDefault)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistCustomSubAgents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(
        state.customSubAgents.map((a) => a.toJson()).toList());
    await prefs.setString(_prefCustomSubAgents, raw);
  }

  /// Add a new user-defined subagent.
  Future<void> addSubAgent(SubAgent agent) async {
    state = state.copyWith(
        customSubAgents: [...state.customSubAgents, agent]);
    await _persistCustomSubAgents();
  }

  /// Update an existing custom subagent (by id).
  Future<void> updateSubAgent(SubAgent agent) async {
    state = state.copyWith(
        customSubAgents: state.customSubAgents
            .map((a) => a.id == agent.id ? agent : a)
            .toList());
    await _persistCustomSubAgents();
  }

  /// Remove a custom subagent (by id). Built-in defaults cannot be removed.
  Future<void> removeSubAgent(String id) async {
    state = state.copyWith(
        customSubAgents:
            state.customSubAgents.where((a) => a.id != id).toList());
    await _persistCustomSubAgents();
  }

  List<ProviderConfig> _loadCustomProviders(SharedPreferences prefs) {
    final raw = prefs.getString(_prefCustomProviders);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => _providerFromJson(e as Map<String, dynamic>))
          .whereType<ProviderConfig>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistCustomProviders() async {
    final prefs = await SharedPreferences.getInstance();
    final custom = state.providers.values
        .where((p) => !_builtinProviderIds.contains(p.id))
        .toList();
    await prefs.setString(
        _prefCustomProviders, jsonEncode(custom.map(_providerToJson).toList()));
  }

  static const _builtinProviderIds = {
    'claude', 'gemini', 'groq', 'ollama', 'custom',
  };

  static Map<String, dynamic> _providerToJson(ProviderConfig p) => {
        'id': p.id,
        'name': p.name,
        'protocol': p.protocol.name,
        'apiKey': p.apiKey,
        'baseUrl': p.baseUrl,
        'selectedModel': p.selectedModel,
        'models': p.models,
        'featureModels': p.featureModels,
      };

  static ProviderConfig? _providerFromJson(Map<String, dynamic> j) {
    try {
      final id = j['id'] as String;
      final protocol = ProviderProtocol.values
          .firstWhere((e) => e.name == (j['protocol'] as String?),
              orElse: () => ProviderProtocol.openai);
      final featureModels = (j['featureModels'] as Map? ?? {})
          .map((k, v) => MapEntry(k as String, v as String));
      return ProviderConfig(
        id: id,
        name: j['name'] as String? ?? id,
        protocol: protocol,
        apiKey: j['apiKey'] as String? ?? '',
        baseUrl: j['baseUrl'] as String? ?? '',
        selectedModel: j['selectedModel'] as String? ?? '',
        models: (j['models'] as List? ?? [
          'model'
        ]).map((e) => e as String).toList(),
        featureModels: featureModels,
      );
    } catch (_) {
      return null;
    }
  }

  /// Add a user-defined provider. Returns an error message, or null on success.
  Future<String?> addProvider(ProviderConfig provider) async {
    if (provider.id.isEmpty || provider.name.isEmpty) {
      return 'Provider needs an id and a name.';
    }
    if (state.providers.containsKey(provider.id)) {
      return 'A provider with id "${provider.id}" already exists.';
    }
    final providers = Map<String, ProviderConfig>.from(state.providers);
    providers[provider.id] = provider;
    state = state.copyWith(providers: providers);
    await _persistCustomProviders();
    return null;
  }

  /// Update any provider (built-in key/url/model, or a fully custom one).
  Future<void> updateProvider(ProviderConfig provider) async {
    final providers = Map<String, ProviderConfig>.from(state.providers);
    providers[provider.id] = provider;
    state = state.copyWith(providers: providers);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey(provider.id), provider.apiKey);
    await prefs.setString(_prefModel(provider.id), provider.selectedModel);
    await prefs.setString(_prefBaseUrl(provider.id), provider.baseUrl);
    if (!_builtinProviderIds.contains(provider.id)) {
      await _persistCustomProviders();
    }
  }

  /// Remove a user-defined provider. Built-ins cannot be removed.
  Future<String?> removeProvider(String id) async {
    if (_builtinProviderIds.contains(id)) {
      return 'Built-in providers cannot be removed.';
    }
    final providers = Map<String, ProviderConfig>.from(state.providers)
      ..remove(id);
    final newActive = state.activeProviderId == id
        ? (providers.keys.isNotEmpty ? providers.keys.first : 'claude')
        : state.activeProviderId;
    state = AppConfig(
      activeProviderId: newActive,
      providers: providers,
      daemonMode: state.daemonMode,
      nightlyTime: state.nightlyTime,
      taskTtlDays: state.taskTtlDays,
      agentMaxIterations: state.agentMaxIterations,
      daemonMaxIterations: state.daemonMaxIterations,
      customSubAgents: state.customSubAgents,
      shortcuts: state.shortcuts,
    );
    final prefs = await SharedPreferences.getInstance();
    await _persistCustomProviders();
    await prefs.remove(_prefKey(id));
    await prefs.remove(_prefModel(id));
    await prefs.remove(_prefBaseUrl(id));
    return null;
  }

  Future<void> setActiveProvider(String id) async {
    state = state.copyWith(activeProviderId: id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefActiveProvider, id);
  }

  Future<void> setApiKey(String providerId, String key) async {
    final providers = Map<String, ProviderConfig>.from(state.providers);
    providers[providerId] = providers[providerId]!.copyWith(apiKey: key);
    state = state.copyWith(providers: providers);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey(providerId), key);
  }

  Future<void> setModel(String providerId, String model) async {
    final providers = Map<String, ProviderConfig>.from(state.providers);
    providers[providerId] = providers[providerId]!.copyWith(selectedModel: model);
    state = state.copyWith(providers: providers);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefModel(providerId), model);
  }

  Future<void> setBaseUrl(String providerId, String url) async {
    final providers = Map<String, ProviderConfig>.from(state.providers);
    providers[providerId] = providers[providerId]!.copyWith(baseUrl: url);
    state = state.copyWith(providers: providers);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefBaseUrl(providerId), url);
  }

  /// Set the model used by a specific feature for a provider. An empty
  /// [model] clears the override and falls back to the provider's default.
  Future<void> setFeatureModel(
      String providerId, Feature feature, String model) async {
    final providers = Map<String, ProviderConfig>.from(state.providers);
    final p = providers[providerId]!;
    final featureModels = Map<String, String>.from(p.featureModels);
    if (model.isEmpty) {
      featureModels.remove(feature.name);
    } else {
      featureModels[feature.name] = model;
    }
    providers[providerId] = p.copyWith(featureModels: featureModels);
    state = state.copyWith(providers: providers);
    final prefs = await SharedPreferences.getInstance();
    if (model.isEmpty) {
      await prefs.remove(_prefFeatureModel(providerId, feature));
    } else {
      await prefs.setString(_prefFeatureModel(providerId, feature), model);
    }
  }

  Future<void> setDaemonMode(DaemonMode mode) async {
    state = state.copyWith(daemonMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefDaemonMode, mode.name);
    DaemonService.instance.apply(mode, state.nightlyTime);
  }

  Future<void> setNightlyTime(String hhmm) async {
    state = state.copyWith(nightlyTime: hhmm);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefNightlyTime, hhmm);
    if (state.daemonMode == DaemonMode.nightly) {
      DaemonService.instance.apply(DaemonMode.nightly, hhmm);
    }
  }

  Future<void> setTaskTtlDays(int days) async {
    state = state.copyWith(taskTtlDays: days);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefTaskTtlDays, days);
  }

  Future<void> setAgentMaxIterations(int value) async {
    state = state.copyWith(agentMaxIterations: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefAgentMaxIterations, value);
  }

  Future<void> setDaemonMaxIterations(int value) async {
    state = state.copyWith(daemonMaxIterations: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefDaemonMaxIterations, value);
  }

  Future<void> setDarkMode(bool dark) async {
    state = state.copyWith(darkMode: dark);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefDarkMode, dark);
  }

  Future<void> markOnboardingSeen() async {
    state = state.copyWith(hasSeenOnboarding: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefHasSeenOnboarding, true);
  }
}
