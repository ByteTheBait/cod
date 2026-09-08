import 'package:flutter/material.dart' show IconData, Icons;

class Tool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const Tool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, dynamic> toClaudeJson() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };

  Map<String, dynamic> toOpenAIJson() => {
        'type': 'function',
        'function': {'name': name, 'description': description, 'parameters': inputSchema},
      };

  Map<String, dynamic> toGeminiJson() => {
        'name': name,
        'description': description,
        'parameters': inputSchema,
      };
}

/// Behavioural modes for the Code agent.
enum CodeMode {
  // Fully autonomous — run every tool without asking.
  yolo,
  // Ask for approval before every tool call.
  ask,
  // Plan first: present a plan, then confirm before each step.
  plan,
  // Edit-only: file read/write/edit tools, no shell or web, no confirmation.
  edit,
}

extension CodeModeX on CodeMode {
  String get label => switch (this) {
        CodeMode.yolo => 'YOLO',
        CodeMode.ask => 'Ask',
        CodeMode.plan => 'Plan',
        CodeMode.edit => 'Edit',
      };

  /// Description shown in the mode picker.
  String get description => switch (this) {
        CodeMode.yolo => 'Fully autonomous. Runs every tool without asking.',
        CodeMode.ask => 'Asks for approval before every tool call.',
        CodeMode.plan => 'Presents a plan, then confirms before each step.',
        CodeMode.edit => 'File edits only — no shell or web, no confirmation.',
      };

  IconData get icon => switch (this) {
        CodeMode.yolo => Icons.rocket_launch,
        CodeMode.ask => Icons.question_mark,
        CodeMode.plan => Icons.list_alt,
        CodeMode.edit => Icons.edit_note,
      };

  /// Whether tool calls should pause for user approval before running.
  bool get requiresApproval => this == CodeMode.ask || this == CodeMode.plan;

  /// The agent is only allowed to read/write/edit files.
  bool get editOnly => this == CodeMode.edit;
}

class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> input;

  const ToolCall({required this.id, required this.name, required this.input});
}

sealed class AgentEvent {
  const AgentEvent();
}

class AgentText extends AgentEvent {
  final String text;
  const AgentText(this.text);
}

class AgentToolStart extends AgentEvent {
  final ToolCall call;
  const AgentToolStart(this.call);
}

class AgentToolDone extends AgentEvent {
  final String toolName;
  final String result;
  const AgentToolDone(this.toolName, this.result);
}

class AgentCommandOutput extends AgentEvent {
  final String line;
  const AgentCommandOutput(this.line);
}

class AgentComplete extends AgentEvent {
  const AgentComplete();
}

class AgentError extends AgentEvent {
  final String message;
  const AgentError(this.message);
}
