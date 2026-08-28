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
    final color = _colors[providerId] ?? Colors.grey;
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
