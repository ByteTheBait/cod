import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/message.dart';
import '../utils/rate_limit.dart';
import 'provider.dart';

class ClaudeProvider implements LLMProvider {
  @override
  String get id => 'claude';
  @override
  String get name => 'Claude';

  @override
  Stream<String> stream({
    required List<Message> messages,
    required String model,
    required String apiKey,
    String? baseUrl,
    int maxTokens = 4096,
  }) async* {
    final client = http.Client();
    try {
      final systemContent = messages
          .where((m) => m.role == MessageRole.system)
          .map((m) => m.content)
          .join('\n');

      final chatMessages = messages
          .where((m) => m.role != MessageRole.system)
          .map((m) => {'role': m.role.name, 'content': m.content})
          .toList();

      final bodyJson = jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'stream': true,
        if (systemContent.isNotEmpty) 'system': systemContent,
        'messages': chatMessages,
      });

      final endpoint = (baseUrl?.isNotEmpty == true
          ? baseUrl!.replaceAll(RegExp(r'/+$'), '')
          : 'https://api.anthropic.com') + '/v1/messages';
      final uri = Uri.parse(endpoint);

      http.Request build() {
        final r = http.Request('POST', uri);
        r.headers.addAll({
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        });
        r.body = bodyJson;
        return r;
      }

      final response = await sendWithRetry(client, build);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw Exception('Claude ${response.statusCode}: $body');
      }

      String buf = '';
      await for (final bytes in response.stream) {
        buf += utf8.decode(bytes);
        final lines = buf.split('\n');
        buf = lines.removeLast();
        for (final line in lines) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6).trim();
          if (data.isEmpty) continue;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            if (json['type'] == 'content_block_delta') {
              final delta = json['delta'] as Map<String, dynamic>;
              if (delta['type'] == 'text_delta') {
                yield delta['text'] as String;
              }
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }
}
