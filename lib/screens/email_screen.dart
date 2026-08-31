import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/config.dart';
import '../models/email_model.dart';
import '../services/gmail_service.dart';
import '../services/agent_service.dart';
import '../state/email.dart';
import '../state/providers.dart';
import '../llm/provider.dart';
import '../widgets/linkified_text.dart';

class EmailScreen extends ConsumerWidget {
  const EmailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emailState = ref.watch(emailProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Email'),
        actions: [
          if (emailState.status == EmailConnectionStatus.connected) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.read(emailProvider.notifier).refresh(),
            ),
            IconButton(
              icon: const Icon(Icons.logout_outlined),
              tooltip: 'Disconnect',
              onPressed: () => ref.read(emailProvider.notifier).disconnect(),
            ),
          ],
        ],
      ),
      floatingActionButton: emailState.status == EmailConnectionStatus.connected
          ? FloatingActionButton(
              onPressed: () => _showComposeSheet(context),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              tooltip: 'Compose',
              child: const Icon(Icons.edit_outlined),
            )
          : null,
      body: switch (emailState.status) {
        EmailConnectionStatus.unknown => const Center(child: CircularProgressIndicator()),
        EmailConnectionStatus.disconnected => _SetupView(error: emailState.error),
        EmailConnectionStatus.connected => _InboxView(loading: emailState.loading),
      },
    );
  }

  void _showComposeSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _ComposeSheet(),
    );
  }
}

// ── Setup / connect ──────────────────────────────────────────────────────────

class _SetupView extends ConsumerStatefulWidget {
  final String? error;
  const _SetupView({this.error});

  @override
  ConsumerState<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends ConsumerState<_SetupView> {
  bool _connecting = false;

  Future<void> _connect() async {
    setState(() => _connecting = true);
    await ref.read(emailProvider.notifier).connect();
    setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          Icon(Icons.mail_outline, size: 48, color: cs.primary.withOpacity(0.5)),
          const SizedBox(height: 20),
          Text('Gmail', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            'Sign in with your Google account to read and manage your inbox.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface.withOpacity(0.55)),
          ),
          const SizedBox(height: 28),
          if (widget.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(widget.error!, style: TextStyle(color: cs.error, fontSize: 13)),
            ),
          FilledButton.icon(
            onPressed: _connecting ? null : _connect,
            icon: _connecting
                ? SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                : const Icon(Icons.login),
            label: Text(_connecting ? 'Opening browser…' : 'Connect Google Account'),
          ),
          ],
        ),
      ),
    );
  }
}

// ── Inbox ────────────────────────────────────────────────────────────────────

class _InboxView extends ConsumerWidget {
  final bool loading;
  const _InboxView({required this.loading});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threads = ref.watch(emailProvider).threads;
    final cs = Theme.of(context).colorScheme;

    if (loading && threads.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (threads.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: cs.primary.withOpacity(0.4)),
            const SizedBox(height: 12),
            Text('Inbox empty',
                style: TextStyle(color: cs.onSurface.withOpacity(0.5))),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(emailProvider.notifier).refresh(),
      child: ListView.separated(
        itemCount: threads.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) => _ThreadTile(thread: threads[i]),
      ),
    );
  }
}

class _ThreadTile extends ConsumerWidget {
  final GmailThread thread;
  const _ThreadTile({required this.thread});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isUnread = thread.isUnread;

    return ListTile(
      tileColor: isUnread ? cs.primary.withOpacity(0.08) : null,
      leading: Stack(
        alignment: Alignment.topRight,
        children: [
          CircleAvatar(
            backgroundColor: isUnread
                ? cs.primary.withOpacity(0.25)
                : cs.surfaceContainerHigh,
            radius: 20,
            child: Text(
              _initials(thread.from),
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isUnread ? cs.primary : cs.onSurface.withOpacity(0.7)),
            ),
          ),
          if (isUnread)
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
                border: Border.all(
                    color: Theme.of(context).scaffoldBackgroundColor, width: 1.5),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              _displayName(thread.from),
              style: TextStyle(
                fontWeight: isUnread ? FontWeight.w700 : FontWeight.w500,
                fontSize: 14,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _dateLabel(thread.date),
            style: TextStyle(
                fontSize: 11,
                color: isUnread ? cs.primary : cs.onSurface.withOpacity(0.4),
                fontWeight: isUnread ? FontWeight.w700 : FontWeight.normal),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            thread.subject.isEmpty ? '(no subject)' : thread.subject,
            style: TextStyle(
                fontSize: 13,
                color: isUnread ? cs.onSurface : cs.onSurface.withOpacity(0.8),
                fontWeight: isUnread ? FontWeight.w600 : FontWeight.normal),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            thread.snippet,
            style: TextStyle(
                fontSize: 12, color: cs.onSurface.withOpacity(0.45)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      onTap: () {
        ref.read(emailProvider.notifier).markRead(thread.id);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => _ThreadDetailScreen(threadId: thread.id)),
        );
      },
    );
  }

  String _initials(String from) {
    final name = _displayName(from);
    if (name.isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name[0].toUpperCase();
  }

  String _displayName(String from) {
    final match = RegExp(r'^(.*?)\s*<').firstMatch(from);
    if (match != null) return match.group(1)!.trim().replaceAll('"', '');
    return from.split('@').first;
  }

  String _dateLabel(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inDays == 0) return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (diff.inDays < 7) return ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];
    return '${d.month}/${d.day}';
  }
}

// ── Thread detail ────────────────────────────────────────────────────────────

class _ThreadDetailScreen extends ConsumerStatefulWidget {
  final String threadId;
  const _ThreadDetailScreen({required this.threadId});

  @override
  ConsumerState<_ThreadDetailScreen> createState() => _ThreadDetailScreenState();
}

class _ThreadDetailScreenState extends ConsumerState<_ThreadDetailScreen> {
  bool _loading = true;
  bool _aiLoading = false;
  String _aiAction = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ref.read(emailProvider.notifier).loadThread(widget.threadId);
    setState(() => _loading = false);
  }

  GmailThread? get _thread =>
      ref.read(emailProvider).threads.where((t) => t.id == widget.threadId).firstOrNull;

  Future<void> _summarize() async {
    final thread = _thread;
    if (thread == null) return;
    final config = ref.read(configProvider);
    if (config.active.apiKey.isEmpty) {
      _showError('Set an API key in Settings first.');
      return;
    }
    setState(() { _aiLoading = true; _aiAction = 'Summarizing…'; });
    try {
      final body = thread.messages
              ?.map((m) => 'From: ${m.from}\n\n${m.body}')
              .join('\n\n---\n\n') ??
          thread.snippet;
      final registry = ref.read(llmRegistryProvider);
      final provider = registry[config.activeProviderId] ?? registry.values.first;
      final summary = await fetchEmailAI(
        prompt: 'Summarize this email thread concisely in 2-3 bullet points:\n\n$body',
        config: config,
        provider: provider,
        model: config.modelFor(Feature.email),
      );
      ref.read(emailProvider.notifier).setAiSummary(widget.threadId, summary);
    } catch (e) {
      _showError(e.toString());
    } finally {
      setState(() { _aiLoading = false; _aiAction = ''; });
    }
  }

  Future<void> _draftReply() async {
    final thread = _thread;
    if (thread == null) return;
    final config = ref.read(configProvider);
    if (config.active.apiKey.isEmpty) {
      _showError('Set an API key in Settings first.');
      return;
    }
    setState(() { _aiLoading = true; _aiAction = 'Drafting reply…'; });
    try {
      final last = thread.messages?.lastOrNull;
      final body = last?.body ?? thread.snippet;
      final registry = ref.read(llmRegistryProvider);
      final provider = registry[config.activeProviderId] ?? registry.values.first;
      final draft = await fetchEmailAI(
        prompt: 'Draft a professional, concise reply to this email. '
            'Output only the reply body, no subject line:\n\n'
            'From: ${last?.from ?? thread.from}\n\n$body',
        config: config,
        provider: provider,
        model: config.modelFor(Feature.email),
      );
      ref.read(emailProvider.notifier).setAiDraft(widget.threadId, draft);
    } catch (e) {
      _showError(e.toString());
    } finally {
      setState(() { _aiLoading = false; _aiAction = ''; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  void _openReplyEditor() {
    final thread = _thread;
    if (thread == null) return;
    final last = thread.messages?.lastOrNull;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ReplySheet(
        thread: thread,
        lastMessage: last,
        initialBody: thread.aiDraft ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final thread = ref.watch(emailProvider).threads.where((t) => t.id == widget.threadId).firstOrNull;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(thread?.subject ?? 'Email', style: const TextStyle(fontSize: 15)),
        actions: [
          if (_aiLoading)
            Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Action bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  color: cs.surfaceContainerLow,
                  child: Row(
                    children: [
                      if (_aiLoading)
                        Text(_aiAction,
                            style: TextStyle(
                                fontSize: 12, color: cs.primary, fontStyle: FontStyle.italic))
                      else ...[
                        _ActionChip(
                          icon: Icons.auto_awesome,
                          label: 'Summarize',
                          onTap: _summarize,
                        ),
                        const SizedBox(width: 8),
                        _ActionChip(
                          icon: Icons.edit_outlined,
                          label: 'Draft reply',
                          onTap: _draftReply,
                        ),
                        const SizedBox(width: 8),
                        _ActionChip(
                          icon: Icons.reply,
                          label: 'Reply',
                          onTap: _openReplyEditor,
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // AI summary
                      if (thread?.aiSummary != null) ...[
                        _AiCard(
                          label: 'Summary',
                          content: thread!.aiSummary!,
                          icon: Icons.auto_awesome,
                        ),
                        const SizedBox(height: 12),
                      ],
                      // AI draft
                      if (thread?.aiDraft != null) ...[
                        _AiCard(
                          label: 'Draft reply',
                          content: thread!.aiDraft!,
                          icon: Icons.edit_outlined,
                          trailing: TextButton(
                            onPressed: _openReplyEditor,
                            child: const Text('Edit & Send'),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      // Messages
                      if (thread?.messages != null)
                        ...thread!.messages!.map((m) => _MessageCard(message: m)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: cs.primary),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary)),
          ],
        ),
      ),
    );
  }
}

class _AiCard extends StatelessWidget {
  final String label;
  final String content;
  final IconData icon;
  final Widget? trailing;

  const _AiCard({
    required this.label,
    required this.content,
    required this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: cs.primary),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                      letterSpacing: 0.5)),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 8),
          MarkdownBody(data: content),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  final GmailMessage message;
  const _MessageCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  message.from,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _fmt(message.date),
                style: TextStyle(
                    fontSize: 11, color: cs.onSurface.withOpacity(0.4)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinkifiedText(
            message.body.trim(),
            style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withOpacity(0.85),
                height: 1.5),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.month}/${d.day} $h:$m';
  }
}

// ── Reply sheet ───────────────────────────────────────────────────────────────

class _ReplySheet extends ConsumerStatefulWidget {
  final GmailThread thread;
  final GmailMessage? lastMessage;
  final String initialBody;

  const _ReplySheet({
    required this.thread,
    required this.lastMessage,
    required this.initialBody,
  });

  @override
  ConsumerState<_ReplySheet> createState() => _ReplySheetState();
}

class _ReplySheetState extends ConsumerState<_ReplySheet> {
  late final TextEditingController _body;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _body = TextEditingController(text: widget.initialBody);
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final from = await GmailService.instance.userEmail;
      final to = widget.lastMessage?.from ?? widget.thread.from;
      await GmailService.instance.sendReply(
        from: from,
        to: to,
        subject: widget.thread.subject,
        body: _body.text,
        inReplyTo: widget.lastMessage?.messageId,
        references: widget.lastMessage?.messageId,
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reply sent!')),
        );
      }
    } catch (e) {
      setState(() => _sending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Send failed: $e'),
              backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reply to ${widget.thread.from}',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(hintText: 'Your reply…'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                : const Icon(Icons.send),
            label: Text(_sending ? 'Sending…' : 'Send'),
          ),
        ],
      ),
    );
  }
}

// ── Compose sheet ────────────────────────────────────────────────────────────

class _ComposeSheet extends ConsumerStatefulWidget {
  const _ComposeSheet();

  @override
  ConsumerState<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends ConsumerState<_ComposeSheet> {
  final _toCtrl = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  bool _sending = false;
  bool _aiDrafting = false;

  @override
  void dispose() {
    _toCtrl.dispose();
    _subjectCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _aiDraft() async {
    final note = _bodyCtrl.text.trim();
    final config = ref.read(configProvider);
    if (config.active.apiKey.isEmpty && config.activeProviderId != 'ollama') {
      _showError('Set an API key in Settings first.');
      return;
    }
    if (_aiDrafting) return;
    setState(() => _aiDrafting = true);

    final registry = ref.read(llmRegistryProvider);
    final provider = registry[config.activeProviderId] ?? registry.values.first;

    final system = 'You are a professional email writer. '
        'Draft a polished, concise email based on the user\'s notes or ideas. '
        'Output only the email body — no subject line, no salutation, no signature. '
        'Match the tone implied by the notes.';

    try {
      final draft = await provider.complete(
        config: config,
        system: system,
        prompt: 'Draft an email based on these notes:\n\n$note',
        maxTokens: 2048,
        model: config.modelFor(Feature.email),
      );
      if (!mounted) return;
      final trimmed = draft.trim();
      final cleaned = trimmed
          .replaceAll(RegExp(r'^```[\w-]*\s*'), '')
          .replaceAll(RegExp(r'\s*```$'), '')
          .replaceAll(RegExp(r'^Subject:\s*.*$\n?', multiLine: true), '')
          .trim();
      // Replace the notes with the drafted body.
      setState(() {
        _bodyCtrl.text = cleaned;
        _bodyCtrl.selection = TextSelection.collapsed(offset: cleaned.length);
      });
    } catch (e) {
      _showError('Draft failed: $e');
    } finally {
      if (mounted) setState(() => _aiDrafting = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  Future<void> _send() async {
    final to = _toCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (to.isEmpty) return;
    setState(() => _sending = true);
    try {
      final from = await GmailService.instance.userEmail;
      await GmailService.instance.sendMessage(
        from: from,
        to: to,
        subject: _subjectCtrl.text.trim(),
        body: body,
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email sent!')),
        );
      }
    } catch (e) {
      setState(() => _sending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Send failed: $e'),
              backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New message',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TextField(
            controller: _toCtrl,
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'To'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _subjectCtrl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Subject'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bodyCtrl,
            maxLines: 10,
            minLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Message',
              suffixIcon: _aiDrafting
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.auto_awesome),
                      tooltip: 'AI draft',
                      onPressed: _aiDraft,
                    ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                : const Icon(Icons.send),
            label: Text(_sending ? 'Sending…' : 'Send'),
          ),
        ],
      ),
    );
  }
}
