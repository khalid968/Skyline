import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../messages/data/messenger.dart';
import '../../messages/domain/models.dart';
import '../data/media_service.dart';
import 'media_format.dart';

/// Board 21: a photo, video, document or voice message in a chat, with its
/// upload or download progress. [meta] is the time-and-tick row.
class MediaBubble extends StatelessWidget {
  const MediaBubble({super.key, required this.m, required this.messenger, required this.meta, this.onDetails});

  final LocalMessage m;
  final Messenger messenger;
  final Widget meta;
  final VoidCallback? onDetails;

  MediaInfo get info => m.media!;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return ListenableBuilder(
      listenable: messenger.media,
      builder: (context, _) {
        final transfer = messenger.media.transfer(m.id);
        _autoFetch();
        final failed = m.status == MessageStatus.failed;
        final bg = m.fromMe ? (failed ? const Color(0xFF5A1E26) : t.bubbleOutgoing) : t.bubbleIncoming;
        final radius = BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(m.fromMe ? 18 : 5),
          bottomRight: Radius.circular(m.fromMe ? 5 : 18),
        );
        if (info.state == MediaState.expired) return _align(_Expired(info: info));
        final body = switch (info.kind) {
          MediaKind.photo || MediaKind.video => _visual(context, transfer),
          MediaKind.file => _file(context, transfer),
          MediaKind.voice => _VoiceRow(m: m, messenger: messenger, transfer: transfer),
        };
        final fg = m.fromMe ? Colors.white : t.textPrimary;
        return _align(Container(
          width: info.kind == MediaKind.photo || info.kind == MediaKind.video ? 240 : 260,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
            border: failed ? Border.all(color: const Color(0xFFB7414C)) : null,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            body,
            if (m.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                child: SelectableText(m.text, style: TextStyle(fontSize: 14, height: 1.4, color: fg)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
              child: Align(alignment: Alignment.centerRight, child: meta),
            ),
            if (failed)
              const Padding(
                padding: EdgeInsets.fromLTRB(10, 0, 10, 6),
                child: Text('Not sent · tap to try again',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFFFD0D2))),
              ),
          ]),
        ));
      },
    );
  }

  Widget _align(Widget child) => Align(
        alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(onTap: m.status == MessageStatus.failed ? onDetails : null, child: child),
      );

  // Photos and voice messages fetch themselves. A failed attempt (offline)
  // is retried at most every 30 seconds, not on every repaint.
  static final Map<String, DateTime> _tried = {};

  void _autoFetch() {
    if (info.state != MediaState.remote) return;
    if (info.kind != MediaKind.photo && info.kind != MediaKind.voice) return;
    if (messenger.media.downloading(m.id)) return;
    final last = _tried[m.id];
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 30)) return;
    _tried[m.id] = DateTime.now();
    scheduleMicrotask(() => messenger.fetchMedia(m.id));
  }

  // ------------------------------------------------------ photo and video

  Widget _visual(BuildContext context, Transfer? transfer) {
    final ratio = (info.width != null && info.height != null && info.height! > 0)
        ? (info.width! / info.height!).clamp(0.6, 1.9)
        : (info.kind == MediaKind.video ? 16 / 9 : 4 / 3);
    final ready = info.state == MediaState.ready && messenger.media.hasLocal(info);
    Widget picture;
    if (info.kind == MediaKind.photo && ready) {
      picture = _DecryptedImage(info: info, media: messenger.media, fallback: _thumbOrGradient());
    } else {
      picture = _thumbOrGradient();
    }
    final overlay = transfer != null
        ? _progressOverlay(transfer)
        : info.kind == MediaKind.video
            ? (ready ? _playBadge() : (info.state == MediaState.remote ? _downloadPill() : null))
            : null;
    return GestureDetector(
      onTap: () => _openVisual(context, ready),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: ratio.toDouble(),
          child: Stack(fit: StackFit.expand, children: [
            picture,
            if (overlay != null) overlay,
            if (info.kind == MediaKind.video && info.durationMs != null)
              Positioned(
                left: 8,
                bottom: 8,
                child: _chip(formatDuration(info.durationMs)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _thumbOrGradient() {
    if (info.thumb != null) {
      try {
        return Image.memory(base64.decode(info.thumb!), fit: BoxFit.cover, gaplessPlayback: true);
      } on FormatException {
        // fall through
      }
    }
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1F3A4F), Color(0xFF3D6E86)],
        ),
      ),
    );
  }

  Widget _progressOverlay(Transfer tr) {
    final pct = (tr.fraction * 100).round();
    final text = tr.encrypting
        ? 'Encrypting…'
        : m.fromMe && info.state == MediaState.uploading
            ? 'Encrypting and sending · $pct%'
            : 'Downloading · $pct%';
    return ColoredBox(
      color: const Color(0x73080C16),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              value: tr.encrypting ? null : tr.fraction,
              strokeWidth: 3,
              color: Colors.white,
              backgroundColor: Colors.white24,
            ),
          ),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white)),
        ]),
      ),
    );
  }

  Widget _playBadge() => Center(
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Color(0xB3080C16), shape: BoxShape.circle),
          child: const SkyIcon(SkyIcons.play, size: 20, color: Colors.white, filled: true),
        ),
      );

  Widget _downloadPill() => Center(
        child: Semantics(
          button: true,
          label: 'Download video, ${formatBytes(info.size)}',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(color: const Color(0xB3080C16), borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const SkyIcon(SkyIcons.download, size: 16, color: Colors.white, stroke: 2.2),
              const SizedBox(width: 8),
              Text('Video · ${formatBytes(info.size)}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
            ]),
          ),
        ),
      );

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: const Color(0x99080C16), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: const TextStyle(fontSize: 11.5, color: Color(0xFFE3E8F2))),
      );

  Future<void> _openVisual(BuildContext context, bool ready) async {
    if (m.status == MessageStatus.failed) return onDetails?.call();
    if (!ready) {
      if (info.state == MediaState.remote) unawaited(messenger.fetchMedia(m.id));
      return;
    }
    final name = m.fromMe ? 'You' : (messenger.contact(m.peerUserId)?.displayName ?? '');
    if (info.kind == MediaKind.photo) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PhotoViewerScreen(m: m, media: messenger.media, from: name),
      ));
    } else {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => VideoScreen(info: info, media: messenger.media),
      ));
    }
  }

  // ---------------------------------------------------------- documents

  Widget _file(BuildContext context, Transfer? tr) {
    final t = context.sky;
    final fg = m.fromMe ? Colors.white : t.textPrimary;
    final sub = m.fromMe ? const Color(0xFFDDE5FC) : t.textSecondary;
    final ready = info.state == MediaState.ready && messenger.media.hasLocal(info);
    final ext = info.name.contains('.') ? info.name.split('.').last.toUpperCase() : 'FILE';
    final line = tr != null
        ? (tr.encrypting
            ? 'Encrypting…'
            : '${m.fromMe && info.state == MediaState.uploading ? 'Uploading' : 'Downloading'} ${formatProgress(tr.done, tr.total)}')
        : ready
            ? '${formatBytes(info.size)} · $ext'
            : info.state == MediaState.remote
                ? '${formatBytes(info.size)} · tap to download'
                : formatBytes(info.size);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        if (m.status == MessageStatus.failed) return onDetails?.call();
        if (ready) return _openFile(context);
        if (info.state == MediaState.remote) unawaited(messenger.fetchMedia(m.id));
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(9, 7, 9, 3),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: m.fromMe ? const Color(0x33FFFFFF) : const Color(0xFF2A3550),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SkyIcon(
              ready || m.fromMe ? SkyIcons.file : SkyIcons.download,
              size: 18,
              color: m.fromMe ? Colors.white : const Color(0xFF9DB8FF),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(info.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: fg)),
              if (tr != null) ...[
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: tr.encrypting ? null : tr.fraction,
                    minHeight: 4,
                    color: m.fromMe ? Colors.white : t.accentText,
                    backgroundColor: m.fromMe ? const Color(0x33FFFFFF) : const Color(0xFF2A3550),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(line, style: TextStyle(fontSize: 11.5, color: sub)),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Hands a decrypted copy to the app that opens this kind of file. That
  /// app then holds plaintext, which is why documents are opened on request.
  Future<void> _openFile(BuildContext context) async {
    final messengerState = ScaffoldMessenger.of(context);
    try {
      final plain = await messenger.media.plainCopy(info);
      final r = await OpenFilex.open(plain.path, type: info.mime);
      if (r.type != ResultType.done) {
        messengerState.showSnackBar(const SnackBar(content: Text('No app on this device can open this file.')));
        await messenger.media.discard(plain);
      }
      // Otherwise the copy is swept on the next start (the other app may
      // still be reading it).
    } on Object {
      messengerState.showSnackBar(const SnackBar(content: Text('This file could not be opened.')));
    }
  }
}

/// A photo decrypted into memory.
class _DecryptedImage extends StatefulWidget {
  const _DecryptedImage({required this.info, required this.media, required this.fallback});
  final MediaInfo info;
  final MediaService media;
  final Widget fallback;

  @override
  State<_DecryptedImage> createState() => _DecryptedImageState();
}

class _DecryptedImageState extends State<_DecryptedImage> {
  late Future<Uint8List> _bytes = widget.media.bytes(widget.info);

  @override
  void didUpdateWidget(_DecryptedImage old) {
    super.didUpdateWidget(old);
    if (old.info.localFile != widget.info.localFile) _bytes = widget.media.bytes(widget.info);
  }

  @override
  Widget build(BuildContext context) {
    final cached = widget.media.cached(widget.info);
    if (cached != null) return Image.memory(cached, fit: BoxFit.cover, gaplessPlayback: true);
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snap) => snap.hasData
          ? Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
          : widget.fallback,
    );
  }
}

class _Expired extends StatelessWidget {
  const _Expired({required this.info});
  final MediaInfo info;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: const Color(0xFF33405C)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(children: [
        SkyIcon(SkyIcons.clock, size: 18, color: t.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '${info.kind == MediaKind.file ? 'File' : info.label} no longer available',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFC4CDDF)),
            ),
            const SizedBox(height: 2),
            Text('Files are kept on the server for 30 days',
                style: TextStyle(fontSize: 11.5, color: t.textSecondary)),
          ]),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ voice

class _VoiceRow extends StatefulWidget {
  const _VoiceRow({required this.m, required this.messenger, required this.transfer});
  final LocalMessage m;
  final Messenger messenger;
  final Transfer? transfer;

  @override
  State<_VoiceRow> createState() => _VoiceRowState();
}

class _VoiceRowState extends State<_VoiceRow> {
  AudioPlayer? _player;
  File? _plain;
  double _position = 0; // 0..1
  bool _playing = false;
  StreamSubscription<Duration>? _posSub;

  MediaInfo get info => widget.m.media!;

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  Future<void> _stop() async {
    await _posSub?.cancel();
    _posSub = null;
    final p = _player;
    _player = null;
    await p?.dispose();
    final f = _plain;
    _plain = null;
    if (f != null) await widget.messenger.media.discard(f);
  }

  Future<void> _toggle() async {
    final media = widget.messenger.media;
    if (info.state != MediaState.ready || !media.hasLocal(info)) {
      if (info.state == MediaState.remote) unawaited(widget.messenger.fetchMedia(widget.m.id));
      return;
    }
    if (_player != null) {
      if (_playing) {
        await _player!.pause();
      } else {
        await _player!.resume();
      }
      setState(() => _playing = !_playing);
      return;
    }
    // Decrypted to a short-lived file only while it plays.
    _plain = await media.plainCopy(info);
    final p = AudioPlayer();
    _player = p;
    final total = info.durationMs ?? 0;
    _posSub = p.onPositionChanged.listen((d) {
      if (!mounted || total <= 0) return;
      setState(() => _position = (d.inMilliseconds / total).clamp(0, 1));
    });
    p.onPlayerComplete.listen((_) async {
      await _stop();
      if (mounted) {
        setState(() {
          _playing = false;
          _position = 0;
        });
      }
    });
    await p.play(DeviceFileSource(_plain!.path));
    setState(() => _playing = true);
  }

  @override
  Widget build(BuildContext context) {
    final fromMe = widget.m.fromMe;
    final t = context.sky;
    final bars = info.wave.isNotEmpty ? info.wave : const [8, 14, 20, 12, 22, 26, 16, 10, 18, 24, 14, 8, 12, 20, 26, 18, 10, 14, 22, 16, 8, 12, 18, 24];
    final played = (bars.length * _position).round();
    final on = fromMe ? Colors.white : t.accentText;
    final off = fromMe ? Colors.white54 : const Color(0xFF45526E);
    final busy = widget.transfer != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(children: [
        Semantics(
          button: true,
          label: '${_playing ? 'Pause' : 'Play'} voice message, ${formatDuration(info.durationMs)}',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: busy ? null : _toggle,
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: fromMe ? Colors.white : t.accentFill, shape: BoxShape.circle),
              child: busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        value: widget.transfer!.encrypting ? null : widget.transfer!.fraction,
                        color: fromMe ? const Color(0xFF2A4FB8) : Colors.white,
                      ),
                    )
                  : SkyIcon(
                      _playing ? SkyIcons.pause : SkyIcons.play,
                      size: 14,
                      color: fromMe ? const Color(0xFF2A4FB8) : Colors.white,
                      stroke: 2.6,
                      filled: !_playing,
                    ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 26,
            child: Row(children: [
              for (var i = 0; i < bars.length; i++)
                Expanded(
                  child: Center(
                    child: Container(
                      width: 3,
                      height: (4 + bars[i].clamp(0, 31) * 0.7).toDouble(),
                      decoration: BoxDecoration(
                        color: i < played ? on : off,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        Text(formatDuration(info.durationMs),
            style: TextStyle(fontSize: 11, color: fromMe ? const Color(0xFFDDE5FC) : t.textSecondary)),
      ]),
    );
  }
}

// ----------------------------------------------------------------- viewer

/// Board 22: the photo viewer. Decrypted only while shown; saving a normal,
/// unencrypted copy asks first.
class PhotoViewerScreen extends StatelessWidget {
  const PhotoViewerScreen({super.key, required this.m, required this.media, required this.from});
  final LocalMessage m;
  final MediaService media;
  final String from;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final when = m.sentAt.toLocal();
    final time = '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      backgroundColor: const Color(0xFF05070C),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Row(children: [
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const SkyIcon(SkyIcons.close, size: 20, color: Color(0xFFE3E8F2), stroke: 2.2),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(from, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
                  Text(_day(when) + time, style: TextStyle(fontSize: 12, color: t.textSecondary)),
                ]),
              ),
              IconButton(
                tooltip: 'Save to this device',
                onPressed: () => _save(context),
                icon: const SkyIcon(SkyIcons.download, size: 20, color: Color(0xFFE3E8F2), stroke: 2),
              ),
            ]),
          ),
          Expanded(
            child: FutureBuilder<Uint8List>(
              future: media.bytes(m.media!),
              builder: (context, snap) => snap.hasData
                  ? InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(snap.data!)))
                  : snap.hasError
                      ? Center(
                          child: Text('This photo could not be opened.',
                              style: TextStyle(color: t.textSecondary)))
                      : const Center(child: CircularProgressIndicator()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (m.text.isNotEmpty) ...[
                Text(m.text, style: TextStyle(fontSize: 14.5, color: t.textPrimary)),
                const SizedBox(height: 10),
              ],
              Text(
                'Decrypted only while you look at it. “Save to this device” puts a normal, unencrypted copy '
                'on this device; Skyline asks first.',
                style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  static String _day(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today, ';
    return '${d.day}/${d.month}/${d.year}, ';
  }

  Future<void> _save(BuildContext context) async {
    final t = context.sky;
    final snack = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        title: const Text('Save an unencrypted copy?'),
        content: const Text(
          'The copy is a normal file on this device. Other apps, backups and anyone who can open this '
          'device can see it. Skyline cannot delete it later, even if the message disappears.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save copy')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final bytes = await media.bytes(m.media!);
      final path = await FilePicker.saveFile(fileName: MediaService.safeName(m.media!.name), bytes: bytes);
      if (path != null && Platform.isWindows) await File(path).writeAsBytes(bytes);
      if (path != null) snack.showSnackBar(const SnackBar(content: Text('Saved.')));
    } on Object {
      snack.showSnackBar(const SnackBar(content: Text('The copy could not be saved.')));
    }
  }
}

/// Plays a video from a short-lived decrypted copy, deleted on close.
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.info, required this.media});
  final MediaInfo info;
  final MediaService media;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  File? _plain;
  VideoPlayerController? _video;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final plain = await widget.media.plainCopy(widget.info);
      _plain = plain;
      final c = VideoPlayerController.file(plain);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _video = c);
      await c.play();
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    final c = _video;
    final f = _plain;
    unawaited(() async {
      await c?.dispose();
      if (f != null) await widget.media.discard(f);
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final c = _video;
    return Scaffold(
      backgroundColor: const Color(0xFF05070C),
      body: SafeArea(
        child: Stack(children: [
          Center(
            child: _error != null
                ? Text('This video could not be played on this device.', style: TextStyle(color: t.textSecondary))
                : c == null
                    ? const CircularProgressIndicator()
                    : GestureDetector(
                        onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
                        child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
                      ),
          ),
          Positioned(
            left: 4,
            top: 8,
            child: IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const SkyIcon(SkyIcons.close, size: 20, color: Color(0xFFE3E8F2), stroke: 2.2),
            ),
          ),
          if (c != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: VideoProgressIndicator(c, allowScrubbing: true),
            ),
        ]),
      ),
    );
  }
}
