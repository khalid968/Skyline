import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import 'package:video_compress/video_compress.dart' as vc;
import 'package:video_player/video_player.dart';

import '../../../core/api/api_client.dart';
import '../../../src/rust/api/crypto.dart' as rust;
import '../../messages/domain/models.dart';

enum TransferStage { preparing, encrypting, moving }

/// Progress of one upload or download, by message id.
class Transfer {
  const Transfer(this.done, this.total, {this.stage = TransferStage.moving});
  final int done;
  final int total;
  final TransferStage stage;
  bool get encrypting => stage != TransferStage.moving;
  double get fraction => total <= 0 ? 0 : (done / total).clamp(0, 1);

  /// "Compressing · 40%", "Preparing…", "Encrypting…"; null while moving.
  String? get label => switch (stage) {
        TransferStage.preparing => total > 0 ? 'Compressing · ${(fraction * 100).round()}%' : 'Preparing…',
        TransferStage.encrypting => 'Encrypting…',
        TransferStage.moving => null,
      };
}

/// What actually gets encrypted and sent: for photos a re-encoded copy
/// (smaller, with location and camera details stripped), for videos on
/// phones a compressed copy, otherwise the original. [temporary] files are
/// ours to delete once encrypted.
class PreparedFile {
  PreparedFile(this.file, this.name, {this.temporary = false, this.thumb, this.width, this.height, this.durationMs});
  final File file;
  final String name;
  final bool temporary;
  final String? thumb;
  final int? width;
  final int? height;
  final int? durationMs;
}

/// The server deleted the file (30 days) before this device fetched it.
class MediaExpiredException implements Exception {}

/// Encrypted media on this device (decisions.md 2026-09-25).
///
/// Every file is encrypted on the phone with a fresh key before it leaves
/// (the Rust core, libsignal's streaming AES-256-GCM), uploaded in 8 MB parts
/// that resume after an interruption, and kept here only as ciphertext.
/// Plaintext exists only while something is viewed: photos in memory, and
/// videos, voice and documents as a short-lived copy in [viewDir] that is
/// thrown away afterwards (and swept at start-up).
class MediaService extends ChangeNotifier {
  MediaService({required this.api, required this.dir, required this.viewDir});

  final ApiClient api;
  final Directory dir;
  final Directory viewDir;

  static const maxBytes = 2 * 1024 * 1024 * 1024;
  static const _cacheLimit = 64 * 1024 * 1024;

  final _uuid = const Uuid();
  final Map<String, Transfer> transfers = {};
  final Map<String, Future<void>> _downloads = {};
  final _cache = <String, Uint8List>{}; // insertion-ordered: oldest first
  var _cacheBytes = 0;
  Timer? _notifyTimer;

  Transfer? transfer(String messageId) => transfers[messageId];

  File fileOf(MediaInfo m) => File('${dir.path}${Platform.pathSeparator}${m.localFile}');
  bool hasLocal(MediaInfo m) => m.localFile != null && fileOf(m).existsSync();

  // ------------------------------------------------------------ sending

  /// Encrypts [source] into the media folder and fills in the key, nonce,
  /// hash and size. The source itself is left alone.
  Future<void> encrypt(String messageId, File source, MediaInfo m) async {
    await dir.create(recursive: true);
    transfers[messageId] = Transfer(0, m.size, stage: TransferStage.encrypting);
    notifyListeners();
    final name = '${_uuid.v4()}.enc';
    final keys = await rust.encryptMediaFile(
      input: source.path,
      output: '${dir.path}${Platform.pathSeparator}$name',
    );
    m
      ..localFile = name
      ..key = base64.encode(keys.key)
      ..nonce = base64.encode(keys.nonce)
      ..sha256 = base64.encode(keys.ciphertextSha256)
      ..cipherSize = keys.ciphertextSize.toInt();
  }

  /// Uploads the encrypted file, or resumes an interrupted upload.
  /// [onStarted] runs as soon as the server has assigned an id, so the
  /// caller can persist it and resume after a restart.
  Future<void> upload(String messageId, MediaInfo m, {required Future<void> Function() onStarted}) async {
    int parts;
    var done = <int>{};
    if (m.attachmentId == null) {
      final j = await api.post('/attachments', {'ciphertextBytes': m.cipherSize, 'sha256': m.sha256})
          as Map<String, Object?>;
      m.attachmentId = j['attachmentId']! as String;
      parts = j['parts']! as int;
      await onStarted();
    } else {
      try {
        final j = await api.get('/attachments/${m.attachmentId}/upload') as Map<String, Object?>;
        parts = j['parts']! as int;
        done = {for (final n in j['done']! as List<Object?>) n! as int};
      } on ApiException catch (e) {
        // No longer an upload in progress: it was completed before we lost
        // track (or has expired, which the send then reports).
        if (e.status == 404) return;
        rethrow;
      }
    }
    const partSize = _partSize; // the server's part size (fixed at 8 MB)
    var sent = 0;
    for (final n in done) {
      sent += n < parts ? partSize : m.cipherSize - (parts - 1) * partSize;
    }
    transfers[messageId] = Transfer(sent, m.cipherSize);
    notifyListeners();
    final raf = await fileOf(m).open();
    try {
      for (var n = 1; n <= parts; n++) {
        if (done.contains(n)) continue;
        await raf.setPosition((n - 1) * partSize);
        final bytes = await raf.read(partSize);
        await api.putBytes('/attachments/${m.attachmentId}/parts?part=$n', bytes);
        sent += bytes.length;
        transfers[messageId] = Transfer(sent, m.cipherSize);
        notifyListeners();
      }
    } finally {
      await raf.close();
    }
    await api.post('/attachments/${m.attachmentId}/complete');
  }

  static const _partSize = 8 * 1024 * 1024;

  void finished(String messageId) {
    if (transfers.remove(messageId) != null) notifyListeners();
  }

  // ---------------------------------------------------------- receiving

  /// Fetches the ciphertext (resuming a partial download). Concurrent calls
  /// for the same message share one download.
  Future<void> download(String messageId, MediaInfo m) {
    return _downloads[messageId] ??= () async {
      try {
        await dir.create(recursive: true);
        final name = '${m.attachmentId}.enc';
        final part = File('${dir.path}${Platform.pathSeparator}$name.part');
        transfers[messageId] = Transfer(0, m.cipherSize);
        notifyListeners();
        try {
          await api.download('/attachments/${m.attachmentId}', part, onProgress: (got, total) {
            transfers[messageId] = Transfer(got, m.cipherSize > 0 ? m.cipherSize : total);
            _notifySoon();
          });
        } on ApiException catch (e) {
          if (e.status == 404) {
            if (await part.exists()) await part.delete();
            throw MediaExpiredException();
          }
          rethrow;
        }
        final target = File('${dir.path}${Platform.pathSeparator}$name');
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        m.localFile = name;
      } finally {
        transfers.remove(messageId);
        _downloads.remove(messageId);
        notifyListeners();
      }
    }();
  }

  bool downloading(String messageId) => _downloads.containsKey(messageId);

  // ------------------------------------------------------------ viewing

  /// A photo, decrypted into memory (never to disk). A few recent ones are
  /// kept in memory so scrolling does not decrypt them again.
  Future<Uint8List> bytes(MediaInfo m) async {
    final k = m.localFile!;
    final hit = _cache.remove(k);
    if (hit != null) return _cache[k] = hit;
    final b = await rust.decryptMediaToMemory(
      input: fileOf(m).path,
      key: base64.decode(m.key),
      nonce: base64.decode(m.nonce),
      expectedSha256: m.sha256.isEmpty ? null : base64.decode(m.sha256),
    );
    _cache[k] = b;
    _cacheBytes += b.length;
    while (_cacheBytes > _cacheLimit && _cache.length > 1) {
      final first = _cache.keys.first;
      _cacheBytes -= _cache.remove(first)!.length;
    }
    return b;
  }

  Uint8List? cached(MediaInfo m) => m.localFile == null ? null : _cache[m.localFile];

  /// A short-lived plaintext copy for a player or another app. Throw it
  /// away with [discard] when done; leftovers are swept at start-up.
  Future<File> plainCopy(MediaInfo m) async {
    final folder = Directory('${viewDir.path}${Platform.pathSeparator}${_uuid.v4()}');
    await folder.create(recursive: true);
    final out = File('${folder.path}${Platform.pathSeparator}${safeName(m.name)}');
    await rust.decryptMediaFile(
      input: fileOf(m).path,
      output: out.path,
      key: base64.decode(m.key),
      nonce: base64.decode(m.nonce),
      expectedSha256: m.sha256.isEmpty ? null : base64.decode(m.sha256),
    );
    return out;
  }

  Future<void> discard(File plain) async {
    try {
      await plain.parent.delete(recursive: true);
    } on FileSystemException {
      // Still open in another app (Windows locks it): swept later.
    }
  }

  /// Deletes plaintext copies older than [olderThan] (all of them at start).
  Future<void> sweepViewCache({Duration olderThan = Duration.zero}) async {
    if (!await viewDir.exists()) return;
    final cutoff = DateTime.now().subtract(olderThan);
    await for (final e in viewDir.list()) {
      try {
        if ((await e.stat()).modified.isBefore(cutoff)) await e.delete(recursive: true);
      } on FileSystemException {
        // in use; next time
      }
    }
  }

  /// A disappearing message (or a deleted one) takes its file with it.
  Future<void> delete(MediaInfo m) async {
    final names = [
      if (m.localFile != null) m.localFile!,
      if (m.attachmentId != null) '${m.attachmentId}.enc.part',
    ];
    for (final n in names) {
      final f = File('${dir.path}${Platform.pathSeparator}$n');
      try {
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // ignore
      }
      final c = _cache.remove(n);
      if (c != null) _cacheBytes -= c.length;
    }
  }

  void _notifySoon() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ helpers

  /// A file name that is safe to create: no folders, no control characters.
  static String safeName(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    if (n.isEmpty || n == '.' || n == '..') n = 'file';
    if (n.length > 120) {
      final dot = n.lastIndexOf('.');
      final ext = dot > 0 && n.length - dot <= 10 ? n.substring(dot) : '';
      n = n.substring(0, 120 - ext.length) + ext;
    }
    return n;
  }

  // ------------------------------------------------------------ preparing

  /// Makes [source] ready to send (see [PreparedFile]). Anything that fails
  /// here falls back to sending the original as it is.
  Future<PreparedFile> prepare(String messageId, File source, MediaKind kind, String name) async {
    transfers[messageId] = const Transfer(0, 0, stage: TransferStage.preparing);
    notifyListeners();
    await viewDir.create(recursive: true);
    switch (kind) {
      case MediaKind.photo:
        final out = '${viewDir.path}${Platform.pathSeparator}${_uuid.v4()}';
        final r = await compute(_preparePhoto, (source.path, out, name));
        if (r == null) return PreparedFile(source, name);
        return PreparedFile(File(r.path), r.name,
            temporary: true, thumb: r.thumb, width: r.width, height: r.height);
      case MediaKind.video:
        return _prepareVideo(messageId, source, name);
      case MediaKind.voice:
      case MediaKind.file:
        // Documents and recordings go exactly as they are.
        return PreparedFile(source, name);
    }
  }

  static const _compressVideosOver = 12 * 1024 * 1024;
  static Future<void> _videoQueue = Future.value(); // one compression at a time

  Future<PreparedFile> _prepareVideo(String messageId, File source, String name) async {
    var file = source;
    var fileName = name;
    var temporary = false;
    int? ms;
    // Phones re-encode large videos (about a tenth of the size at medium
    // quality). Windows has no converter we can ship, so it sends originals.
    if ((Platform.isAndroid || Platform.isIOS) && await source.length() > _compressVideosOver) {
      final done = Completer<void>();
      final previous = _videoQueue;
      _videoQueue = done.future;
      await previous;
      final sub = vc.VideoCompress.compressProgress$.subscribe((p) {
        transfers[messageId] = Transfer(p.round(), 100, stage: TransferStage.preparing);
        _notifySoon();
      });
      try {
        final out = await vc.VideoCompress.compressVideo(
          source.path,
          quality: vc.VideoQuality.MediumQuality,
          includeAudio: true,
        );
        if (out?.path != null && (out!.filesize ?? 1 << 62) < await source.length()) {
          file = File(out.path!);
          temporary = true;
          final dot = name.lastIndexOf('.');
          fileName = '${dot > 0 ? name.substring(0, dot) : name}.mp4';
          ms = out.duration?.round();
        }
      } on Object {
        // Could not convert: send the original.
      } finally {
        sub.unsubscribe();
        done.complete();
      }
    }
    final preview = await _videoPreview(file);
    ms ??= await _videoLength(file);
    return PreparedFile(file, fileName,
        temporary: temporary, thumb: preview?.thumb, width: preview?.width, height: preview?.height, durationMs: ms);
  }

  Future<({String thumb, int width, int height})?> _videoPreview(File video) async {
    try {
      final jpg = await FcNativeVideoThumbnail()
          .saveThumbnailToBytes(srcFile: video.path, width: 320, height: 320, format: 'jpeg', quality: 70)
          .timeout(const Duration(seconds: 15));
      if (jpg == null) return null;
      return await compute(_shrinkPreview, jpg);
    } on Object {
      return null;
    }
  }

  Future<int?> _videoLength(File video) async {
    final c = VideoPlayerController.file(video);
    try {
      await c.initialize().timeout(const Duration(seconds: 10));
      final ms = c.value.duration.inMilliseconds;
      return ms > 0 ? ms : null;
    } on Object {
      return null;
    } finally {
      await c.dispose();
    }
  }
}

/// A small JPEG (at most ~14 KB) of [image], to travel inside the message.
String? _previewOf(img.Image image) {
  final small = image.width >= image.height
      ? img.copyResize(image, width: image.width < 320 ? image.width : 320)
      : img.copyResize(image, height: image.height < 320 ? image.height : 320);
  var quality = 60;
  var jpg = img.encodeJpg(small, quality: quality);
  while (jpg.length > 14000 && quality > 20) {
    quality -= 10;
    jpg = img.encodeJpg(small, quality: quality);
  }
  return jpg.length > 20000 ? null : base64.encode(jpg);
}

({String thumb, int width, int height})? _shrinkPreview(Uint8List jpg) {
  final image = img.decodeImage(jpg);
  if (image == null) return null;
  final t = _previewOf(image);
  return t == null ? null : (thumb: t, width: image.width, height: image.height);
}

/// Re-encodes a photo: at most 2048 px on the long side, JPEG at quality 82
/// (PNG stays PNG, for screenshots). Re-encoding drops EXIF, so location,
/// camera and date details never leave the device. Null if it cannot be
/// decoded (HEIC, for one): the original is sent instead.
({String path, String name, String thumb, int width, int height})? _preparePhoto((String, String, String) args) {
  final (source, outBase, name) = args;
  try {
    final file = File(source);
    if (file.lengthSync() > 80 * 1024 * 1024) return null;
    final decoded = img.decodeImage(file.readAsBytesSync());
    if (decoded == null) return null;
    if (decoded.numFrames > 1) return null; // an animation: keep it whole
    var image = img.bakeOrientation(decoded);
    const edge = 2048;
    if (image.width > edge || image.height > edge) {
      image = image.width >= image.height ? img.copyResize(image, width: edge) : img.copyResize(image, height: edge);
    }
    image.exif = img.ExifData();
    final png = name.toLowerCase().endsWith('.png');
    final bytes = png ? img.encodePng(image, level: 6) : img.encodeJpg(image, quality: 82);
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final outName = png ? '$base.png' : '$base.jpg';
    final outPath = '$outBase${png ? '.png' : '.jpg'}';
    File(outPath).writeAsBytesSync(bytes);
    return (
      path: outPath,
      name: outName,
      thumb: _previewOf(image) ?? '',
      width: image.width,
      height: image.height,
    );
  } on Object {
    return null;
  }
}
