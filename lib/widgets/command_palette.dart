import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/command.dart';

/// A global registry of commands available in the command palette.
/// Screens register their commands at build time.
class CommandRegistry {
  CommandRegistry._();
  static final CommandRegistry instance = CommandRegistry._();

  final List<Command> _commands = [];
  final Map<String, Command> _byId = {};

  void register(Command cmd) {
    _byId[cmd.id] = cmd;
    _commands
      ..removeWhere((c) => c.id == cmd.id)
      ..add(cmd);
  }

  void unregister(String id) {
    _byId.remove(id);
    _commands.removeWhere((c) => c.id == id);
  }

  List<Command> get commands => List.unmodifiable(_commands);

  Command? byId(String id) => _byId[id];
}

/// Opens the command palette overlay.
Future<void> showCommandPalette(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => const _CommandPaletteDialog(),
  );
}

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog();

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final _ctrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<Command> get _filtered {
    final q = _query.trim().toLowerCase();
    final all = CommandRegistry.instance.commands;
    if (q.isEmpty) return all;
    return all.where((c) {
      return c.title.toLowerCase().contains(q) ||
          (c.subtitle?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final results = _filtered;

    return Dialog(
      backgroundColor: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  hintText: 'Type a command…',
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: InputBorder.none,
                  filled: false,
                ),
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('No commands match "$_query"',
                          style: TextStyle(
                              color: cs.onSurface.withOpacity(0.5))),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final cmd = results[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(cmd.icon, size: 18, color: cs.primary),
                          title: Text(cmd.title, style: const TextStyle(fontSize: 14)),
                          subtitle: cmd.subtitle == null
                              ? null
                              : Text(cmd.subtitle!,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurface.withOpacity(0.5))),
                          trailing: cmd.shortcut == null
                              ? null
                              : Text(cmd.shortcut!,
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: cs.onSurface.withOpacity(0.4))),
                          onTap: () {
                            Navigator.pop(context);
                            cmd.run();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A widget that captures a key combination and reports it. Used by the
/// shortcut editor in Settings.
class ShortcutRecorder extends StatefulWidget {
  final String current;
  final void Function(String key) onChanged;
  const ShortcutRecorder({super.key, required this.current, required this.onChanged});

  @override
  State<ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<ShortcutRecorder> {
  bool _recording = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() => _recording = true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _recording ? cs.primary.withOpacity(0.15) : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: _recording ? cs.primary : Colors.transparent, width: 1.5),
        ),
        child: _recording
            ? Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent) {
                    final key = _describe(event.logicalKey, event.physicalKey);
                    if (key.isNotEmpty) {
                      setState(() => _recording = false);
                      widget.onChanged(key);
                    }
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Text('Press keys…',
                    style: TextStyle(fontSize: 12, color: cs.primary)),
              )
            : Text(widget.current.isEmpty ? 'None' : widget.current,
                style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurface.withOpacity(0.8))),
      ),
    );
  }

  String _describe(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) {
    final parts = <String>[];
    if (logical == LogicalKeyboardKey.metaLeft ||
        logical == LogicalKeyboardKey.metaRight) {
      return 'cmd';
    }
    if (logical == LogicalKeyboardKey.controlLeft ||
        logical == LogicalKeyboardKey.controlRight) {
      return 'ctrl';
    }
    if (logical == LogicalKeyboardKey.altLeft ||
        logical == LogicalKeyboardKey.altRight) {
      return 'alt';
    }
    if (logical == LogicalKeyboardKey.shiftLeft ||
        logical == LogicalKeyboardKey.shiftRight) {
      return 'shift';
    }
    // Modifier combos: capture cmd/ctrl/alt/shift + a key.
    final mods = HardwareKeyboard.instance.logicalKeysPressed;
    if (mods.contains(LogicalKeyboardKey.metaLeft) ||
        mods.contains(LogicalKeyboardKey.metaRight)) {
      parts.add('cmd');
    }
    if (mods.contains(LogicalKeyboardKey.controlLeft) ||
        mods.contains(LogicalKeyboardKey.controlRight)) {
      parts.add('ctrl');
    }
    if (mods.contains(LogicalKeyboardKey.altLeft) ||
        mods.contains(LogicalKeyboardKey.altRight)) {
      parts.add('alt');
    }
    if (mods.contains(LogicalKeyboardKey.shiftLeft) ||
        mods.contains(LogicalKeyboardKey.shiftRight)) {
      parts.add('shift');
    }
    final keyName = _keyName(logical);
    if (keyName.isNotEmpty) parts.add(keyName);
    return parts.join('+');
  }

  String _keyName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.enter) return 'enter';
    if (key == LogicalKeyboardKey.space) return 'space';
    if (key == LogicalKeyboardKey.backspace) return 'backspace';
    if (key == LogicalKeyboardKey.escape) return 'esc';
    if (key == LogicalKeyboardKey.tab) return 'tab';
    if (key == LogicalKeyboardKey.delete) return 'delete';
    if (key == LogicalKeyboardKey.arrowUp) return 'up';
    if (key == LogicalKeyboardKey.arrowDown) return 'down';
    if (key == LogicalKeyboardKey.arrowLeft) return 'left';
    if (key == LogicalKeyboardKey.arrowRight) return 'right';
    // Single letters / digits
    final label = key.keyLabel;
    if (label.length == 1) return label.toLowerCase();
    return '';
  }
}
