import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/command.dart';
import '../models/config.dart';
import '../models/subagent.dart';
import '../services/daemon_service.dart';
import '../widgets/command_palette.dart';
import '../services/gmail_service.dart';
import '../state/providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _showProviderEditor(BuildContext context, WidgetRef ref,
      ProviderConfig? existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ProviderEditorSheet(
        existing: existing,
        onSave: (provider) async {
          final notifier = ref.read(configProvider.notifier);
          final err = await notifier.addProvider(provider);
          if (err != null && ctx.mounted) {
            ScaffoldMessenger.of(ctx)
                .showSnackBar(SnackBar(content: Text(err)));
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    final update = ref.watch(updateProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (update.hasUpdate) ...[
            _UpdateBanner(update: update),
            const SizedBox(height: 16),
          ],
          _SectionHeader('Appearance'),
          const SizedBox(height: 8),
          _AppearanceCard(darkMode: config.darkMode),
          const SizedBox(height: 24),
          _SectionHeader('Active provider'),
          const SizedBox(height: 8),
          _ProviderSelector(
            activeId: config.activeProviderId,
            providers: config.providers.values.toList(),
            onChanged: (id) => ref.read(configProvider.notifier).setActiveProvider(id),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _showProviderEditor(context, ref, null),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add provider'),
            ),
          ),
          const SizedBox(height: 16),
          _ProviderCard(providerId: config.activeProviderId),
          const SizedBox(height: 24),
          _SectionHeader('Feature models'),
          const SizedBox(height: 8),
          _FeatureModelsCard(providerId: config.activeProviderId),
          const SizedBox(height: 24),
          _SectionHeader('Sub-agents'),
          const SizedBox(height: 8),
          _SubAgentsCard(subAgents: config.subAgents),
          const SizedBox(height: 24),
          _SectionHeader('Keyboard shortcuts'),
          const SizedBox(height: 8),
          _ShortcutsCard(),
          const SizedBox(height: 24),
          _SectionHeader('Daemon'),
          const SizedBox(height: 8),
          const _DaemonCard(),
          const SizedBox(height: 24),
          _SectionHeader('Gmail'),
          const SizedBox(height: 8),
          const _GmailCard(),
          const SizedBox(height: 24),
          _SectionHeader('Minnow companion'),
          const SizedBox(height: 8),
          const _CompanionCard(),
          const SizedBox(height: 24),
          _SectionHeader('About'),
          const SizedBox(height: 8),
          _AboutCard(update: update),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
      );
}

class _AppearanceCard extends ConsumerWidget {
  final bool darkMode;
  const _AppearanceCard({required this.darkMode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(darkMode ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
              size: 20, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Theme',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  darkMode ? 'Dark' : 'Light',
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurface.withValues(alpha: 0.5)),
                ),
              ],
            ),
          ),
          Switch(
            value: darkMode,
            onChanged: (v) => ref.read(configProvider.notifier).setDarkMode(v),
          ),
        ],
      ),
    );
  }
}

class _ProviderSelector extends StatelessWidget {
  final String activeId;
  final List providers;
  final void Function(String) onChanged;

  const _ProviderSelector({
    required this.activeId,
    required this.providers,
    required this.onChanged,
  });

  static const _colors = {
    'claude': Color(0xFFDA7756),
    'gemini': Color(0xFF4285F4),
    'groq': Color(0xFF00B4D8),
    'ollama': Color(0xFF7CB77C),
    'custom': Color(0xFF9C6ADE),
  };

  Color _colorFor(ProviderConfig p) =>
      _colors[p.protocol.badgeKey] ?? _colors[p.id] ?? Colors.grey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: providers.map((p) {
        final pc = p as ProviderConfig;
        final isActive = pc.id == activeId;
        final color = _colorFor(pc);
        return GestureDetector(
          onTap: () => onChanged(pc.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isActive ? color.withValues(alpha: 0.2) : cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isActive ? color : cs.surfaceContainerHigh,
                width: isActive ? 1.5 : 1,
              ),
            ),
            child: Text(
              pc.name,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isActive ? color : cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _ProviderCard extends ConsumerStatefulWidget {
  final String providerId;
  const _ProviderCard({required this.providerId});

  @override
  ConsumerState<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends ConsumerState<_ProviderCard> {
  late TextEditingController _keyCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _modelCtrl;
  bool _keyVisible = false;

  static const _builtinIds = {'claude', 'gemini', 'groq', 'ollama', 'custom'};

  @override
  void initState() {
    super.initState();
    _loadControllers();
  }

  void _loadControllers() {
    final config = ref.read(configProvider);
    final p = config.providers[widget.providerId]!;
    _keyCtrl = TextEditingController(text: p.apiKey);
    _urlCtrl = TextEditingController(text: p.baseUrl);
    _modelCtrl = TextEditingController(text: p.selectedModel);
  }

  @override
  void didUpdateWidget(covariant _ProviderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerId != widget.providerId) {
      _keyCtrl.dispose();
      _urlCtrl.dispose();
      _modelCtrl.dispose();
      _keyVisible = false;
      _loadControllers();
    }
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    final p = config.providers[widget.providerId]!;
    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(configProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                p.name,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(width: 8),
              Text(
                '· ${p.protocol.label}',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.4),
                ),
              ),
              const Spacer(),
              if (p.id != 'ollama')
                _KeyStatusDot(hasKey: p.apiKey.isNotEmpty),
              if (!_builtinIds.contains(p.id))
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: cs.error.withValues(alpha: 0.8)),
                  tooltip: 'Remove provider',
                  onPressed: () => _remove(context),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Base URL — required for every provider (determines the endpoint).
          TextFormField(
            controller: _urlCtrl,
            decoration: const InputDecoration(labelText: 'Base URL'),
            onChanged: (v) => notifier.setBaseUrl(p.id, v),
          ),
          const SizedBox(height: 10),
          // Model picker
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(labelText: 'Model'),
            onChanged: (v) => notifier.setModel(p.id, v),
          ),
          const SizedBox(height: 10),
          // API key (not shown for local ollama)
          if (p.id != 'ollama' ||
              !p.baseUrl.contains('localhost') && !p.baseUrl.contains('127.0.0.1')) ...[
            TextFormField(
              controller: _keyCtrl,
              obscureText: !_keyVisible,
              decoration: InputDecoration(
                labelText: 'API key',
                suffixIcon: IconButton(
                  icon: Icon(_keyVisible ? Icons.visibility_off : Icons.visibility, size: 18),
                  onPressed: () => setState(() => _keyVisible = !_keyVisible),
                ),
              ),
              onChanged: (v) => notifier.setApiKey(p.id, v),
            ),
          ],
        ],
      ),
    );
  }

  void _remove(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        title: const Text('Remove provider?'),
        content: const Text(
            'This removes the provider and its saved key from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        ref.read(configProvider.notifier).removeProvider(widget.providerId);
      }
    });
  }
}

class _KeyStatusDot extends StatelessWidget {
  final bool hasKey;
  const _KeyStatusDot({required this.hasKey});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hasKey ? Colors.green.shade400 : Colors.grey.shade600,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          hasKey ? 'key set' : 'no key',
          style: TextStyle(
            fontSize: 11,
            color: hasKey ? Colors.green.shade400 : Colors.grey.shade600,
          ),
        ),
      ],
    );
  }
}

// ── Add / edit provider sheet ─────────────────────────────────────────────────

class _ProviderEditorSheet extends StatefulWidget {
  final ProviderConfig? existing;
  final Future<void> Function(ProviderConfig) onSave;
  const _ProviderEditorSheet({this.existing, required this.onSave});

  @override
  State<_ProviderEditorSheet> createState() => _ProviderEditorSheetState();
}

class _ProviderEditorSheetState extends State<_ProviderEditorSheet> {
  late final TextEditingController _idCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _modelCtrl;
  late ProviderProtocol _protocol;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _protocol = e?.protocol ?? ProviderProtocol.openai;
    _idCtrl = TextEditingController(
        text: e?.id ?? _derivedId(e?.name ?? ''));
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _urlCtrl = TextEditingController(
        text: e?.baseUrl ?? ''); // default filled live from protocol
    _modelCtrl = TextEditingController(text: e?.selectedModel ?? '');
  }

  String _derivedId(String name) {
    var id = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    id = id.replaceAll(RegExp(r'^_|_$'), '');
    return id.isEmpty ? 'provider' : id;
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null ? 'Add provider' : 'Edit provider',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              autofocus: widget.existing == null,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (v) => setState(() {
                // Auto-derive the id while editing a new provider and the user
                // hasn't typed one manually yet.
                if (!_idTouched && widget.existing == null) {
                  _idCtrl.text = _derivedId(v);
                }
              }),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _idCtrl,
              enabled: widget.existing == null,
              decoration: const InputDecoration(
                labelText: 'ID',
                hintText: 'e.g. openrouter',
                helperText: 'Used to reference this provider. Cannot be changed later.',
              ),
              onChanged: (_) => _idTouched = true,
            ),
            const SizedBox(height: 10),
            const Text('Protocol',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ProviderProtocol.values.map((pr) {
                final isActive = pr == _protocol;
                return GestureDetector(
                  onTap: () => setState(() {
                    _protocol = pr;
                    // Prefill a sensible base URL for the chosen protocol if
                    // the user hasn't typed their own yet.
                    if (!_urlTouched) {
                      _urlCtrl.text = pr.defaultBaseUrl ?? '';
                    }
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isActive
                          ? cs.primary.withValues(alpha: 0.15)
                          : cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isActive ? cs.primary : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      pr.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            isActive ? FontWeight.w700 : FontWeight.w500,
                        color: isActive
                            ? cs.primary
                            : cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                  labelText: 'Base URL',
                  helperText:
                      'e.g. https://api.openai.com/v1 or http://localhost:11434'),
              onChanged: (_) => _urlTouched = true,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _modelCtrl,
              decoration: const InputDecoration(
                  labelText: 'Default model',
                  hintText: 'e.g. gpt-4o, claude-sonnet-4-6, gemini-2.0-flash'),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                final name = _nameCtrl.text.trim();
                final id = _idCtrl.text.trim();
                final model = _modelCtrl.text.trim();
                final base = _urlCtrl.text.trim();
                if (name.isEmpty || id.isEmpty || model.isEmpty || base.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content:
                              Text('Name, ID, base URL and model are required.')));
                  return;
                }
                final provider = ProviderConfig(
                  id: id,
                  name: name,
                  protocol: _protocol,
                  baseUrl: base,
                  selectedModel: model,
                  models: [model],
                );
                widget.onSave(provider);
                Navigator.pop(context);
              },
              style: FilledButton.styleFrom(backgroundColor: cs.primary),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  bool _idTouched = false;
  bool _urlTouched = false;
}

// ── Feature models card ───────────────────────────────────────────────────────

class _FeatureModelsCard extends ConsumerWidget {
  final String providerId;
  const _FeatureModelsCard({required this.providerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    final p = config.providers[providerId]!;
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choose a model for each feature. All use ${p.name} — '
            'the same API key. A custom model still uses the provider\'s '
            'API endpoint.',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 12),
          ...Feature.values.map((f) {
            return _FeatureModelInput(
              key: ValueKey('feature_${providerId}_${f.name}'),
              providerId: providerId,
              feature: f,
            );
          }),
        ],
      ),
    );
  }
}

class _FeatureModelInput extends ConsumerStatefulWidget {
  final String providerId;
  final Feature feature;
  const _FeatureModelInput({
    super.key,
    required this.providerId,
    required this.feature,
  });

  @override
  ConsumerState<_FeatureModelInput> createState() =>
      _FeatureModelInputState();
}

class _FeatureModelInputState extends ConsumerState<_FeatureModelInput> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _currentModel());
  }

  @override
  void didUpdateWidget(covariant _FeatureModelInput old) {
    super.didUpdateWidget(old);
    if (old.providerId != widget.providerId ||
        old.feature != widget.feature) {
      _ctrl.text = _currentModel();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _currentModel() {
    final config = ref.read(configProvider);
    return config.providers[widget.providerId]!.modelFor(widget.feature);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(widget.feature.icon, size: 16, color: cs.primary.withValues(alpha: 0.7)),
          const SizedBox(width: 10),
          SizedBox(
            width: 90,
            child: Text(
              widget.feature.label,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Model ID',
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              onChanged: (v) => ref
                  .read(configProvider.notifier)
                  .setFeatureModel(widget.providerId, widget.feature, v.trim()),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sub-agents card ───────────────────────────────────────────────────────────

class _SubAgentsCard extends ConsumerWidget {
  final List<SubAgent> subAgents;
  const _SubAgentsCard({required this.subAgents});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final defaults = subAgents.where((a) => a.isDefault).toList();
    final custom = subAgents.where((a) => !a.isDefault).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Specialised agents for the Code tab. Each has its own system '
            'prompt and restricted tool set. Pick one from the Code toolbar.',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 12),
          for (final a in defaults) _SubAgentRow(agent: a),
          if (custom.isNotEmpty) ...[
            const Divider(height: 24),
            for (final a in custom) _SubAgentRow(agent: a),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _showEditor(context, ref, null),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add sub-agent'),
            ),
          ),
        ],
      ),
    );
  }

  void _showEditor(BuildContext context, WidgetRef ref, SubAgent? existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SubAgentEditorSheet(
        existing: existing,
        onSave: (agent) {
          final notifier = ref.read(configProvider.notifier);
          if (existing == null) {
            notifier.addSubAgent(agent);
          } else {
            notifier.updateSubAgent(agent);
          }
        },
      ),
    );
  }
}

class _SubAgentRow extends ConsumerWidget {
  final SubAgent agent;
  const _SubAgentRow({required this.agent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(agent.iconData, size: 18, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(agent.name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  agent.description,
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurface.withValues(alpha: 0.5)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${agent.tools.length} tools'
                  '${agent.model?.isNotEmpty == true ? '  ·  ${agent.model}' : ''}',
                  style: TextStyle(
                      fontSize: 10,
                      color: cs.primary.withValues(alpha: 0.7),
                      fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          if (!agent.isDefault)
            IconButton(
              icon: Icon(Icons.edit_outlined,
                  size: 16, color: cs.onSurface.withValues(alpha: 0.5)),
              tooltip: 'Edit',
              onPressed: () => _openEditor(context, ref, agent),
            ),
          if (!agent.isDefault)
            IconButton(
              icon: Icon(Icons.delete_outline,
                  size: 16, color: cs.error.withValues(alpha: 0.8)),
              tooltip: 'Delete',
              onPressed: () => _delete(context, ref, agent),
            ),
        ],
      ),
    );
  }

  void _openEditor(BuildContext context, WidgetRef ref, SubAgent agent) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SubAgentEditorSheet(
        existing: agent,
        onSave: (updated) =>
            ref.read(configProvider.notifier).updateSubAgent(updated),
      ),
    );
  }

  void _delete(BuildContext context, WidgetRef ref, SubAgent agent) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        title: const Text('Delete sub-agent?'),
        content: Text('"${agent.name}" will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        ref.read(configProvider.notifier).removeSubAgent(agent.id);
      }
    });
  }
}

class _SubAgentEditorSheet extends StatefulWidget {
  final SubAgent? existing;
  final void Function(SubAgent) onSave;
  const _SubAgentEditorSheet({this.existing, required this.onSave});

  @override
  State<_SubAgentEditorSheet> createState() => _SubAgentEditorSheetState();
}

class _SubAgentEditorSheetState extends State<_SubAgentEditorSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _modelCtrl;
  late String _icon;
  late Set<String> _tools;
  bool _useDefaultModel = true;

  static const _allToolNames = [
    'read_file', 'str_replace_file', 'multi_edit', 'write_file',
    'list_directory', 'run_command', 'search_files', 'create_directory',
    'background_start', 'background_status', 'background_list', 'background_kill',
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _promptCtrl = TextEditingController(text: e?.systemPrompt ?? '');
    _modelCtrl = TextEditingController(text: e?.model ?? '');
    _useDefaultModel = e?.model == null || e!.model!.isEmpty;
    _icon = e?.icon ?? SubAgentIcons.defaultIcon;
    _tools = (e?.tools ?? const ['read_file', 'list_directory', 'search_files'])
        .toSet();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _promptCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null ? 'New sub-agent' : 'Edit sub-agent',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              autofocus: widget.existing == null,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                  labelText: 'Description (shown in picker)'),
              maxLines: 2,
              minLines: 1,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _promptCtrl,
              decoration: const InputDecoration(
                  labelText: 'System prompt',
                  hintText: 'e.g. You are a security review agent. Read files and report vulnerabilities...'),
              maxLines: 4,
              minLines: 3,
            ),
            const SizedBox(height: 16),
            Text('Model',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _useDefaultModel = true;
                      _modelCtrl.clear();
                    }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: _useDefaultModel
                            ? cs.primary.withValues(alpha: 0.15)
                            : cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _useDefaultModel
                              ? cs.primary
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Use Code default',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _useDefaultModel
                                    ? cs.primary
                                    : cs.onSurface.withValues(alpha: 0.6),
                              )),
                          const SizedBox(height: 2),
                          Text(
                            'Uses the model set for the Code feature.',
                            style: TextStyle(
                                fontSize: 10,
                                color: cs.onSurface.withValues(alpha: 0.45)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _useDefaultModel = false),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: !_useDefaultModel
                            ? cs.primary.withValues(alpha: 0.15)
                            : cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: !_useDefaultModel
                              ? cs.primary
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Custom model',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: !_useDefaultModel
                                    ? cs.primary
                                    : cs.onSurface.withValues(alpha: 0.6),
                              )),
                          const SizedBox(height: 2),
                          Text(
                            'Use a specific model for this sub-agent.',
                            style: TextStyle(
                                fontSize: 10,
                                color: cs.onSurface.withValues(alpha: 0.45)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (!_useDefaultModel) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _modelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Model ID',
                  hintText: 'e.g. claude-haiku-4-5-20251001',
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('Icon',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: SubAgentIcons.all.map((ic) {
                final isActive = ic == _icon;
                return GestureDetector(
                  onTap: () => setState(() => _icon = ic),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: isActive
                          ? cs.primary.withValues(alpha: 0.18)
                          : cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isActive ? cs.primary : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Icon(SubAgentIcons.dataOf(ic),
                        size: 20,
                        color: isActive ? cs.primary : cs.onSurface.withValues(alpha: 0.6)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Text('Tools',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _allToolNames.map((name) {
                final isActive = _tools.contains(name);
                return GestureDetector(
                  onTap: () => setState(() {
                    if (isActive) {
                      _tools.remove(name);
                    } else {
                      _tools.add(name);
                    }
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isActive
                          ? cs.primary.withValues(alpha: 0.15)
                          : cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isActive ? cs.primary : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      name,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        color: isActive
                            ? cs.primary
                            : cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                final name = _nameCtrl.text.trim();
                if (name.isEmpty || _tools.isEmpty) return;
                final agent = SubAgent(
                  id: widget.existing?.id ??
                      'custom_${DateTime.now().millisecondsSinceEpoch}',
                  name: name,
                  description: _descCtrl.text.trim(),
                  icon: _icon,
                  systemPrompt: _promptCtrl.text.trim().isEmpty
                      ? 'You are a specialised coding agent. Be concise and '
                          'methodical. Read files before editing them.'
                      : _promptCtrl.text.trim(),
                  tools: _allToolNames.where(_tools.contains).toList(),
                  model: _useDefaultModel ? null : _modelCtrl.text.trim(),
                );
                widget.onSave(agent);
                Navigator.pop(context);
              },
              style: FilledButton.styleFrom(backgroundColor: cs.primary),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

}

// ── Keyboard shortcuts card ───────────────────────────────────────────────────

class _ShortcutsCard extends ConsumerWidget {
  const _ShortcutsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final config = ref.watch(configProvider);
    final notifier = ref.read(configProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rebind keyboard shortcuts. Click a key to record a new one.',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 12),
          for (final s in ShortcutDefaults.all)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(s.label,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  ShortcutRecorder(
                    current: config.shortcutKey(s.id),
                    onChanged: (key) => notifier.setShortcut(s.id, key),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => notifier.setShortcut(s.id, ''),
                    child: Icon(Icons.restart_alt,
                        size: 16, color: cs.onSurface.withValues(alpha: 0.4)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Daemon card ───────────────────────────────────────────────────────────────

class _DaemonCard extends ConsumerStatefulWidget {
  const _DaemonCard();

  @override
  ConsumerState<_DaemonCard> createState() => _DaemonCardState();
}

class _DaemonCardState extends ConsumerState<_DaemonCard> {
  late TextEditingController _timeCtrl;

  @override
  void initState() {
    super.initState();
    final config = ref.read(configProvider);
    _timeCtrl = TextEditingController(text: config.nightlyTime);
  }

  @override
  void dispose() {
    _timeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(configProvider.notifier);
    final daemon = DaemonService.instance;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Auto-run', style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (daemon.isTicking)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary),
                    ),
                    const SizedBox(width: 6),
                    Text('running', style: TextStyle(fontSize: 11, color: cs.primary)),
                  ],
                )
              else if (config.daemonMode != DaemonMode.manual) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.green.shade400,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  'active',
                  style: TextStyle(fontSize: 11, color: Colors.green.shade400),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Automatically run the agent on all pending tasks.',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: DaemonMode.values.map((mode) {
              final isActive = config.daemonMode == mode;
              return GestureDetector(
                onTap: () => notifier.setDaemonMode(mode),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isActive ? cs.primary.withValues(alpha: 0.18) : cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isActive ? cs.primary : cs.surfaceContainerHigh,
                      width: isActive ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    mode.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isActive ? cs.primary : cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          if (config.daemonMode == DaemonMode.nightly) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _timeCtrl,
              decoration: const InputDecoration(
                labelText: 'Run at (HH:MM)',
                hintText: '23:00',
              ),
              keyboardType: TextInputType.datetime,
              onChanged: (v) {
                if (RegExp(r'^\d{2}:\d{2}$').hasMatch(v)) {
                  notifier.setNightlyTime(v);
                }
              },
            ),
          ],
          if (config.daemonMode != DaemonMode.manual) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                if (daemon.lastRun != null)
                  Text(
                    'Last run: ${_formatTime(daemon.lastRun!)}',
                    style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.4)),
                  ),
                const Spacer(),
                GestureDetector(
                  onTap: daemon.isTicking ? null : () => setState(() => daemon.tick()),
                  child: Text(
                    'Run now',
                    style: TextStyle(
                      fontSize: 12,
                      color: daemon.isTicking
                          ? cs.onSurface.withValues(alpha: 0.3)
                          : cs.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              const Text('Expire tasks after',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              _TtlSelector(
                value: config.taskTtlDays,
                onChanged: (d) => notifier.setTaskTtlDays(d),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Tasks untouched by you or the agent are deleted automatically.',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.4)),
          ),
          const SizedBox(height: 18),
          const Divider(height: 1),
          const SizedBox(height: 14),
          _IterationCapSelector(
            label: 'Agent loop cap',
            value: config.agentMaxIterations,
            min: 1,
            max: 100,
            onChanged: (v) => notifier.setAgentMaxIterations(v),
          ),
          const SizedBox(height: 4),
          Text(
            'Max tool-use rounds the agent runs before giving up.',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.4)),
          ),
          const SizedBox(height: 14),
          _IterationCapSelector(
            label: 'Daemon run cap',
            value: config.daemonMaxIterations,
            min: 1,
            max: 50,
            onChanged: (v) => notifier.setDaemonMaxIterations(v),
          ),
          const SizedBox(height: 4),
          Text(
            'Max times the auto-run daemon re-runs each pending task.',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.4)),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _TtlSelector extends StatelessWidget {
  final int value;
  final void Function(int) onChanged;

  static const _options = [
    (1, '1d'),
    (2, '2d'),
    (7, '7d'),
    (0, 'Never'),
  ];

  const _TtlSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _options.map(((int days, String label) opt) {
        final isActive = value == opt.$1;
        return GestureDetector(
          onTap: () => onChanged(opt.$1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isActive ? cs.primary.withValues(alpha: 0.18) : cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isActive ? cs.primary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Text(
              opt.$2,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isActive ? cs.primary : cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Iteration cap selector ────────────────────────────────────────────────────

class _IterationCapSelector extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final void Function(int) onChanged;

  const _IterationCapSelector({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        _CapButton(
          icon: Icons.remove,
          onTap: value > min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(
          width: 40,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.primary,
            ),
          ),
        ),
        _CapButton(
          icon: Icons.add,
          onTap: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

class _CapButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _CapButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: onTap == null
              ? cs.surfaceContainerHigh.withValues(alpha: 0.5)
              : cs.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: onTap == null ? Colors.transparent : cs.primary.withValues(alpha: 0.4),
          ),
        ),
        child: Icon(icon,
            size: 16,
            color: onTap == null
                ? cs.onSurface.withValues(alpha: 0.25)
                : cs.primary),
      ),
    );
  }
}

// ── Gmail card ────────────────────────────────────────────────────────────────

class _GmailCard extends ConsumerStatefulWidget {
  const _GmailCard();

  @override
  ConsumerState<_GmailCard> createState() => _GmailCardState();
}

class _GmailCardState extends ConsumerState<_GmailCard> {
  bool _connected = false;
  String _email = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final email = await GmailService.instance.userEmail;
    final connected = await GmailService.instance.isConnected;
    if (!mounted) return;
    setState(() { _email = email; _connected = connected; });
  }

  Future<void> _disconnect() async {
    await GmailService.instance.disconnect();
    ref.read(emailProvider.notifier).disconnect();
    setState(() { _connected = false; _email = ''; });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Gmail', style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_connected)
                Row(
                  children: [
                    Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: Colors.green)),
                    const SizedBox(width: 5),
                    Text(_email,
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurface.withValues(alpha: 0.6))),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _disconnect,
                      child: Text('disconnect',
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.error,
                              decoration: TextDecoration.underline)),
                    ),
                  ],
                ),
            ],
          ),
          if (!_connected) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () async {
                try {
                  final email = await GmailService.instance.connect();
                  if (mounted) setState(() { _connected = true; _email = email; });
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('$e')));
                }
              },
              icon: const Icon(Icons.login, size: 16),
              label: const Text('Connect Google Account'),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Update banner ─────────────────────────────────────────────────────────────

class _UpdateBanner extends StatelessWidget {
  final dynamic update;
  const _UpdateBanner({required this.update});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final latestVersion = update.info?.latestVersion ?? '';
    final releaseUrl = update.info?.releaseUrl ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.system_update_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'v$latestVersion is available',
              style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary, fontSize: 13),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: cs.primary,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: releaseUrl.isNotEmpty
                ? () => launchUrl(Uri.parse(releaseUrl))
                : null,
            child: const Text('Download', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

// ── About card ────────────────────────────────────────────────────────────────

class _AboutCard extends ConsumerWidget {
  final dynamic update;
  const _AboutCard({required this.update});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final version = update.currentVersion;
    final isChecking = update.isChecking;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            version.isEmpty ? 'Cod' : 'Cod v$version',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          if (isChecking)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            GestureDetector(
              onTap: () => ref.read(updateProvider.notifier).checkForUpdates(force: true),
              child: Text(
                update.hasUpdate ? 'Update available' : 'Check for updates',
                style: TextStyle(
                  fontSize: 12,
                  color: update.hasUpdate ? cs.primary : cs.onSurface.withValues(alpha: 0.5),
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Companion / Minnow card ───────────────────────────────────────────────────

class _CompanionCard extends ConsumerWidget {
  const _CompanionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final sync = ref.read(minnowSyncProvider);
    final qr = sync.qrData;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Minnow', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Open Minnow on your phone and scan this code. Works anywhere — Wi-Fi or cellular.',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 16),
          Center(
            child: QrImageView(
              data: qr,
              version: QrVersions.auto,
              size: 160,
              backgroundColor: Colors.white,
              padding: const EdgeInsets.all(8),
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => Clipboard.setData(ClipboardData(text: sync.sessionId)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.copy, size: 12, color: cs.onSurface.withValues(alpha: 0.4)),
                const SizedBox(width: 5),
                Text(
                  // Guard: on first launch start() may not have run yet, so the
                  // session id can be empty — substring(0, 8) would crash.
                  sync.sessionId.isEmpty
                      ? 'Session: initializing…'
                      : 'Session: ${sync.sessionId.substring(0, 8)}…',
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: cs.onSurface.withValues(alpha: 0.5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
