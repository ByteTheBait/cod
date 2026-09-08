import '../models/config.dart';
import 'claude.dart';
import 'custom.dart';
import 'gemini.dart';
import 'provider.dart';

/// Builds an [LLMProvider] from a [ProviderConfig] based on its wire protocol.
/// Because routing is by protocol (not a fixed id), the app can support an
/// unlimited number of providers per compatible protocol.
LLMProvider providerFor(ProviderConfig p) => switch (p.protocol) {
      ProviderProtocol.anthropic => ClaudeProvider(),
      ProviderProtocol.gemini => GeminiProvider(),
      ProviderProtocol.openai => CustomProvider(),
    };
