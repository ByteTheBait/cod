import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A multiline [TextField] for AI prompts where:
/// - **Enter** inserts a newline
/// - **Shift+Enter** triggers [onSend]
///
/// This gives a chat-like experience on desktop: you can compose multi-line
/// prompts with Enter and send with Shift+Enter.
class AiInputField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final TextStyle? hintStyle;
  final VoidCallback? onSend;
  final int maxLines;
  final int minLines;
  final TextStyle? style;
  final EdgeInsetsGeometry? contentPadding;
  final bool isDense;
  final TextInputAction textInputAction;
  final TextCapitalization textCapitalization;

  const AiInputField({
    super.key,
    required this.controller,
    required this.hintText,
    this.hintStyle,
    this.onSend,
    this.maxLines = 5,
    this.minLines = 1,
    this.style,
    this.contentPadding,
    this.isDense = false,
    this.textInputAction = TextInputAction.newline,
    this.textCapitalization = TextCapitalization.none,
  });

  @override
  State<AiInputField> createState() => _AiInputFieldState();
}

class _AiInputFieldState extends State<AiInputField> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode()..onKeyEvent = _handleKey;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }

    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+Enter → send the message.
      widget.onSend?.call();
    } else {
      // Enter → insert a newline at the cursor.
      _insertNewline();
    }
    return KeyEventResult.handled;
  }

  void _insertNewline() {
    final ctrl = widget.controller;
    final text = ctrl.text;
    final sel = ctrl.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final newText = text.replaceRange(start, end, '\n');
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      textInputAction: widget.textInputAction,
      textCapitalization: widget.textCapitalization,
      style: widget.style,
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle: widget.hintStyle,
        contentPadding: widget.contentPadding,
        isDense: widget.isDense,
      ),
    );
  }
}
