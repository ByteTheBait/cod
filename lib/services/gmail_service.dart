import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/google_oauth.dart';
import '../models/email_model.dart';

const _authUrl = 'https://accounts.google.com/o/oauth2/v2/auth';
const _tokenUrl = 'https://oauth2.googleapis.com/token';
const _gmailBase = 'https://gmail.googleapis.com/gmail/v1/users/me';
const _scope =
    'https://www.googleapis.com/auth/gmail.modify '
    'https://www.googleapis.com/auth/calendar '
    'email';

const _prefAccessToken = 'gmail_access_token';
const _prefRefreshToken = 'gmail_refresh_token';
const _prefExpiry = 'gmail_expiry';
const _prefUserEmail = 'gmail_user_email';

class GmailService {
  static final GmailService instance = GmailService._();
  GmailService._();

  // ── credentials ─────────────────────────────────────────────────────────────

  // Exposed so GCalService can reuse the same token
  Future<String> get accessToken => _accessToken();

  Future<bool> get isConnected async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_prefRefreshToken) ?? '').isNotEmpty;
  }

  Future<String> get userEmail async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefUserEmail) ?? '';
  }

  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefAccessToken);
    await prefs.remove(_prefRefreshToken);
    await prefs.remove(_prefExpiry);
    await prefs.remove(_prefUserEmail);
  }

  // ── OAuth flow (local redirect server) ──────────────────────────────────────

  Future<String> connect() async {
    if (kGoogleClientId.isEmpty || kGoogleClientSecret.isEmpty) {
      throw Exception(
          'App was built without Google credentials. Rebuild with --dart-define.');
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final redirectUri = 'http://127.0.0.1:$port/callback';

    final authUri = Uri.parse(_authUrl).replace(queryParameters: {
      'client_id': kGoogleClientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': _scope,
      'access_type': 'offline',
      'prompt': 'consent',
    });

    await launchUrl(authUri, mode: LaunchMode.externalApplication);

    String? code;
    await for (final req in server) {
      code = req.uri.queryParameters['code'];
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '<html><body style="font-family:sans-serif;padding:40px">'
          '<h2>✓ Connected to Gmail</h2>'
          '<p>You can close this tab and return to cod.</p>'
          '</body></html>',
        );
      await req.response.close();
      await server.close();
      break;
    }

    if (code == null) throw Exception('No code received from OAuth callback.');

    await _exchangeCode(code, kGoogleClientId, kGoogleClientSecret, redirectUri);
    return await userEmail;
  }

  Future<void> _exchangeCode(
      String code, String clientId, String clientSecret, String redirectUri) async {
    final resp = await http.post(Uri.parse(_tokenUrl), body: {
      'code': code,
      'client_id': clientId,
      'client_secret': clientSecret,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
    });

    if (resp.statusCode != 200) {
      throw Exception('Token exchange failed: ${resp.body}');
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefAccessToken, json['access_token'] as String);
    if (json['refresh_token'] != null) {
      await prefs.setString(_prefRefreshToken, json['refresh_token'] as String);
    }
    final expiry = DateTime.now().add(Duration(seconds: json['expires_in'] as int));
    await prefs.setString(_prefExpiry, expiry.toIso8601String());

    // Fetch user email
    final profile = await http.get(
      Uri.parse('https://www.googleapis.com/oauth2/v1/userinfo'),
      headers: {'authorization': 'Bearer ${json['access_token']}'},
    );
    if (profile.statusCode == 200) {
      final pj = jsonDecode(profile.body) as Map<String, dynamic>;
      await prefs.setString(_prefUserEmail, pj['email'] as String? ?? '');
    }
  }

  Future<String> _accessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final expiryStr = prefs.getString(_prefExpiry);
    if (expiryStr != null) {
      final expiry = DateTime.parse(expiryStr);
      if (DateTime.now().isAfter(expiry.subtract(const Duration(minutes: 2)))) {
        await _refreshToken(prefs);
      }
    }
    return prefs.getString(_prefAccessToken) ?? '';
  }

  Future<void> _refreshToken(SharedPreferences prefs) async {
    final refresh = prefs.getString(_prefRefreshToken) ?? '';
    if (refresh.isEmpty) throw Exception('No refresh token — reconnect Gmail.');

    final resp = await http.post(Uri.parse(_tokenUrl), body: {
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': kGoogleClientId,
      'client_secret': kGoogleClientSecret,
    });

    if (resp.statusCode != 200) {
      throw Exception('Token refresh failed: ${resp.body}');
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    await prefs.setString(_prefAccessToken, json['access_token'] as String);
    final expiry = DateTime.now().add(Duration(seconds: json['expires_in'] as int));
    await prefs.setString(_prefExpiry, expiry.toIso8601String());
  }

  // ── Gmail API ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _get(String path) async {
    final token = await _accessToken();
    final resp = await http.get(
      Uri.parse('$_gmailBase/$path'),
      headers: {'authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Gmail GET $path → ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final token = await _accessToken();
    final resp = await http.post(
      Uri.parse('$_gmailBase/$path'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200 && resp.statusCode != 204) {
      throw Exception('Gmail POST $path → ${resp.statusCode}: ${resp.body}');
    }
    if (resp.body.isEmpty) return {};
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<List<GmailThread>> listThreads({int maxResults = 25}) async {
    final data = await _get(
        'threads?maxResults=$maxResults&labelIds=INBOX');
    final items = data['threads'] as List? ?? [];
    final threads = <GmailThread>[];
    for (final item in items) {
      try {
        final thread = await _getThreadHeader(item['id'] as String);
        threads.add(thread);
      } catch (_) {}
    }
    return threads;
  }

  Future<GmailThread> _getThreadHeader(String id) async {
    final data = await _get(
        'threads/$id?format=metadata'
        '&metadataHeaders=Subject'
        '&metadataHeaders=From'
        '&metadataHeaders=Date');
    final messages = (data['messages'] as List? ?? []);
    if (messages.isEmpty) {
      return GmailThread(
        id: id,
        subject: '(no subject)',
        from: '',
        snippet: data['snippet'] as String? ?? '',
        date: DateTime.now(),
        isUnread: false,
      );
    }
    final first = messages.first as Map<String, dynamic>;
    final last = messages.last as Map<String, dynamic>;
    final headers = _headers(first);
    final lastHeaders = _headers(last);
    final labels = (last['labelIds'] as List?)?.cast<String>() ?? [];

    return GmailThread(
      id: id,
      subject: headers['Subject'] ?? '(no subject)',
      from: headers['From'] ?? '',
      snippet: data['snippet'] as String? ?? '',
      date: _parseDate(lastHeaders['Date'] ?? ''),
      isUnread: labels.contains('UNREAD'),
    );
  }

  Future<GmailThread> loadMessages(String threadId) async {
    final data = await _get('threads/$threadId?format=full');
    final raw = (data['messages'] as List? ?? []);
    final msgs = raw.map((m) => _parseMessage(m as Map<String, dynamic>)).toList();
    final first = msgs.isNotEmpty ? msgs.first : null;

    return GmailThread(
      id: threadId,
      subject: first?.subject ?? '(no subject)',
      from: first?.from ?? '',
      snippet: data['snippet'] as String? ?? '',
      date: msgs.isNotEmpty ? msgs.last.date : DateTime.now(),
      isUnread: false,
      messages: msgs,
    );
  }

  GmailMessage _parseMessage(Map<String, dynamic> msg) {
    final headers = _headers(msg);
    return GmailMessage(
      id: msg['id'] as String,
      from: headers['From'] ?? '',
      to: headers['To'] ?? '',
      subject: headers['Subject'] ?? '',
      body: _decodeBody(msg['payload'] as Map<String, dynamic>? ?? {}),
      date: _parseDate(headers['Date'] ?? ''),
      messageId: headers['Message-ID'],
    );
  }

  Map<String, String> _headers(Map<String, dynamic> msg) {
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};
    final headers = (payload['headers'] as List? ?? []).cast<Map>();
    return {for (final h in headers) h['name'] as String: h['value'] as String};
  }

  String _decodeBody(Map<String, dynamic> payload) {
    // Try direct body
    final body = payload['body'] as Map<String, dynamic>?;
    if (body != null && (body['data'] as String? ?? '').isNotEmpty) {
      return _b64decode(body['data'] as String);
    }

    // Try parts
    for (final part in (payload['parts'] as List? ?? [])) {
      final p = part as Map<String, dynamic>;
      final mime = p['mimeType'] as String? ?? '';
      if (mime == 'text/plain') {
        final b = p['body'] as Map<String, dynamic>?;
        if (b != null && (b['data'] as String? ?? '').isNotEmpty) {
          return _b64decode(b['data'] as String);
        }
      }
      // Recurse into multipart
      if (mime.startsWith('multipart/')) {
        final nested = _decodeBody(p);
        if (nested.isNotEmpty) return nested;
      }
    }
    return '';
  }

  String _b64decode(String data) {
    try {
      final normalized = data.replaceAll('-', '+').replaceAll('_', '/');
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  DateTime _parseDate(String value) {
    try {
      return HttpDate.parse(value);
    } catch (_) {
      try {
        return DateTime.parse(value);
      } catch (_) {
        return DateTime.now();
      }
    }
  }

  Future<void> markRead(String threadId) async {
    await _post('threads/$threadId/modify', {
      'removeLabelIds': ['UNREAD'],
    });
  }

  Future<void> sendReply({
    required String from,
    required String to,
    required String subject,
    required String body,
    String? inReplyTo,
    String? references,
  }) async {
    final subjectLine = subject.startsWith('Re:') ? subject : 'Re: $subject';
    await sendMessage(
      from: from,
      to: to,
      subject: subjectLine,
      body: body,
      inReplyTo: inReplyTo,
      references: references,
    );
  }

  /// Send a brand-new email (compose). `inReplyTo`/`references` are only
  /// used when composing a reply via [sendReply].
  Future<void> sendMessage({
    required String from,
    required String to,
    required String subject,
    required String body,
    String? inReplyTo,
    String? references,
    List<String>? bcc,
    List<String>? cc,
  }) async {
    final mime = StringBuffer()
      ..writeln('MIME-Version: 1.0')
      ..writeln('From: $from')
      ..writeln('To: $to');
    if (cc != null && cc.isNotEmpty) mime.writeln('Cc: ${cc.join(', ')}');
    if (bcc != null && bcc.isNotEmpty) mime.writeln('Bcc: ${bcc.join(', ')}');
    mime
      ..writeln('Subject: $subject')
      ..writeln('Content-Type: text/plain; charset=utf-8')
      ..writeln('Content-Transfer-Encoding: quoted-printable');
    if (inReplyTo != null) mime.writeln('In-Reply-To: $inReplyTo');
    if (references != null) mime.writeln('References: $references');
    mime
      ..writeln()
      ..write(body);

    final raw = base64Url.encode(utf8.encode(mime.toString()));
    await _post('messages/send', {'raw': raw});
  }
}
