import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum SandboxType { docker, restricted }

enum ContainerStatus { idle, starting, running, error }

// Environment variables too sensitive to expose to agent-run commands.
// Keep this conservative but broad: anything a command could read that would
// be damaging if printed. The *values* of these are also redacted from any
// command output (see _redact), so a command can't silently exfiltrate them
// via the shell even if a sibling env var slips through.
const _stripEnv = {
  'AWS_SECRET_ACCESS_KEY', 'AWS_ACCESS_KEY_ID', 'AWS_SESSION_TOKEN',
  'AWS_SHARED_CREDENTIALS_FILE', 'AZURE_CLIENT_SECRET', 'AZURE_TENANT_ID',
  'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'GEMINI_API_KEY_1',
  'GEMINI_API_KEY_2', 'GROQ_API_KEY', 'MISTRAL_API_KEY', 'COHERE_API_KEY',
  'GITHUB_TOKEN', 'GH_TOKEN', 'GITLAB_TOKEN', 'NPM_TOKEN', 'YARN_NPM_AUTH_TOKEN',
  'PYPI_TOKEN', 'TWINE_PASSWORD', 'DOCKER_PASSWORD', 'DOCKER_REGISTRY_PASSWORD',
  'GOOGLE_APPLICATION_CREDENTIALS', 'GOOGLE_CLIENT_SECRET', 'SUPABASE_SERVICE_ROLE',
  'SSH_PRIVATE_KEY', 'PGPASSWORD', 'MYSQL_PWD', 'REDIS_PASSWORD', 'DATABASE_URL',
  'HEROKU_API_KEY', 'NETLIFY_AUTH_TOKEN', 'VERCEL_TOKEN', 'SLACK_TOKEN',
  'SENTRY_AUTH_TOKEN', 'STRIPE_SECRET_KEY', 'STRIPE_PUBLISHABLE_KEY',
  'GCLOUD_KEYFILE_PATH', 'GOOGLE_PROJECT_ID', 'SPACES_ACCESS_KEY',
  'SPACES_SECRET_KEY', 'GCP_SA_KEY', 'SNOWFLAKE_PASSWORD', 'JIRA_API_TOKEN',
};

/// Redact known secret values out of a string so a command cannot print them.
/// Called on every merged output line in the restricted sandbox.
String _redact(String text, Set<String> secretValues) {
  if (secretValues.isEmpty || text.isEmpty) return text;
  var out = text;
  for (final v in secretValues) {
    if (v.isEmpty || v.length < 4) continue; // avoid over-eager single-char scrubs
    out = out.replaceAll(v, '[REDACTED]');
  }
  return out;
}

/// The set of current secret *values* (keys stripped from the env) so they can
/// be redacted from output.
Set<String> _currentSecretValues() {
  final env = Platform.environment;
  return {
    for (final k in _stripEnv)
      if (env[k] != null && env[k]!.isNotEmpty) env[k]!,
  };
}

class SandboxService {
  SandboxType _type = SandboxType.restricted;
  String? _containerId;
  ContainerStatus _status = ContainerStatus.idle;
  String _workingDir = '';

  SandboxType get type => _type;
  ContainerStatus get status => _status;
  
  // Allow manual override of sandbox type
  Future<SandboxType> setType(SandboxType newType) async {
    if (_type == newType) return _type;
    
    final wasRunning = _status == ContainerStatus.running;
    if (wasRunning) await stop();
    
    _type = newType;
    
    if (newType == SandboxType.docker && _isMobile) {
      _type = SandboxType.restricted; // Don't allow docker on mobile
      return _type;
    }
    
    return _type;
  }
  
  void setMode(SandboxType mode) {
    _type = mode;
  }
  
  bool get canUseDocker => !_isMobile && _type == SandboxType.docker;

  // Detect whether Docker is available on this platform
  bool get _isMobile => Platform.isIOS || Platform.isAndroid;

  Future<SandboxType> detect() async {
    // Process.run is unavailable on mobile
    if (_isMobile) {
      _type = SandboxType.restricted;
      return _type;
    }
    try {
      final r = await Process.run('docker', ['info', '--format', '{{.ServerVersion}}'])
          .timeout(const Duration(seconds: 4));
      if (r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty) {
        _type = SandboxType.docker;
        return _type;
      }
    } catch (_) {}
    _type = SandboxType.restricted;
    return _type;
  }

  // Start a persistent Docker container for this session
  Future<void> start({
    required String workingDir,
    String image = 'ubuntu:24.04',
    bool networkEnabled = false,
  }) async {
    _workingDir = workingDir;

    if (_status == ContainerStatus.running) return;

    if (_isMobile || _type == SandboxType.restricted) {
      _status = ContainerStatus.running;
      return;
    }

    if (_type == SandboxType.docker && _containerId != null) {
      await stop();
    }

    if (_containerId != null) await stop();

    _status = ContainerStatus.starting;
    final id = 'cod-${DateTime.now().millisecondsSinceEpoch}';

    try {
      // Pull image silently if missing (docker run does this, but explicit pull
      // gives us better error messages)
      await Process.run('docker', ['pull', image])
          .timeout(const Duration(minutes: 3));

      final r = await Process.run('docker', [
        'run', '-d',
        '--name', id,
        '-v', '$workingDir:/workspace:rw',
        '-w', '/workspace',
        '--memory=512m',
        '--cpus=1.0',
        '--pids-limit=128',
        '--security-opt=no-new-privileges',
        if (!networkEnabled) '--network=none',
        image,
        'tail', '-f', '/dev/null', // keep alive
      ]).timeout(const Duration(seconds: 30));

      if (r.exitCode != 0) {
        throw Exception((r.stderr as String).trim());
      }

      _containerId = id;
      _status = ContainerStatus.running;
    } catch (e) {
      _status = ContainerStatus.error;
      rethrow;
    }
  }

  // Execute a shell command in the sandbox (blocking, returns full output)
  Future<String> exec(String command, {String? workingDir}) async {
    if (_isMobile) return 'Shell execution is not supported on this platform.';
    if (_type == SandboxType.docker && _containerId != null) {
      return _execDocker(command);
    }
    return _execRestricted(command, workingDir ?? _workingDir);
  }

  // Execute a shell command and stream output lines as they arrive
  Stream<String> execStream(String command, {String? workingDir}) {
    if (_isMobile) return Stream.value('Shell execution is not supported on this platform.');
    if (_type == SandboxType.docker && _containerId != null) {
      return _execDockerStream(command);
    }
    return _execRestrictedStream(command, workingDir ?? _workingDir);
  }

  Future<String> _execDocker(String command) async {
    final r = await Process.run(
      'docker', ['exec', _containerId!, 'sh', '-c', command],
      runInShell: false,
    ).timeout(const Duration(seconds: 30));
    return _mergeOutput(r);
  }

  Stream<String> _execDockerStream(String command) =>
      _processStream(Process.start('docker', ['exec', _containerId!, 'sh', '-c', command]));

  Future<String> _execRestricted(String command, String? cwd) async {
    final env = _sanitisedEnv();
    final redact = _currentSecretValues();

    final r = await Process.run(
      'sh', ['-c', command],
      workingDirectory: (cwd != null && cwd.isNotEmpty) ? cwd : null,
      environment: env,
      runInShell: false,
    ).timeout(const Duration(seconds: 30));
    return _redact(_mergeOutput(r), redact);
  }

  Stream<String> _execRestrictedStream(String command, String? cwd) {
    final env = _sanitisedEnv();
    final redact = _currentSecretValues();
    return _processStream(
      Process.start(
        'sh', ['-c', command],
        workingDirectory: (cwd != null && cwd.isNotEmpty) ? cwd : null,
        environment: env,
        runInShell: false,
      ),
      redactValues: redact,
    );
  }

  /// Build a sanitised environment: strip known secrets and normalise PATH so
  /// `./bin` surprises and shadowed system binaries can't be reached.
  Map<String, String> _sanitisedEnv() {
    final env = Map<String, String>.from(Platform.environment);
    for (final k in _stripEnv) {
      env.remove(k);
    }
    // Keep HOME visible for relative path convenience but drop any *_KEY files
    // and shell rc files by not adding them (they're not in env anyway).
    env['PATH'] =
        '/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin';
    return env;
  }

  // Merges stdout and stderr of a process into a single line stream.
  // [redactValues] silently scrubs secret values from each emitted line.
  static Stream<String> _processStream(
    Future<Process> processFuture, {
    Set<String> redactValues = const {},
  }) async* {
    final process = await processFuture;

    // Guard against a runaway command that produces no output — kill it so
    // the agent can't block forever waiting on a hung process.
    final killTimer = Timer(const Duration(seconds: 30), () {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });

    try {
      final ctrl = StreamController<String>();
      int pending = 2;
      void done() { if (--pending == 0) ctrl.close(); }
      process.stdout.transform(utf8.decoder).transform(const LineSplitter())
          .listen(
              (l) => ctrl.add(_redact(l, redactValues)),
              onDone: done, onError: (_) => done(), cancelOnError: false);
      process.stderr.transform(utf8.decoder).transform(const LineSplitter())
          .map((l) => _redact('stderr: $l', redactValues))
          .listen(ctrl.add, onDone: done, onError: (_) => done(), cancelOnError: false);
      yield* ctrl.stream;
      await process.exitCode;
    } finally {
      killTimer.cancel();
    }
  }

  String _mergeOutput(ProcessResult r) {
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    final parts = [if (out.isNotEmpty) out, if (err.isNotEmpty) 'stderr:\n$err'];
    return parts.isEmpty ? '(no output)' : parts.join('\n');
  }

  Future<void> stop() async {
    _status = ContainerStatus.idle;
    if (_containerId == null || _isMobile) return;
    try {
      await Process.run('docker', ['rm', '-f', _containerId!])
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
    _containerId = null;
  }

  Future<void> dispose() => stop();
}
