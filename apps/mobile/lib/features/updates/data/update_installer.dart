import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'release_service.dart';

enum InstallPhase { idle, downloading, ready, failed }

/// Board 43: "Download and install". On Android and Windows the app fetches
/// the file from the organization's server, checks it against the SHA-256 the
/// server published, then hands it to the system installer (Android asks the
/// person to confirm; Windows opens the signed installer). Anywhere else, or
/// without a checksum, the link opens in the browser (iPhone: TestFlight).
class UpdateInstaller extends ChangeNotifier {
  UpdateInstaller({http.Client? client, Future<Directory> Function()? dir})
      : _client = client ?? http.Client(),
        _dir = dir ?? getTemporaryDirectory;

  final http.Client _client;
  final Future<Directory> Function() _dir;

  InstallPhase phase = InstallPhase.idle;
  double fraction = 0;
  String? problem;
  File? _file;
  bool _disposed = false;

  static bool get inApp => Platform.isAndroid || Platform.isWindows;

  static bool canInstallInApp(Release r) => inApp && r.sha256 != null && r.url.scheme == 'https';

  /// Starts (or finishes) the install for [r].
  Future<void> run(Release r) async {
    if (!canInstallInApp(r)) {
      await launchUrl(r.url, mode: LaunchMode.externalApplication);
      return;
    }
    if (phase == InstallPhase.ready && _file != null) return _open();
    if (phase == InstallPhase.downloading) return;
    _set(InstallPhase.downloading, fraction: 0);
    try {
      final name = r.url.pathSegments.isEmpty ? 'skyline-update' : r.url.pathSegments.last;
      final dir = Directory('${(await _dir()).path}${Platform.pathSeparator}skyline-update');
      await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      final res = await _client.send(http.Request('GET', r.url));
      if (res.statusCode != 200) throw const HttpException('download failed');
      final total = res.contentLength ?? r.size ?? 0;
      final sink = file.openWrite();
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      var done = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        done += chunk.length;
        if (total > 0) _set(InstallPhase.downloading, fraction: done / total);
      }
      await sink.close();
      hasher.close();
      // Never install something that isn't exactly what the server published.
      if (digest.value.toString() != r.sha256) {
        await file.delete();
        throw const FormatException('checksum');
      }
      _file = file;
      _set(InstallPhase.ready, fraction: 1);
      await _open();
    } on FormatException {
      _set(InstallPhase.failed,
          problem: "The download didn't match what your server published, so it wasn't installed.");
    } on Object {
      _set(InstallPhase.failed, problem: "Couldn't download the update. Check your connection and try again.");
    }
  }

  Future<void> _open() async {
    final f = _file!;
    if (Platform.isWindows) {
      // The signed installer closes Skyline, replaces it and can reopen it.
      await Process.start(f.path, const [], mode: ProcessStartMode.detached);
    } else {
      await OpenFilex.open(f.path, type: 'application/vnd.android.package-archive');
    }
  }

  void _set(InstallPhase p, {double? fraction, String? problem}) {
    phase = p;
    if (fraction != null) this.fraction = fraction;
    this.problem = problem;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
