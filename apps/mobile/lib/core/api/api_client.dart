import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../crypto/device_crypto.dart';
import '../version.dart';
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
  static const _slow = Duration(minutes: 3);

  Future<Session> session() async {
    final s = await sessions.read();
    if (s == null) throw SignedOutException();
    return s.accessStale ? _refresh(s) : s;
  }

  Future<Object?> get(String path) => _call('GET', path);
  Future<Object?> post(String path, [Object? body]) => _call('POST', path, body);
  Future<Object?> put(String path, [Object? body]) => _call('PUT', path, body);
  Future<Object?> delete(String path) => _call('DELETE', path);

  /// PUTs raw bytes (one part of an encrypted upload). 8 MB can take a while
  /// on a slow link, so the timeout is generous.
  Future<void> putBytes(String path, Uint8List bytes) async {
    var s = await session();
    var res = await _send('PUT', path, null, s.accessToken, raw: bytes, timeout: _slow);
    if (res.statusCode == 401) {
      s = await _refresh(s);
      res = await _send('PUT', path, null, s.accessToken, raw: bytes, timeout: _slow);
      if (res.statusCode == 401) throw SignedOutException();
    }
    _decode(res);
  }

  /// Streams a download into [out], resuming from however much of it is
  /// already there (HTTP Range). [onProgress] gets (bytes so far, total).
  Future<void> download(String path, File out, {void Function(int got, int total)? onProgress}) async {
    Future<http.StreamedResponse> open(String token, int from) async {
      final req = http.Request('GET', url(path))
        ..headers['authorization'] = 'Bearer $token'
        ..headers['x-skyline-app'] = appVersionHeader;
      if (from > 0) req.headers['range'] = 'bytes=$from-';
      try {
        return await _http.send(req).timeout(_timeout);
      } on Exception {
        throw ApiException(0);
      }
    }

    var from = await out.exists() ? await out.length() : 0;
    var s = await session();
    var res = await open(s.accessToken, from);
    if (res.statusCode == 401) {
      await res.stream.drain<void>();
      s = await _refresh(s);
      res = await open(s.accessToken, from);
      if (res.statusCode == 401) throw SignedOutException();
    }
    if (res.statusCode == 416) {
      // Nothing past what we hold: the file is complete. (Decryption checks
      // the hash and the tag, so a bad file is caught there.)
      await res.stream.drain<void>();
      onProgress?.call(from, from);
      return;
    }
    if (res.statusCode != 200 && res.statusCode != 206) {
      await res.stream.drain<void>();
      throw ApiException(res.statusCode);
    }
    if (res.statusCode == 200) from = 0; // the server sent it all
    final total = from + (res.contentLength ?? 0);
    final sink = out.openWrite(mode: from == 0 ? FileMode.write : FileMode.append);
    var got = from;
    try {
      await for (final chunk in res.stream.timeout(_timeout)) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
    } on Exception {
      throw ApiException(0); // resumable: the bytes so far are kept
    } finally {
      await sink.close();
    }
  }

  /// Unauthenticated POST (activation).
  /// A GET that needs no session (the release manifest, board 42).
  Future<Object?> getPublic(String path) async => _decode(await _send('GET', path, null, null));

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

  Future<http.Response> _send(String method, String path, Object? body, String? token,
      {Uint8List? raw, Duration timeout = _timeout}) async {
    final req = http.Request(method, url(path));
    req.headers['x-skyline-app'] = appVersionHeader;
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    } else if (raw != null) {
      req.headers['content-type'] = 'application/octet-stream';
      req.bodyBytes = raw;
    }
    try {
      return await http.Response.fromStream(await _http.send(req).timeout(timeout));
    } on TimeoutException {
      throw ApiException(0);
    } on http.ClientException {
      throw ApiException(0);
    } on Exception {
      throw ApiException(0);
    }
  }

  /// [path] (which may carry a query) under the API base, keeping the base's
  /// own path: https://example.org/api + /me/inbox -> https://example.org/api/me/inbox.
  /// (Uri.resolve would drop "/api".)
  Uri url(String path) => under(base, path);

  static Uri under(Uri base, String path) {
    final q = path.indexOf('?');
    final p = q < 0 ? path : path.substring(0, q);
    final joined = base.replace(path: AppConfig.joinPath(base.path, p));
    return q < 0 ? joined : Uri.parse('$joined${path.substring(q)}');
  }

  /// Board 42: set when the server said this version is no longer supported
  /// (426), with the minimum it named. The app shows "Please update".
  static final updateRequired = ValueNotifier<String?>(null);

  Object? _decode(http.Response res) {
    if (res.statusCode == 426) {
      final body = res.body.isEmpty ? null : jsonDecode(res.body);
      updateRequired.value = body is Map ? (body['minimum'] as String? ?? '') : '';
    }
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
