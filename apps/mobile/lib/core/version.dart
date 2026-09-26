import 'dart:io';

/// This build's version. Release builds set it from the tag
/// (--dart-define=SKYLINE_VERSION=1.2.3; the release workflow checks it matches
/// pubspec.yaml). The server compares it with its minimum (board 42).
const appVersion = String.fromEnvironment('SKYLINE_VERSION', defaultValue: '1.0.0');

/// Sent with every request: "1.0.0+android".
String get appVersionHeader => '$appVersion+${Platform.operatingSystem}';

/// [a] < [b] as dotted versions ("1.10.0" > "1.9.3"); malformed counts as 0.0.0.
bool versionBelow(String a, String b) {
  List<int> parts(String v) {
    final p = v.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    while (p.length < 3) {
      p.add(0);
    }
    return p;
  }

  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] < y[i];
  }
  return false;
}
