import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    final process = await Process.start(
      'sh', ['-c', command],
      workingDirectory: workingDir,
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
