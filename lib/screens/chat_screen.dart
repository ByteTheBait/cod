import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/config.dart';
import '../models/message.dart';
import '../state/providers.dart';
import '../widgets/message_bubble.dart';
import '../widgets/provider_badge.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _streaming = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _streaming) return;
    _ctrl.clear();

    final config = ref.read(configProvider);
    final llm = ref.read(llmRegistryProvider)[config.activeProviderId];
    if (llm == null) return;

    final sessions = ref.read(sessionsProvider.notifier);
    var sessionId = ref.read(sessionsProvider).activeId;

    if (sessionId == null) {
      final s = await sessions.create(
        providerId: config.activeProviderId,
        modelId: config.modelFor(Feature.chat),
      );
      sessionId = s.id;
    }

    await sessions.addMessage(sessionId, Message.user(text));
    _scrollToBottom();

    final placeholder = Message.assistant('', isStreaming: true);
    await sessions.addMessage(sessionId, placeholder);
    setState(() => _streaming = true);
    _scrollToBottom();

    final history = ref
        .read(sessionsProvider)
        .sessions
        .firstWhere((s) => s.id == sessionId)
        .messages
        .where((m) => !m.isStreaming)
        .toList();

    String accumulated = '';
    try {
      await for (final chunk in llm.stream(
        messages: history,
        model: config.modelFor(Feature.chat),
        apiKey: config.active.apiKey,
        baseUrl: config.active.baseUrl.isNotEmpty ? config.active.baseUrl : null,
      )) {
        accumulated += chunk;
        sessions.updateStreaming(sessionId!, accumulated);
        _scrollToBottom();
      }
    } catch (e) {
      accumulated = '_Error: ${e}_';
      sessions.updateStreaming(sessionId!, accumulated);
    }

    await sessions.finalizeStreaming(sessionId!);
    setState(() => _streaming = false);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final sessState = ref.watch(sessionsProvider);
    final config = ref.watch(configProvider);
    final active = sessState.active;
    final messages = active?.messages ?? [];
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      drawer: _SessionsDrawer(
        onNewChat: () async {
          Navigator.pop(context);
          ref.read(sessionsProvider.notifier).clearActive();
        },
      ),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Text(active?.title ?? 'Cod'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ProviderBadge(
              providerId: config.activeProviderId,
              modelId: config.active.selectedModel,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? _EmptyChat(config: config)
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => MessageBubble(message: messages[i]),
                  ),
          ),
          _InputBar(
            ctrl: _ctrl,
            streaming: _streaming,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController ctrl;
  final bool streaming;
  final VoidCallback onSend;

  const _InputBar({
    required this.ctrl,
    required this.streaming,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.fromLTRB(12, 8, 12, MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.surfaceContainerHigh)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              maxLines: 5,
              minLines: 1,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: 'Message...',
                hintStyle: TextStyle(color: Colors.white24),
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: streaming
                ? SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.primary,
                        ),
                      ),
                    ),
                  )
                : IconButton.filled(
                    onPressed: onSend,
                    icon: const Icon(Icons.arrow_upward),
                    style: IconButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  final AppConfig config;
  const _EmptyChat({required this.config});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 48, color: cs.primary.withOpacity(0.4)),
          const SizedBox(height: 16),
          Text(
            'Cod',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: cs.onSurface.withOpacity(0.7),
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            '${config.active.name} · ${config.active.selectedModel}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withOpacity(0.35),
                ),
          ),
        ],
      ),
    );
  }
}

class _SessionsDrawer extends ConsumerWidget {
  final VoidCallback onNewChat;

  const _SessionsDrawer({required this.onNewChat});

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset all sessions?'),
        content: const Text(
            'This deletes all chat history. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(sessionsProvider.notifier).resetAll();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessState = ref.watch(sessionsProvider);
    final cs = Theme.of(context).colorScheme;

    return Drawer(
      backgroundColor: cs.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    'Sessions',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  if (sessState.sessions.isNotEmpty)
                    IconButton(
                      icon: Icon(Icons.delete_sweep_outlined,
                          size: 18, color: cs.onSurface.withOpacity(0.5)),
                      tooltip: 'Reset all sessions',
                      onPressed: () => _confirmReset(context, ref),
                    ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: onNewChat,
                    icon: const Icon(Icons.add, size: 18),
                    style: IconButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                      minimumSize: const Size(32, 32),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: sessState.sessions.isEmpty
                  ? Center(
                      child: Text(
                        'No sessions yet',
                        style: TextStyle(color: cs.onSurface.withOpacity(0.4)),
                      ),
                    )
                  : ListView.builder(
                      itemCount: sessState.sessions.length,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      itemBuilder: (_, i) {
                        final s = sessState.sessions[i];
                        final isActive = s.id == sessState.activeId;
                        return ListTile(
                          selected: isActive,
                          selectedTileColor: cs.primary.withOpacity(0.12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight:
                                      isActive ? FontWeight.w600 : FontWeight.normal,
                                ),
                          ),
                          subtitle: ProviderBadge(
                            providerId: s.providerId,
                            modelId: s.modelId,
                            compact: true,
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.delete_outline,
                                size: 18, color: cs.onSurface.withOpacity(0.4)),
                            onPressed: () => ref
                                .read(sessionsProvider.notifier)
                                .delete(s.id),
                          ),
                          onTap: () {
                            ref.read(sessionsProvider.notifier).setActive(s.id);
                            Navigator.pop(context);
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
