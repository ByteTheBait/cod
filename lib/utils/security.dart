import 'dart:io';

/// Environment variables too sensitive to expose to agent-run shell commands.
/// A prompt is free to run `sh -c '…'`, so any secret that would be inherited
/// by the child process must be scrubbed before execution.
const Set<String> kSensitiveEnvVars = {
  'AWS_SECRET_ACCESS_KEY',
  'AWS_ACCESS_KEY_ID',
  'AWS_SESSION_TOKEN',
  'AWS_SHARED_CREDENTIALS_FILE',
  'AZURE_CLIENT_SECRET',
  'AZURE_TENANT_ID',
  'ANTHROPIC_API_KEY',
  'OPENAI_API_KEY',
  'OPENROUTER_API_KEY',
  'GEMINI_API_KEY',
  'GOOGLE_API_KEY',
  'GROQ_API_KEY',
  'MISTRAL_API_KEY',
  'COHERE_API_KEY',
  'GITHUB_TOKEN',
  'GH_TOKEN',
  'GITLAB_TOKEN',
  'NPM_TOKEN',
  'YARN_NPM_AUTH_TOKEN',
  'PYPI_TOKEN',
  'TWINE_PASSWORD',
  'NUGET_API_KEY',
  'DOCKER_PASSWORD',
  'DOCKER_REGISTRY_PASSWORD',
  'GOOGLE_APPLICATION_CREDENTIALS',
  'GOOGLE_CLIENT_SECRET',
  'SUPABASE_SERVICE_ROLE',
  'SUPABASE_SERVICE_ROLE_KEY',
  'SSH_PRIVATE_KEY',
  'PGPASSWORD',
  'MYSQL_PWD',
  'REDIS_PASSWORD',
  'DATABASE_URL',
  'HEROKU_API_KEY',
  'NETLIFY_AUTH_TOKEN',
  'VERCEL_TOKEN',
  'SLACK_TOKEN',
  'SENTRY_AUTH_TOKEN',
  'STRIPE_SECRET_KEY',
  'STRIPE_PUBLISHABLE_KEY',
  'GCLOUD_KEYFILE_PATH',
  'GOOGLE_PROJECT_ID',
  'SPACES_ACCESS_KEY',
  'SPACES_SECRET_KEY',
  'GCP_SA_KEY',
  'SNOWFLAKE_PASSWORD',
  'JIRA_API_TOKEN',
  'CLAUDE_CODE_OAUTH_TOKEN',
};

/// The current secret *values* (the env vars stripped by [sanitizedEnvironment])
/// so callers can redact them from command output, preventing exfiltration
/// even if a command prints an env var that slipped through a sibling key.
Set<String> currentSecretValues() {
  final env = Platform.environment;
  return {
    for (final k in kSensitiveEnvVars)
      if (env[k] != null && env[k]!.isNotEmpty) env[k]!,
  };
}

/// Replace known secret values in [text] with [REDACTED]. Short (length < 4)
/// values are skipped to avoid over-eager scrubbing.
String redactSecrets(String text, [Set<String>? secretValues]) {
  final secrets = secretValues ?? currentSecretValues();
  if (secrets.isEmpty || text.isEmpty) return text;
  var out = text;
  for (final v in secrets) {
    if (v.isEmpty || v.length < 4) continue;
    out = out.replaceAll(v, 'REDACTED');
  }
  return out;
}

/// Returns a sanitised copy of the current process environment: sensitive
/// secrets are removed so an agent-run command can't read them, and `PATH` is
/// normalised so it can't pick up unexpected binaries.
Map<String, String> sanitizedEnvironment() {
  final env = Map<String, String>.from(Platform.environment);
  for (final k in kSensitiveEnvVars) {
    env.remove(k);
  }
  env['PATH'] =
      '/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin';
  return env;
}

/// A best-effort denylist of destructive / privilege-escalating shell
/// patterns. This is a guardrail, NOT a security boundary — the only robust
/// isolation is an OS-level sandbox (e.g. Docker with `--network=none`).
/// The regex catches common plaintext forms; deliberately obfuscated commands
/// (base64, `\x`, `$IFS`) can still slip through, which is why restricted-mode
/// execution must also scrub the environment and why destructive writes should
/// additionally be routed through the sandbox.
final RegExp kBlockedCommandPattern = RegExp(
  r'(?:'
  r'\b(sudo|su\b|doas)\s|'
  r'\b(chmod\s+[0-7]{3,4}\s+\S+)|'
  r'\bchown\s+\S+\s+/\b|'
  r'\brm\s+(-[A-Za-z]*[rf][A-Za-z]*){1,}\s+\s?[/~].*|'
  r'\bdd\b.*\bof=/dev/|'
  r'\b(mkfs|mkswap|parted|fdisk)\b|'
  r':\s*\(\s*\)\s*\{|'
  r'(?:curl|wget|fetch|lynx)\b.*[|;\s]\s*(?:sh|bash|zsh)\b|'
  r'\b(shutdown|reboot|halt|poweroff)\b|'
  r'\b(launchctl|systemctl)\s+reboot\b'
  r')',
  caseSensitive: false,
);

/// Whether a command string triggers the destructive-command denylist.
bool isCommandBlocked(String command) =>
    kBlockedCommandPattern.hasMatch(command);
