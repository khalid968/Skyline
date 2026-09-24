import 'dart:io';

/// Where the Skyline server is. Set at build time:
///
///   flutter run --dart-define=SKYLINE_API=https://skyline.example.org
///
/// Development defaults: the Android emulator reaches the host PC at 10.0.2.2;
/// everything else uses localhost. Plain HTTP is allowed only in debug builds
/// (Android: src/debug network security config). Production is HTTPS only.
abstract final class AppConfig {
  static const _fromDefine = String.fromEnvironment('SKYLINE_API');

  static Uri get apiBase {
    if (_fromDefine.isNotEmpty) return Uri.parse(_fromDefine);
    return Uri.parse(
      Platform.isAndroid ? 'http://10.0.2.2:3000' : 'http://localhost:3000',
    );
  }

  static Uri get socketUri {
    final base = apiBase;
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws',
    );
  }
}
