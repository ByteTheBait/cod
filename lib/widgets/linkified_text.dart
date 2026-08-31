import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders [text] with any URLs/emails as tappable links that open in the
/// system browser / mail client.
class LinkifiedText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign textAlign;

  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    this.linkStyle,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.textAlign = TextAlign.start,
  });

  static final _urlRe = RegExp(
    r'(https?://[^\s<>"()]+|www\.[^\s<>"()]+|'
    r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})',
  );

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final linkColor = Theme.of(context).colorScheme.primary;
    final link = linkStyle ??
        baseStyle.copyWith(
          color: linkColor,
          decoration: TextDecoration.underline,
          decorationColor: linkColor,
        );

    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _urlRe.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final raw = m.group(0)!;
      final uri = _toUri(raw);
      spans.add(TextSpan(
        text: raw,
        style: link,
        recognizer: uri == null
            ? null
            : (TapGestureRecognizer()
              ..onTap = () => _open(uri)),
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }

  Uri? _toUri(String raw) {
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Uri.parse(raw);
    }
    if (raw.startsWith('www.')) {
      return Uri.parse('https://$raw');
    }
    // Looks like an email address.
    if (raw.contains('@') && raw.contains('.')) {
      return Uri(scheme: 'mailto', path: raw);
    }
    return null;
  }

  Future<void> _open(Uri uri) async {
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        // Fall back to in-app for mailto etc.
        await launchUrl(uri);
      }
    } catch (_) {}
  }
}
