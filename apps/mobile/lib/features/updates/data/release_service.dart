import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../core/version.dart';

/// One release, as the server publishes it (GET /app/releases).
class Release {
  Release({required this.version, required this.notes, required this.url, this.size, this.sha256});
  final String version;
  final List<String> notes;

  /// Where this platform's build is: the APK or installer on the server, or
  /// the TestFlight / App Store link.
  final Uri url;
  final int? size;

  /// The file's SHA-256 (hex), checked before an in-app install (board 43).
  final String? sha256;
}

/// Board 42: is there a newer version for this platform, and is this one
/// still supported? Asked at start and every six hours; the answer carries
/// nothing about the person, and asking needs no session.
class ReleaseService extends ChangeNotifier {
  ReleaseService({required ApiClient api}) : this.from(fetch: api.getPublic, base: api.base);

  /// For tests: any source of the release manifest.
  ReleaseService.from({required this.fetch, required this.base});

  final Future<Object?> Function(String path) fetch;
  final Uri base;
  Release? available;
  String? minimum;

  /// When the server last answered (board 43's "Last checked").
  DateTime? checkedAt;
  Timer? _timer;
  bool _disposed = false;

  /// Too old to use at all: the server's minimum is above this build, or the
  /// server already answered 426.
  bool get required =>
      ApiClient.updateRequired.value != null || (minimum != null && versionBelow(appVersion, minimum!));

  void start() {
    unawaited(check());
    _timer = Timer.periodic(const Duration(hours: 6), (_) => unawaited(check()));
    ApiClient.updateRequired.addListener(_changed);
  }

  Future<void> check() async {
    try {
      final j = await fetch('/app/releases') as Map<String, Object?>;
      minimum = j['minimum'] as String?;
      available = parse(j['latest'], base, Platform.operatingSystem);
      checkedAt = DateTime.now();
      _changed();
    } on Object {
      // offline or no release yet: try again later
    }
  }

  /// Board 43's button: true when the server answered.
  Future<bool> checkNow() async {
    final before = checkedAt;
    await check();
    return checkedAt != before;
  }

  /// The release for [platform] if it is newer than this build.
  @visibleForTesting
  static Release? parse(Object? latest, Uri base, String platform) {
    if (latest is! Map) return null;
    final version = latest['version'];
    if (version is! String || !versionBelow(appVersion, version)) return null;
    final item = latest[platform];
    if (item is! Map || item['url'] is! String) return null;
    // A path on our own server ("/downloads/...") is on the site's root, not
    // under /api; a full address (TestFlight) is used as it is.
    final link = Uri.parse(item['url'] as String);
    final url = link.hasScheme ? link : base.replace(path: link.path, query: link.hasQuery ? link.query : null);
    return Release(
      version: version,
      notes: [
        for (final n in (latest['notes'] as List<Object?>? ?? const []))
          if (n is String) n
      ],
      url: url,
      size: (item['size'] as num?)?.toInt(),
      sha256: item['sha256'] is String ? (item['sha256'] as String).toLowerCase() : null,
    );
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    ApiClient.updateRequired.removeListener(_changed);
    super.dispose();
  }
}
