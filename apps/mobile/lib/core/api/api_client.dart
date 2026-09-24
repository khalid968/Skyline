import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../crypto/device_crypto.dart';
import 'session.dart';

/// A failed call. `status` is the HTTP status (0 when the server could not be
/// reached at all), `body` the decoded JSON body when there was one.
class ApiException implements Exception {
  ApiException(this.status, [this.body]);
  final int status;
  final Object? body;

  bool get offline => status == 0;
  @override
  String toString() => 'ApiException($status)';
}

/// The session ended for good: the device was revoked, the account suspended,
/// or the refresh token was used elsewhere. The app must activate again.
class SignedOutException implements Exception {}

/// Talks to the Skyline server as this device. Access tokens last 15 minutes;
/// before one expires (or when the server says it has), the client swaps the
/// refresh token for a new pair, proving possession of the device key with a
/// fresh Ed25519 signature (Phase 5). A stolen refresh token alone is useless.
class ApiClient {
  ApiClient({
    required this.base,
    required this.sessions,
    required this.crypto,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Uri base;
  final SessionStore sessions;
  final CryptoDevice crypto;
  final http.Client _http;
  Future<Session>? _refreshing;

  static const _timeout = Duration(seconds: 20);

  Future<Session> session() async {
    final s = await sessions.read();
    if (s == null) throw SignedOutException();
    return s.accessStale ? _refresh(s) : s;
  }

  Future<Object?> get(String path) => _call('GET', path);
  Future<Object?> post(String path, [Object? body]) => _call('POST', path, body);
  Future<Object?> put(String path, [Object? body]) => _call('PUT', path, body);

  /// Unauthenticated POST (activation).
  Future<Object?> postPublic(String path, Object body) async {
    final res = await _send('POST', path, body, null);
    return _decode(res);
  }

  Future<Object?> _call(String method, String path, [Object? body]) async {
    var s = await session();
    var res = await _send(method, path, body, s.accessToken);
    if (res.statusCode == 401) {
      // The token may have been rejected early (clock skew, server restart):
      // refresh once and retry.
      s = await _refresh(s);
      res = await _send(method, path, body, s.accessToken);
      if (res.statusCode == 401) {
        throw SignedOutException();
      }
    }
    return _decode(res);
  }

  Future<http.Response> _send(String method, String path, Object? body, String? token) async {
    final req = http.Request(method, base.resolve(path));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    try {
      return await http.Response.fromStream(await _http.send(req).timeout(_timeout));
    } on TimeoutException {
      throw ApiException(0);
    } on http.ClientException {
      throw ApiException(0);
    } on Exception {
      throw ApiException(0);
    }
  }

  Object? _decode(http.Response res) {
    Object? body;
    if (res.body.isNotEmpty) {
      try {
        body = jsonDecode(res.body);
      } on FormatException {
        body = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    throw ApiException(res.statusCode, body);
  }

  // One refresh at a time: concurrent callers wait for the same one, because a
  // refresh token works exactly once (reusing it revokes the whole session).
  Future<Session> _refresh(Session s) {
    return _refreshing ??= () async {
      try {
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final sig = await crypto.sign(
          message: utf8.encode('skyline-refresh:v1:$ts:${s.refreshToken}'),
        );
        final res = await _send(
          'POST',
          '/auth/refresh',
          {
            'refreshToken': s.refreshToken,
            'timestamp': ts,
            'signature': base64.encode(sig),
          },
          null,
        );
        if (res.statusCode == 401) {
          await sessions.clear();
          throw SignedOutException();
        }
        final j = _decode(res)! as Map<String, Object?>;
        final next = s.withTokens(
          accessToken: j['accessToken']! as String,
          accessExpiresAt: DateTime.parse(j['accessExpiresAt']! as String),
          refreshToken: j['refreshToken']! as String,
        );
        await sessions.write(next);
        return next;
      } finally {
        _refreshing = null;
      }
    }();
  }
}
