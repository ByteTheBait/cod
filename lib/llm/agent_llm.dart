import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/tool.dart';
import '../utils/rate_limit.dart';

class AgentLLM {
  Future<AgentLLMResponse> call({
    required List<Map<String, dynamic>> messages,
    required List<Tool> tools,
    required String model,
    required String apiKey,
    required String providerId,
    String? baseUrl,
    String? system,
    int maxTokens = 8192,
  }) async {
    return switch (providerId) {
      'gemini' => _callGemini(
          messages: messages, tools: tools, model: model, apiKey: apiKey,
          system: system, maxTokens: maxTokens),
      'groq' => _callOpenAI(
          url: 'https://api.groq.com/openai/v1/chat/completions',
          messages: messages, tools: tools, model: model, apiKey: apiKey,
          system: system, maxTokens: maxTokens),
      'ollama' => _callOpenAI(
          url: '${(baseUrl?.isNotEmpty == true ? baseUrl : 'http://localhost:11434')}/v1/chat/completions',
          messages: messages, tools: tools, model: model, apiKey: '',
          system: system, maxTokens: maxTokens),
      'custom' => _callOpenAI(
          url: '${(baseUrl?.isNotEmpty == true ? baseUrl : 'https://api.openai.com/v1')}/chat/completions',
          messages: messages, tools: tools, model: model, apiKey: apiKey,
          system: system, maxTokens: maxTokens),
      _ => _callClaude(
          messages: messages, tools: tools, model: model, apiKey: apiKey,
          baseUrl: baseUrl, system: system, maxTokens: maxTokens),
    };
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
    final url = (baseUrl?.isNotEmpty == true ? baseUrl! : 'https://api.anthropic.com') + '/v1/messages';
    final body = <String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      if (system != null && system.isNotEmpty) 'system': system,
      'tools': tools.map((t) => t.toClaudeJson()).toList(),
      'messages': messages,
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
    String? system,
    required int maxTokens,
  }) async {
    final url = 'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';
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
          'content': text.isEmpty ? null : text,
          if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
        });
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
          final parts = (content as List).map((block) {
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
