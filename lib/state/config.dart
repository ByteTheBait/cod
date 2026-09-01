import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/config.dart';
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
    final providers = Map<String, ProviderConfig>.from(state.providers);
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
    );
    DaemonService.instance.apply(daemonMode, nightlyTime);
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
}
