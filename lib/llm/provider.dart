import '../models/config.dart';
import '../models/message.dart';

abstract class LLMProvider {
  String get id;
  String get name;

  Stream<String> stream({
    required List<Message> messages,
    required String model,
    required String apiKey,
    String? baseUrl,
    int maxTokens = 4096,
  });
}

extension LLMProviderX on LLMProvider {
  Future<String> complete({
    required AppConfig config,
    String? system,
    required String prompt,
    int maxTokens = 4096,
    String? model,
  }) async {
    final msgs = [
      if (system != null)
        Message(role: MessageRole.system, content: system),
      Message(role: MessageRole.user, content: prompt),
    ];
    final buf = StringBuffer();
    await for (final chunk in stream(
      messages: msgs,
      model: model ?? config.active.selectedModel,
      apiKey: config.active.apiKey,
      baseUrl: config.active.baseUrl,
      maxTokens: maxTokens,
    )) {
      buf.write(chunk);
    }
    return buf.toString();
  }
}
