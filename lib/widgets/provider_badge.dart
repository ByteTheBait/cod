import 'package:flutter/material.dart';

class ProviderBadge extends StatelessWidget {
  final String providerId;
  final String modelId;
  final bool compact;

  const ProviderBadge({
    super.key,
    required this.providerId,
    required this.modelId,
    this.compact = false,
  });

  static const _colors = {
    'claude': Color(0xFFDA7756),
    'gemini': Color(0xFF4285F4),
    'groq': Color(0xFF00B4D8),
    'ollama': Color(0xFF7CB77C),
    'custom': Color(0xFF9C6ADE),
  };

  @override
  Widget build(BuildContext context) {
    // For the built-in id set we have explicit colours; anything else (a
    // user-defined provider) is coloured by the id hash so it's stable.
    final color = _colors[providerId] ?? _hashColor(providerId);
    final label = compact ? _shortModel(modelId) : '$providerId · ${_shortModel(modelId)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  static const _palette = [
    Color(0xFFDA7756), // claude-orange
    Color(0xFF4285F4), // blue
    Color(0xFF00B4D8), // teal
    Color(0xFF7CB77C), // green
    Color(0xFF9C6ADE), // violet
    Color(0xFFF06292), // pink
    Color(0xFFFFB300), // amber
    Color(0xFF26A69A), // teal-green
  ];

  Color _hashColor(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _palette[h % _palette.length];
  }

  String _shortModel(String model) {
    if (model.contains('opus')) return 'opus';
    if (model.contains('sonnet')) return 'sonnet';
    if (model.contains('haiku')) return 'haiku';
    if (model.contains('flash')) return 'flash';
    if (model.contains('pro')) return 'pro';
    if (model.contains('llama')) return 'llama';
    if (model.contains('mistral')) return 'mistral';
    if (model.contains('mixtral')) return 'mixtral';
    final parts = model.split('-');
    return parts.first;
  }
}
