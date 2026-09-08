import 'package:flutter/material.dart';

/// A single command available in the command palette and/or via a keyboard
/// shortcut. Screens register commands into the global registry.
class Command {
  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;
  final void Function() run;
  /// Optional keyboard shortcut (e.g. 'cmd+k'). Shown in the palette.
  final String? shortcut;

  const Command({
    required this.id,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.run,
    this.shortcut,
  });
}

/// A user-configurable keyboard shortcut. Maps a logical action id to a
/// key combination. Persisted in config.
class Shortcut {
  final String id;
  final String label;
  final String defaultKey;
  final String key;

  const Shortcut({
    required this.id,
    required this.label,
    required this.defaultKey,
    this.key = '',
  });

  String get effectiveKey => key.isEmpty ? defaultKey : key;

  Map<String, dynamic> toJson() => {'id': id, 'key': key};

  factory Shortcut.fromJson(Map<String, dynamic> j) => Shortcut(
        id: j['id'] as String,
        label: j['label'] as String? ?? j['id'] as String,
        defaultKey: j['defaultKey'] as String? ?? '',
        key: j['key'] as String? ?? '',
      );
}

/// The built-in shortcuts. Users can rebind these in Settings.
class ShortcutDefaults {
  static const all = [
    Shortcut(id: 'command_palette', label: 'Command palette', defaultKey: 'cmd+k'),
    Shortcut(id: 'new_session', label: 'New code session', defaultKey: 'cmd+n'),
    Shortcut(id: 'run_agent', label: 'Run agent', defaultKey: 'cmd+enter'),
    Shortcut(id: 'open_folder', label: 'Open folder', defaultKey: 'cmd+o'),
    Shortcut(id: 'clear_conversation', label: 'Clear conversation', defaultKey: 'cmd+shift+backspace'),
    Shortcut(id: 'switch_chat', label: 'Go to Chat', defaultKey: 'cmd+1'),
    Shortcut(id: 'switch_email', label: 'Go to Email', defaultKey: 'cmd+2'),
    Shortcut(id: 'switch_calendar', label: 'Go to Calendar', defaultKey: 'cmd+3'),
    Shortcut(id: 'switch_code', label: 'Go to Code', defaultKey: 'cmd+4'),
    Shortcut(id: 'switch_tasks', label: 'Go to Tasks', defaultKey: 'cmd+5'),
    Shortcut(id: 'switch_settings', label: 'Go to Settings', defaultKey: 'cmd+6'),
  ];
}
