import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where the Skyline server is. Set at build time:
///
///   flutter run --dart-define=SKYLINE_API=https://skyline.example.org
///
/// Development defaults: the Android emulator reaches the host PC at 10.0.2.2;
/// everything else uses localhost. Plain HTTP is allowed only in debug builds
/// (Android: src/debug network security config). Production is HTTPS only.
abstract final class AppConfig {
  static const _fromDefine = String.fromEnvironment('SKYLINE_API');

  /// Which server this build belongs to, for keeping its data apart on a
  /// desktop: empty for the development build (whose vault and stored keys
  /// keep their original names), otherwise the server's host
  /// ("chat.example.org"). A PC with both a development and a production
  /// Skyline then has two separate vaults, sessions and keys, never one mixed
  /// identity. Phones don't need it (each app is sandboxed, and one package
  /// can't be installed twice), and must not change it: Android 1.0.0 shipped
  /// with the untagged names, and an update that renamed them would lose the
  /// vault.
  static String get storageTag => _fromDefine.isEmpty || Platform.isAndroid || Platform.isIOS
      ? ''
      : Uri.parse(_fromDefine).host;

  /// [name] for this build's stored items: unchanged for development.
  static String tagged(String name) => storageTag.isEmpty ? name : '$name@$storageTag';

  static Uri get apiBase {
    final base = _fromDefine.isNotEmpty
        ? Uri.parse(_fromDefine)
        : Uri.parse(Platform.isAndroid ? 'http://10.0.2.2:3000' : 'http://localhost:3000');
    // A release build talks to its server over HTTPS only, on every platform
    // (Android also refuses cleartext at the OS level).
    if (kReleaseMode && base.scheme != 'https') {
      throw StateError('release builds require an https SKYLINE_API');
    }
    return base;
  }

  /// The server's WebSocket, under the API's own path: production serves the
  /// API at https://<domain>/api, so the socket is /api/ws there.
  static Uri get socketUri {
    final base = apiBase;
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: joinPath(base.path, '/ws'),
    );
  }

  /// "/api" + "/me/inbox" -> "/api/me/inbox"; "" + "/me" -> "/me".
  static String joinPath(String basePath, String path) {
    final b = basePath.endsWith('/') ? basePath.substring(0, basePath.length - 1) : basePath;
    return '$b${path.startsWith('/') ? path : '/$path'}';
  }
}
