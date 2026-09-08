import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Environment variables the background agent processes must never inherit.
const _bgStripEnv = {
  'AWS_SECRET_ACCESS_KEY', 'AWS_ACCESS_KEY_ID', 'AWS_SESSION_TOKEN',
  'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY',
  'GITHUB_TOKEN', 'GH_TOKEN', 'NPM_TOKEN', 'PYPI_TOKEN',
  'DOCKER_PASSWORD', 'GOOGLE_APPLICATION_CREDENTIALS', 'GOOGLE_CLIENT_SECRET',
  'SUPABASE_SERVICE_ROLE', 'SSH_PRIVATE_KEY', 'DATABASE_URL',
};

/// A single long-running background process started by the agent.
class BackgroundJob {
  final String id;
  final String command;
  final DateTime startedAt;
  final Process process;
  final StringBuffer output = StringBuffer();
  bool _done = false;
  int? exitCode;

  BackgroundJob({
    required this.id,
    required this.command,
    required this.startedAt,
    required this.process,
  });

  bool get isRunning => !_done;

  void markDone(int? code) {
    _done = true;
    exitCode = code;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'command': command,
        'startedAt': startedAt.toIso8601String(),
        'running': isRunning,
        'exitCode': exitCode,
        'output': output.toString(),
      };
}

/// Manages long-running shell processes so the agent can start a server,
/// build, or watcher in the background and poll it later without blocking
/// the agent loop.
class BackgroundProcessManager {
  static final BackgroundProcessManager instance = BackgroundProcessManager._();
  BackgroundProcessManager._();

  final Map<String, BackgroundJob> _jobs = {};
  int _counter = 0;
  static const int _maxOutputChars = 20000;

  /// Start a command in the background and return its job id.
  Future<String> start(String command, {String? workingDir}) async {
    if (Platform.isIOS || Platform.isAndroid) {
      throw StateError('Shell execution is not supported on this platform.');
    }
    final id = 'bg-${++_counter}';

    // Never pass sensitive env values to a background process — it may be a
    // shell the agent controls, and secrets must not leak out of it. PATH is
    // left as-is so legitimate build/server toolchains (nvm, pyenv, etc.)
    // keep working; the restricted sandbox already normalises PATH separately.
    final env = Map<String, String>.from(Platform.environment);
    for (final k in _bgStripEnv) {
      env.remove(k);
    }

    final process = await Process.start(
      'sh', ['-c', command],
      workingDirectory: workingDir,
      environment: env,
      runInShell: false,
    );
    final job = BackgroundJob(
      id: id,
      command: command,
      startedAt: DateTime.now(),
      process: process,
    );
    _jobs[id] = job;

    void append(String s) {
      if (job.output.length < _maxOutputChars) {
        job.output.write(s);
      }
    }

    process.stdout.transform(utf8.decoder).listen(append);
    process.stderr.transform(utf8.decoder).listen((s) => append('stderr: $s'));
    process.exitCode.then((code) => job.markDone(code));
    return id;
  }

  /// Human-readable status + output for a single job.
  String status(String id) {
    final job = _jobs[id];
    if (job == null) return 'No background job with id: $id';
    final out = job.output.toString();
    final truncated = out.length >= _maxOutputChars;
    return 'Job $id: ${job.isRunning ? 'RUNNING' : 'EXITED (code ${job.exitCode})'}\n'
        'Command: ${job.command}\n'
        'Output:\n$out${truncated ? '\n... (output truncated)' : ''}';
  }

  /// Human-readable list of all background jobs.
  String list() {
    if (_jobs.isEmpty) return 'No background jobs.';
    final sb = StringBuffer();
    for (final job in _jobs.values) {
      sb.writeln(
          '${job.id}  ${job.isRunning ? 'RUNNING' : 'EXITED (${job.exitCode})'}  ${job.command}');
    }
    return sb.toString().trim();
  }

  /// Send a kill signal to a running job.
  Future<String> kill(String id) async {
    final job = _jobs[id];
    if (job == null) return 'No background job with id: $id';
    if (!job.isRunning) return 'Job $id already exited (code ${job.exitCode}).';
    job.process.kill();
    return 'Sent kill signal to job $id.';
  }

  void dispose() {
    for (final job in _jobs.values) {
      if (job.isRunning) job.process.kill();
    }
    _jobs.clear();
  }
}
