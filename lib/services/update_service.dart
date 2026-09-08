import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class UpdateInfo {
  final String latestVersion;
  final String releaseUrl;
  final bool isUpdateAvailable;

  const UpdateInfo({
    required this.latestVersion,
    required this.releaseUrl,
    required this.isUpdateAvailable,
  });
}

class UpdateService {
  static const _lastCheckKey = 'update_last_check_ms';
  static const _latestVersionKey = 'update_latest_version';
  static const _releaseUrlKey = 'update_release_url';
  static const _cacheDuration = Duration(hours: 24);
  static const _repo = 'Pkill-MyDaemons/cod';

  Future<UpdateInfo?> check(String currentVersion, {bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();

    if (!force) {
      final lastCheck = prefs.getInt(_lastCheckKey) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - lastCheck;
      if (age < _cacheDuration.inMilliseconds) {
        final cached = _fromPrefs(prefs, currentVersion);
        if (cached != null) return cached;
      }
    }

    try {
      final resp = await http.get(
        Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) return null;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String).replaceFirst('v', '');
      final url = data['html_url'] as String;

      await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.setString(_latestVersionKey, tag);
      await prefs.setString(_releaseUrlKey, url);

      return UpdateInfo(
        latestVersion: tag,
        releaseUrl: url,
        isUpdateAvailable: isNewer(tag, currentVersion),
      );
    } catch (_) {
      return _fromPrefs(prefs, currentVersion);
    }
  }

  UpdateInfo? _fromPrefs(SharedPreferences prefs, String currentVersion) {
    final tag = prefs.getString(_latestVersionKey);
    final url = prefs.getString(_releaseUrlKey);
    if (tag == null || url == null) return null;
    return UpdateInfo(
      latestVersion: tag,
      releaseUrl: url,
      isUpdateAvailable: isNewer(tag, currentVersion),
    );
  }

  /// Whether [latest] is a newer version than [current]. Compares the numeric
  /// major/minor/patch segments; any non-numeric or missing segment is treated
  /// as zero, so build metadata (`+1`) and prerelease suffixes (`-beta`) do
  /// not affect the comparison.
  static bool isNewer(String latest, String current) {
    final l = _parse(latest);
    final c = _parse(current);
    for (int i = 0; i < 3; i++) {
      if (l[i] > c[i]) return true;
      if (l[i] < c[i]) return false;
    }
    return false;
  }

  static List<int> _parse(String v) {
    // Strip build metadata (+N) and prerelease (-suffix) so they don't
    // interfere with numeric comparison.
    final clean = v.split('+').first.split('-').first;
    final parts = clean.split('.');
    return List.generate(3, (i) => i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0);
  }
}
