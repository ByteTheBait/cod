import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/config.dart';

void main() {
  group('AppConfig.defaults', () {
    test('has all five providers', () {
      final c = AppConfig.defaults;
      expect(c.providers.keys, containsAll(['claude', 'gemini', 'groq', 'ollama', 'custom']));
    });

    test('defaults to claude as active provider', () {
      expect(AppConfig.defaults.activeProviderId, 'claude');
      expect(AppConfig.defaults.active.id, 'claude');
    });

    test('default agent iterations are 20', () {
      expect(AppConfig.defaults.agentMaxIterations, 20);
      expect(AppConfig.defaults.daemonMaxIterations, 5);
    });
  });

  group('ProviderConfig.modelFor', () {
    test('falls back to selectedModel when no feature override', () {
      const p = ProviderConfig(
        id: 'claude',
        name: 'Claude',
        selectedModel: 'claude-sonnet-4-6',
        models: ['claude-sonnet-4-6'],
      );
      expect(p.modelFor(Feature.chat), 'claude-sonnet-4-6');
    });

    test('uses feature override when present', () {
      const p = ProviderConfig(
        id: 'claude',
        name: 'Claude',
        selectedModel: 'claude-sonnet-4-6',
        models: ['claude-sonnet-4-6', 'claude-opus-4-8'],
        featureModels: {'code': 'claude-opus-4-8'},
      );
      expect(p.modelFor(Feature.code), 'claude-opus-4-8');
      expect(p.modelFor(Feature.chat), 'claude-sonnet-4-6');
    });
  });

  group('AppConfig.modelFor', () {
    test('delegates to the active provider', () {
      final c = AppConfig.defaults.copyWith(
        providers: {
          'claude': const ProviderConfig(
            id: 'claude',
            name: 'Claude',
            selectedModel: 'claude-sonnet-4-6',
            models: ['claude-sonnet-4-6'],
            featureModels: {'tasks': 'claude-haiku-4-5-20251001'},
          ),
        },
      );
      expect(c.modelFor(Feature.tasks), 'claude-haiku-4-5-20251001');
      expect(c.modelFor(Feature.chat), 'claude-sonnet-4-6');
    });
  });

  group('DaemonMode', () {
    test('intervals match the mode', () {
      expect(DaemonMode.manual.interval, isNull);
      expect(DaemonMode.responsive.interval, const Duration(minutes: 5));
      expect(DaemonMode.hourly.interval, const Duration(hours: 1));
      expect(DaemonMode.nightly.interval, isNull);
    });
  });
}
