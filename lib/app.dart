import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models/command.dart';
import 'services/daemon_service.dart';
import 'state/providers.dart';
import 'theme.dart';
import 'widgets/command_palette.dart';
import 'screens/chat_screen.dart';
import 'screens/email_screen.dart';
import 'screens/code_screen.dart';
import 'screens/tasks_screen.dart';
import 'screens/calendar_screen.dart';
import 'screens/settings_screen.dart';

class CodApp extends StatelessWidget {
  /// A folder to open in the Code tab on launch (from a CLI arg).
  final String? initialFolder;
  const CodApp({super.key, this.initialFolder});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cod',
      debugShowCheckedModeBanner: false,
      theme: CodTheme.dark,
      home: _Shell(initialFolder: initialFolder),
    );
  }
}

class _Shell extends ConsumerStatefulWidget {
  final String? initialFolder;
  const _Shell({this.initialFolder});

  @override
  ConsumerState<_Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<_Shell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      ref.read(minnowSyncProvider).start();
      ref.read(updateProvider.notifier).checkForUpdates();
      final config = ref.read(configProvider);
      DaemonService.instance.init(
        tasksReader: () => ref.read(tasksProvider),
        configReader: () => ref.read(configProvider),
        onComplete: (id, status) =>
            ref.read(tasksProvider.notifier).cycleStatusTo(id, status),
        onThreadMessage: (id, message) =>
            ref.read(tasksProvider.notifier).addThreadMessage(id, message),
      );
      DaemonService.instance.apply(config.daemonMode, config.nightlyTime);
      // Prune stale tasks after tasks have loaded from disk
      await Future.delayed(const Duration(milliseconds: 500));
      ref.read(tasksProvider.notifier).pruneExpired(config.taskTtlDays);

      // Open a folder passed on the command line, if any.
      final initial = widget.initialFolder;
      if (initial != null && initial.isNotEmpty) {
        await ref.read(codeProvider.notifier).setWorkingDirFromPath(initial);
      }
    });

    // Listen for folders opened via Finder / drag-and-drop / "Open With".
    const channel = MethodChannel('cod/folder');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openFolder') {
        final path = call.arguments as String?;
        if (path != null && path.isNotEmpty) {
          await ref.read(codeProvider.notifier).setWorkingDirFromPath(path);
          if (mounted) setState(() => _index = 3); // jump to Code tab
        }
      }
    });

    _registerCommands();
  }

  void _registerCommands() {
    final reg = CommandRegistry.instance;
    reg.register(Command(
      id: 'command_palette',
      title: 'Command palette',
      icon: Icons.search,
      shortcut: 'cmd+k',
      run: () => showCommandPalette(context),
    ));
    reg.register(Command(
      id: 'switch_chat',
      title: 'Go to Chat',
      icon: Icons.chat_bubble_outline,
      shortcut: 'cmd+1',
      run: () => setState(() => _index = 0),
    ));
    reg.register(Command(
      id: 'switch_email',
      title: 'Go to Email',
      icon: Icons.mail_outline,
      shortcut: 'cmd+2',
      run: () => setState(() => _index = 1),
    ));
    reg.register(Command(
      id: 'switch_calendar',
      title: 'Go to Calendar',
      icon: Icons.calendar_month_outlined,
      shortcut: 'cmd+3',
      run: () => setState(() => _index = 2),
    ));
    reg.register(Command(
      id: 'switch_code',
      title: 'Go to Code',
      icon: Icons.code_outlined,
      shortcut: 'cmd+4',
      run: () => setState(() => _index = 3),
    ));
    reg.register(Command(
      id: 'switch_tasks',
      title: 'Go to Tasks',
      icon: Icons.checklist_outlined,
      shortcut: 'cmd+5',
      run: () => setState(() => _index = 4),
    ));
    reg.register(Command(
      id: 'switch_settings',
      title: 'Go to Settings',
      icon: Icons.settings_outlined,
      shortcut: 'cmd+6',
      run: () => setState(() => _index = 5),
    ));
  }

  /// Resolve a shortcut key string (e.g. 'cmd+k') to a set of modifiers and a
  /// key, then run the matching command if the pressed key matches.
  bool _handleShortcut(KeyDownEvent event) {
    final config = ref.read(configProvider);
    final logical = event.logicalKey;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;

    bool hasMod(String m) => switch (m) {
          'cmd' => pressed.contains(LogicalKeyboardKey.metaLeft) ||
              pressed.contains(LogicalKeyboardKey.metaRight),
          'ctrl' => pressed.contains(LogicalKeyboardKey.controlLeft) ||
              pressed.contains(LogicalKeyboardKey.controlRight),
          'alt' => pressed.contains(LogicalKeyboardKey.altLeft) ||
              pressed.contains(LogicalKeyboardKey.altRight),
          'shift' => pressed.contains(LogicalKeyboardKey.shiftLeft) ||
              pressed.contains(LogicalKeyboardKey.shiftRight),
          _ => false,
        };

    final keyName = _logicalKeyName(logical);

    for (final s in ShortcutDefaults.all) {
      final combo = config.shortcutKey(s.id);
      if (combo.isEmpty) continue;
      final parts = combo.split('+');
      final last = parts.last;
      if (last != keyName) continue;
      // All modifiers must be present.
      final mods = parts.sublist(0, parts.length - 1);
      if (!mods.every(hasMod)) continue;
      // No extra modifiers beyond the combo.
      final extra = pressed.where((k) {
        return k == LogicalKeyboardKey.metaLeft ||
            k == LogicalKeyboardKey.metaRight ||
            k == LogicalKeyboardKey.controlLeft ||
            k == LogicalKeyboardKey.controlRight ||
            k == LogicalKeyboardKey.altLeft ||
            k == LogicalKeyboardKey.altRight ||
            k == LogicalKeyboardKey.shiftLeft ||
            k == LogicalKeyboardKey.shiftRight;
      }).length;
      if (extra != mods.length) continue;

      final cmd = CommandRegistry.instance.byId(s.id);
      if (cmd != null) {
        cmd.run();
        return true;
      }
    }
    return false;
  }

  String _logicalKeyName(LogicalKeyboardKey key) {
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
    final label = key.keyLabel;
    if (label.length == 1) return label.toLowerCase();
    return '';
  }

  static const _screens = [
    ChatScreen(),
    EmailScreen(),
    CalendarScreen(),
    CodeScreen(),
    TasksScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && _handleShortcut(event)) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.mail_outline),
            selectedIcon: Icon(Icons.mail),
            label: 'Email',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Calendar',
          ),
          NavigationDestination(
            icon: Icon(Icons.code_outlined),
            selectedIcon: Icon(Icons.code),
            label: 'Code',
          ),
          NavigationDestination(
            icon: Icon(Icons.checklist_outlined),
            selectedIcon: Icon(Icons.checklist),
            label: 'Tasks',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
      ),
    );
  }
}
