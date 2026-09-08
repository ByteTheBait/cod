import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/task.dart';
import '../state/providers.dart';
import '../widgets/task_tile.dart';
import 'task_detail_screen.dart';

class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider);
    final ttlDays = ref.watch(configProvider).taskTtlDays;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Tasks')),
      body: tasks.isEmpty
          ? _EmptyTasks(onAdd: () => _showAddDialog(context, ref))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: tasks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final task = tasks[i];
                return TaskTile(
                  task: task,
                  ttlDays: ttlDays,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TaskDetailScreen(taskId: task.id),
                    ),
                  ),
                  onStatusTap: () =>
                      ref.read(tasksProvider.notifier).cycleStatus(task.id),
                  onRunTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          TaskDetailScreen(taskId: task.id, autoRun: true),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context, ref),
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _AddTaskSheet(
        onAdd: (title, desc, skill) => ref
            .read(tasksProvider.notifier)
            .add(title: title, description: desc, skill: skill),
      ),
    );
  }
}

class _AddTaskSheet extends StatefulWidget {
  final void Function(String title, String description, TaskSkill skill) onAdd;
  const _AddTaskSheet({required this.onAdd});

  @override
  State<_AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<_AddTaskSheet> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  TaskSkill _skill = TaskSkill.general;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'New task',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _titleCtrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Title'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descCtrl,
            decoration: const InputDecoration(hintText: 'Description (optional)'),
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: TaskSkill.values.map((s) {
              final isActive = _skill == s;
              return GestureDetector(
                onTap: () => setState(() => _skill = s),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isActive ? s.color.withValues(alpha: 0.15) : cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isActive ? s.color.withValues(alpha: 0.5) : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(s.icon, size: 13, color: isActive ? s.color : cs.onSurface.withValues(alpha: 0.5)),
                      const SizedBox(width: 5),
                      Text(
                        s.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isActive ? s.color : cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              if (_titleCtrl.text.trim().isEmpty) return;
              widget.onAdd(_titleCtrl.text.trim(), _descCtrl.text.trim(), _skill);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(backgroundColor: cs.primary),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

class _EmptyTasks extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyTasks({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.checklist_outlined, size: 48, color: cs.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(
            'No tasks yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a task'),
          ),
        ],
      ),
    );
  }
}
