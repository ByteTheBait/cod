import 'package:flutter/material.dart';
import '../models/task.dart';
import 'skill_badge.dart';

class TaskTile extends StatelessWidget {
  final Task task;
  final VoidCallback onTap;
  final VoidCallback onStatusTap;
  final VoidCallback? onRunTap;
  final int ttlDays;

  const TaskTile({
    super.key,
    required this.task,
    required this.onTap,
    required this.onStatusTap,
    this.onRunTap,
    this.ttlDays = 0,
  });

  String? _expiryLabel() {
    final remaining = task.timeUntilExpiry(ttlDays);
    if (remaining == null || remaining.inDays >= 1) return null;
    final h = remaining.inHours;
    final m = remaining.inMinutes % 60;
    if (h > 0) return 'expires in ${h}h';
    if (m > 0) return 'expires in ${m}m';
    return 'expiring';
  }

  Color _expiryColor() {
    final remaining = task.timeUntilExpiry(ttlDays);
    if (remaining == null) return Colors.grey;
    return remaining.inHours < 6 ? Colors.red.shade400 : Colors.amber.shade600;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final expiryLabel = _expiryLabel();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: onStatusTap,
              child: _StatusChip(status: task.status),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          decoration: task.status == TaskStatus.done
                              ? TextDecoration.lineThrough
                              : null,
                          color: task.status == TaskStatus.done
                              ? cs.onSurface.withValues(alpha: 0.45)
                              : cs.onSurface,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (task.description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      task.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      SkillBadge(skill: task.skill),
                      if (task.skill != TaskSkill.general && task.thread.isNotEmpty)
                        const SizedBox(width: 6),
                      if (task.thread.isNotEmpty)
                        Text(
                          '${task.thread.length} message${task.thread.length != 1 ? 's' : ''}',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: cs.primary.withValues(alpha: 0.7),
                              ),
                        ),
                    ],
                  ),
                  if (expiryLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.hourglass_bottom_rounded,
                              size: 10, color: _expiryColor()),
                          const SizedBox(width: 3),
                          Text(
                            expiryLabel,
                            style: TextStyle(
                              fontSize: 10,
                              color: _expiryColor(),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (task.hasUnread)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(shape: BoxShape.circle, color: cs.primary),
              ),
            if (onRunTap != null && task.status != TaskStatus.done)
              IconButton(
                icon: Icon(Icons.play_arrow_rounded,
                    size: 20, color: cs.primary.withValues(alpha: 0.75)),
                tooltip: 'Run agent',
                onPressed: onRunTap,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final TaskStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (status) {
      TaskStatus.todo => (Colors.grey.shade600, Icons.radio_button_unchecked),
      TaskStatus.inProgress => (Colors.amber.shade400, Icons.pending_outlined),
      TaskStatus.done => (Colors.green.shade400, Icons.check_circle_outline),
    };

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}
