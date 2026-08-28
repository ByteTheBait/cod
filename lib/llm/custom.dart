import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/message.dart';
import '../utils/rate_limit.dart';
import 'provider.dart';

/// A generic OpenAI-compatible provider. The base URL, API key and model are
/// all user-configurable, so it can point at OpenAI, OpenRouter, a local
/// gateway, or any other OpenAI-compatible endpoint.
class CustomProvider implements LLMProvider {
  @override
  String get id => 'custom';
  @override
  String get name => 'Custom';

  @override
  Stream<String> stream({
    required List<Message> messages,
    required String model,
    required String apiKey,
    String? baseUrl,
    int maxTokens = 4096,
  }) async* {
    final base = (baseUrl != null && baseUrl.isNotEmpty)
        ? baseUrl
        : 'https://api.openai.com/v1';
    final url = '$base/chat/completions';

    final client = http.Client();
    try {
      final bodyJson = jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'stream': true,
        'messages': messages
            .map((m) => {'role': m.role.name, 'content': m.content})
            .toList(),
      });

      http.Request build() {
        final r = http.Request('POST', Uri.parse(url));
        r.headers.addAll({
          'authorization': 'Bearer $apiKey',
          'content-type': 'application/json',
        });
        r.body = bodyJson;
        return r;
      }

      final response = await sendWithRetry(client, build);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw Exception('API ${response.statusCode}: $body');
      }

      String buf = '';
      await for (final bytes in response.stream) {
        buf += utf8.decode(bytes);
        final lines = buf.split('\n');
        buf = lines.removeLast();
        for (final line in lines) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6).trim();
          if (data == '[DONE]' || data.isEmpty) continue;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final choices = json['choices'] as List?;
            if (choices == null || choices.isEmpty) continue;
            final delta = choices[0]['delta'] as Map<String, dynamic>?;
            final content = delta?['content'] as String?;
            if (content != null) yield content;
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }
}
