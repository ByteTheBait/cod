import 'package:flutter/material.dart';
import '../models/task.dart';

class SkillBadge extends StatelessWidget {
  final TaskSkill skill;
  const SkillBadge({super.key, required this.skill});

  @override
  Widget build(BuildContext context) {
    if (skill == TaskSkill.general) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: skill.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: skill.color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(skill.icon, size: 10, color: skill.color),
          const SizedBox(width: 3),
          Text(
            skill.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: skill.color,
            ),
          ),
        ],
      ),
    );
  }
}
