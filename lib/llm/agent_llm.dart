import 'dart:convert';
import '../models/config.dart';
import '../models/tool.dart';
import '../utils/rate_limit.dart';

class AgentLLM {
  Future<AgentLLMResponse> call({
    required List<Map<String, dynamic>> messages,
    required List<Tool> tools,
    required String model,
    required String apiKey,
    required ProviderProtocol protocol,
    String? baseUrl,
    String? system,
    int maxTokens = 8192,
  }) async {
    return switch (protocol) {
      ProviderProtocol.gemini => _callGemini(
          messages: messages, tools: tools, model: model, apiKey: apiKey,
          system: system, maxTokens: maxTokens),
      ProviderProtocol.anthropic => _callClaude(
          messages: messages, tools: tools, model: model, apiKey: apiKey,
          baseUrl: baseUrl, system: system, maxTokens: maxTokens),
      ProviderProtocol.openai => _callOpenAI(
          url: _openAIUrl(baseUrl),
          messages: messages, tools: tools, model: model, apiKey: apiKey,
          system: system, maxTokens: maxTokens),
    };
  }

  /// OpenAI-compatible endpoints take `/v1/chat/completions` under their base.
  /// If the user supplied a base that already ends in `/v1` or points at a
  /// local gateway that routes `/chat/completions` directly, we append
  /// accordingly rather than double-suffixing.
  String _openAIUrl(String? baseUrl) {
    var base = (baseUrl?.isNotEmpty == true ? baseUrl! : 'https://api.openai.com/v1');
    base = base.replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/chat/completions')) return base;
    if (base.endsWith('/v1') || base.endsWith('/v1beta')) return '$base/chat/completions';
    return '$base/v1/chat/completions';
  }

  // ── Claude ────────────────────────────────────────────────────────────────

  Future<AgentLLMResponse> _callClaude({
    required List<Map<String, dynamic>> messages,
    required List<Tool> tools,
    required String model,
    required String apiKey,
    String? baseUrl,
    String? system,
    required int maxTokens,
  }) async {
    final url = (baseUrl?.isNotEmpty == true
        ? baseUrl!.replaceAll(RegExp(r'/+$'), '')
        : 'https://api.anthropic.com') + '/v1/messages';
    final body = <String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      if (system != null && system.isNotEmpty) 'system': system,
      'tools': tools.map((t) => t.toClaudeJson()).toList(),
      'messages': _mergeConsecutiveSameRole(messages),
    };
    final resp = await postWithRetry(Uri.parse(url), headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    }, body: jsonEncode(body));
    if (resp.statusCode != 200) throw Exception('Claude ${resp.statusCode}: ${resp.body}');

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    String text = '';
    final calls = <ToolCall>[];
    for (final block in json['content'] as List) {
      final b = block as Map<String, dynamic>;
      if (b['type'] == 'text') text += b['text'] as String;
      if (b['type'] == 'tool_use') {
        calls.add(ToolCall(id: b['id'] as String, name: b['name'] as String,
            input: Map<String, dynamic>.from(b['input'] as Map)));
      }
    }
    return AgentLLMResponse(text: text, toolCalls: calls, stopReason: json['stop_reason'] as String);
  }

  // ── OpenAI-compat (Groq / Ollama) ─────────────────────────────────────────

  Future<AgentLLMResponse> _callOpenAI({
    required String url,
    required List<Map<String, dynamic>> messages,
    required List<Tool> tools,
    required String model,
    required String apiKey,
    String? system,
    required int maxTokens,
  }) async {
    final oaiMessages = <Map<String, dynamic>>[
      if (system != null && system.isNotEmpty) {'role': 'system', 'content': system},
      ..._toOpenAIMessages(messages),
    ];
    final body = <String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      'tools': tools.map((t) => t.toOpenAIJson()).toList(),
      'messages': oaiMessages,
    };
    final resp = await postWithRetry(Uri.parse(url), headers: {
      if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
      'content-type': 'application/json',
    }, body: jsonEncode(body));
    if (resp.statusCode != 200) throw Exception('${resp.statusCode}: ${resp.body}');

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final msg = (json['choices'] as List).first['message'] as Map<String, dynamic>;
    final text = msg['content'] as String? ?? '';
    final rawCalls = msg['tool_calls'] as List? ?? [];
    final calls = rawCalls.map((tc) {
      final fn = tc['function'] as Map<String, dynamic>;
      return ToolCall(
        id: tc['id'] as String,
        name: fn['name'] as String,
        input: jsonDecode(fn['arguments'] as String) as Map<String, dynamic>,
      );
    }).toList();
    final finish = (json['choices'] as List).first['finish_reason'] as String? ?? 'stop';
    return AgentLLMResponse(text: text, toolCalls: calls,
        stopReason: calls.isNotEmpty ? 'tool_use' : finish);
  }

  // ── Gemini ────────────────────────────────────────────────────────────────

  Future<AgentLLMResponse> _callGemini({
    required List<Map<String, dynamic>> messages,
    required List<Tool> tools,
    required String model,
    required String apiKey,
    String? baseUrl,
    String? system,
    required int maxTokens,
  }) async {
    String endpoint = (baseUrl?.isNotEmpty == true
        ? baseUrl!
        : 'https://generativelanguage.googleapis.com').replaceAll(RegExp(r'/+$'), '');
    if (!endpoint.endsWith(':generateContent')) {
      endpoint = '$endpoint/v1beta/models/$model:generateContent';
    }
    final url = '$endpoint?key=$apiKey';
    final body = <String, dynamic>{
      'contents': _toGeminiContents(messages),
      if (system != null && system.isNotEmpty)
        'systemInstruction': {'parts': [{'text': system}]},
      'tools': [{'functionDeclarations': tools.map((t) => t.toGeminiJson()).toList()}],
      'generationConfig': {'maxOutputTokens': maxTokens},
    };
    final resp = await postWithRetry(Uri.parse(url), headers: {'content-type': 'application/json'},
        body: jsonEncode(body));
    if (resp.statusCode != 200) throw Exception('Gemini ${resp.statusCode}: ${resp.body}');

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final parts = ((json['candidates'] as List).first['content']['parts'] as List);
    String text = '';
    final calls = <ToolCall>[];
    for (final part in parts) {
      final p = part as Map<String, dynamic>;
      if (p.containsKey('text')) text += p['text'] as String;
      if (p.containsKey('functionCall')) {
        final fc = p['functionCall'] as Map<String, dynamic>;
        calls.add(ToolCall(
          id: 'gemini-${fc['name']}-${calls.length}',
          name: fc['name'] as String,
          input: Map<String, dynamic>.from(fc['args'] as Map? ?? {}),
        ));
      }
    }
    return AgentLLMResponse(text: text, toolCalls: calls,
        stopReason: calls.isNotEmpty ? 'tool_use' : 'end_turn');
  }

  // ── Message format converters ─────────────────────────────────────────────

  // Claude internal format → OpenAI messages list
  List<Map<String, dynamic>> _toOpenAIMessages(List<Map<String, dynamic>> claudeMsgs) {
    final out = <Map<String, dynamic>>[];
    for (final msg in claudeMsgs) {
      final role = msg['role'] as String;
      final content = msg['content'];

      if (content is String) {
        out.add({'role': role, 'content': content});
        continue;
      }

      if (content is List) {
        // Check if this is a tool_result message (user role with tool results)
        final isToolResult = content.any((b) => (b as Map)['type'] == 'tool_result');
        if (isToolResult) {
          for (final block in content) {
            final b = block as Map<String, dynamic>;
            out.add({'role': 'tool', 'tool_call_id': b['tool_use_id'], 'content': b['content']});
          }
          continue;
        }

        // Assistant message with text + tool_use blocks
        String text = '';
        final toolCalls = <Map<String, dynamic>>[];
        for (final block in content) {
          final b = block as Map<String, dynamic>;
          if (b['type'] == 'text') text += b['text'] as String;
          if (b['type'] == 'tool_use') {
            toolCalls.add({
              'id': b['id'],
              'type': 'function',
              'function': {'name': b['name'], 'arguments': jsonEncode(b['input'])},
            });
          }
        }
        out.add({
          'role': 'assistant',
          // Use an empty string (not null) so strict providers don't reject
          // an assistant turn that has only tool calls.
          'content': text.isEmpty ? '' : text,
          if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
        });
      }
    }
    // Collapse consecutive messages from the same role. OpenAI-compatible
    // endpoints (and providers in general) are unreliable with back-to-back
    // user/tool turns — some silently drop one, which loses prior context.
    return _mergeSameRole(out);
  }

  /// Merge adjacent messages of the same role so the provider never sees
  /// consecutive user/tool/assistant turns it may reject or silently drop.
  List<Map<String, dynamic>> _mergeSameRole(List<Map<String, dynamic>> msgs) {
    if (msgs.isEmpty) return msgs;
    final out = <Map<String, dynamic>>[msgs.first];
    for (final m in msgs.skip(1)) {
      final last = out.last;
      if (last['role'] == m['role'] && last['role'] != 'tool') {
        // Fold the new message's text into the previous one. Tool calls are
        // kept on the first message; later non-tool text is appended.
        final prevText = (last['content'] as String? ?? '');
        final curText = (m['content'] as String? ?? '');
        last['content'] = prevText.isEmpty ? curText : '$prevText\n$curText';
      } else {
        out.add(m);
      }
    }
    return out;
  }

  /// Merge adjacent messages with the same role. Within a single run the
  /// history interleaves assistant (tool_use) and user (tool_result) turns, so
  /// this is normally a no-op — but if a run is interrupted and its partial
  /// history is carried forward, consecutive same-role turns can appear and
  /// cause providers to error or drop earlier context. Claude enforces strictly
  /// alternating user/assistant messages, so folding them prevents failed calls.
  List<Map<String, dynamic>> _mergeConsecutiveSameRole(
      List<Map<String, dynamic>> msgs) {
    if (msgs.length < 2) return msgs;
    final out = <Map<String, dynamic>>[msgs.first];
    for (final m in msgs.skip(1)) {
      final last = out.last;
      if (last['role'] == m['role']) {
        // Append this message's content to the previous one.
        final prev = last['content'];
        final cur = m['content'];
        if (prev is String && cur is String) {
          last['content'] = '$prev\n$cur';
        } else {
          out.add(m);
        }
      } else {
        out.add(m);
      }
    }
    return out;
  }

  // Claude internal format → Gemini contents list
  List<Map<String, dynamic>> _toGeminiContents(List<Map<String, dynamic>> claudeMsgs) {
    // Build id→name map from tool_use blocks so we can fill functionResponse names
    final idToName = <String, String>{};
    for (final msg in claudeMsgs) {
      final content = msg['content'];
      if (content is List) {
        for (final block in content) {
          final b = block as Map<String, dynamic>;
          if (b['type'] == 'tool_use') idToName[b['id'] as String] = b['name'] as String;
        }
      }
    }

    final out = <Map<String, dynamic>>[];
    for (final msg in claudeMsgs) {
      final role = msg['role'] as String;
      final content = msg['content'];

      if (content is String) {
        out.add({'role': role == 'assistant' ? 'model' : 'user', 'parts': [{'text': content}]});
        continue;
      }

      if (content is List) {
        final isToolResult = content.any((b) => (b as Map)['type'] == 'tool_result');
        if (isToolResult) {
          final parts = content.map((block) {
            final b = block as Map<String, dynamic>;
            final name = idToName[b['tool_use_id'] as String] ?? 'unknown';
            return {'functionResponse': {'name': name, 'response': {'result': b['content']}}};
          }).toList();
          out.add({'role': 'user', 'parts': parts});
          continue;
        }

        // Assistant message
        final parts = <Map<String, dynamic>>[];
        for (final block in content) {
          final b = block as Map<String, dynamic>;
          if (b['type'] == 'text' && (b['text'] as String).isNotEmpty) {
            parts.add({'text': b['text']});
          }
          if (b['type'] == 'tool_use') {
            parts.add({'functionCall': {'name': b['name'], 'args': b['input']}});
          }
        }
        if (parts.isNotEmpty) out.add({'role': 'model', 'parts': parts});
      }
    }
    return out;
  }
}

class AgentLLMResponse {
  final String text;
  final List<ToolCall> toolCalls;
  final String stopReason;

  const AgentLLMResponse({required this.text, required this.toolCalls, required this.stopReason});

  bool get hasToolCalls => toolCalls.isNotEmpty;
}
