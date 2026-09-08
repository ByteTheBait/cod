import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:highlight/highlight.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/google_oauth.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/scss.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';
import 'app.dart';

/// The folder path passed as a command-line argument (e.g. `Cod /path/to/dir`).
/// On macOS this is the first positional arg after the executable.
String? _cliFolderArg() {
  if (Platform.isIOS || Platform.isAndroid) return null;
  final args = Platform.environment['COD_OPEN_FOLDER'];
  if (args != null && args.isNotEmpty) return args;
  return null;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnonKey);
  _registerLanguages();
  runApp(ProviderScope(
    child: CodApp(initialFolder: _cliFolderArg()),
  ));
}

void _registerLanguages() {
  highlight.registerLanguage('dart', dart);
  highlight.registerLanguage('python', python);
  highlight.registerLanguage('javascript', javascript);
  highlight.registerLanguage('typescript', typescript);
  highlight.registerLanguage('go', go);
  highlight.registerLanguage('rust', rust);
  highlight.registerLanguage('cpp', cpp);
  highlight.registerLanguage('c', cpp); // no separate c.dart; cpp handles both
  highlight.registerLanguage('swift', swift);
  highlight.registerLanguage('kotlin', kotlin);
  highlight.registerLanguage('java', java);
  highlight.registerLanguage('ruby', ruby);
  highlight.registerLanguage('php', php);
  highlight.registerLanguage('bash', bash);
  highlight.registerLanguage('json', json);
  highlight.registerLanguage('yaml', yaml);
  highlight.registerLanguage('xml', xml);
  highlight.registerLanguage('css', css);
  highlight.registerLanguage('scss', scss);
  highlight.registerLanguage('sql', sql);
  highlight.registerLanguage('markdown', markdown);
}
