import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:video_player/video_player.dart';

import '../../../core/platform/screen_protection.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../messages/data/messenger.dart';
import '../../messages/domain/models.dart';
import '../data/media_service.dart';
import 'media_format.dart';

String _key(LocalMessage m, int i) => Messenger.transferKey(m.id, i);

String _clock(DateTime d) =>
    '${d.toLocal().hour.toString().padLeft(2, '0')}:${d.toLocal().minute.toString().padLeft(2, '0')}';

/// Boards 21, 23 and 24: a photo, video, album, document, voice message or
/// view-once message in a chat, with upload or download progress. [meta] is
/// the time-and-tick row.
class MediaBubble extends StatelessWidget {
  const MediaBubble({super.key, required this.m, required this.messenger, required this.meta, this.onDetails});

  final LocalMessage m;
  final Messenger messenger;
  final Widget meta;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return ListenableBuilder(
      listenable: messenger.media,
      builder: (context, _) {
        for (var i = 0; i < m.items.length; i++) {
          _autoFetch(i);
        }
        if (m.viewOnce) return _align(_ViewOnceBubble(m: m, messenger: messenger));
        final info = m.items.first;
        if (!m.isAlbum && info.state == MediaState.expired) return _align(_Expired(info: info));
        final failed = m.status == MessageStatus.failed;
        final bg = m.fromMe ? (failed ? const Color(0xFF5A1E26) : t.bubbleOutgoing) : t.bubbleIncoming;
        final radius = BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(m.fromMe ? 18 : 5),
          bottomRight: Radius.circular(m.fromMe ? 5 : 18),
        );
        final visual = info.kind == MediaKind.photo || info.kind == MediaKind.video;
        final body = m.isAlbum
            ? _Album(m: m, messenger: messenger, onDetails: onDetails)
            : switch (info.kind) {
                MediaKind.photo || MediaKind.video => _Visual(m: m, index: 0, messenger: messenger, onDetails: onDetails),
                MediaKind.file => _FileRow(m: m, index: 0, messenger: messenger, onDetails: onDetails),
                MediaKind.voice => VoiceRow(m: m, messenger: messenger),
              };
        final fg = m.fromMe ? Colors.white : t.textPrimary;
        return _align(Container(
          width: m.isAlbum ? 260 : (visual ? 240 : 260),
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
              child: Align(alignment: Alignment.centerRight, child: _albumStatus(fg) ?? meta),
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

  /// Board 23: "Encrypting and sending · 2 of 4" while an album goes out.
  Widget? _albumStatus(Color fg) {
    if (!m.isAlbum || !m.fromMe || m.status != MessageStatus.sending) return null;
    final done = m.items.where((i) => i.state == MediaState.ready).length;
    return Text('Encrypting and sending · ${done + 1 > m.items.length ? m.items.length : done + 1} of ${m.items.length}',
        style: const TextStyle(fontSize: 11, color: Color(0xFFDDE5FC)));
  }

  Widget _align(Widget child) => Align(
        alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(onTap: m.status == MessageStatus.failed ? onDetails : null, child: child),
      );

  // Photos and voice messages fetch themselves. A failed attempt (offline)
  // is retried at most every 30 seconds, not on every repaint.
  static final Map<String, DateTime> _tried = {};

  void _autoFetch(int i) {
    final info = m.items[i];
    if (info.state != MediaState.remote || info.burned) return;
    if (info.kind != MediaKind.photo && info.kind != MediaKind.voice) return;
    final k = _key(m, i);
    if (messenger.media.downloading(k)) return;
    final last = _tried[k];
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 30)) return;
    _tried[k] = DateTime.now();
    scheduleMicrotask(() => messenger.fetchMedia(m.id, i));
  }
}

/// Opens item [index] of [m]: the viewer for a photo, the player for a video,
/// another app for a document. Not on this device yet: fetches it. Used by
/// the chat and by the media gallery (board 25).
Future<void> openMediaItem(BuildContext context, Messenger messenger, LocalMessage m, int index) async {
  final info = m.items[index];
  final from = m.fromMe ? 'You' : (messenger.contact(m.peerUserId)?.displayName ?? '');
  // An album opens in a viewer you can swipe through, at the tile tapped
  // (the "+N" tile included), whether or not that one is downloaded yet.
  if (m.isAlbum && !m.viewOnce && (info.kind == MediaKind.photo || info.kind == MediaKind.video)) {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AlbumViewerScreen(m: m, initial: index, messenger: messenger, from: from),
    ));
    return;
  }
  final ready = info.state == MediaState.ready && messenger.media.hasLocal(info);
  if (!ready) {
    if (info.state == MediaState.remote) unawaited(messenger.fetchMedia(m.id, index));
    return;
  }
  switch (info.kind) {
    case MediaKind.photo:
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PhotoViewerScreen(m: m, index: index, media: messenger.media, from: from),
      ));
    case MediaKind.video:
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => VideoScreen(info: info, media: messenger.media),
      ));
    case MediaKind.file:
      await _openFile(context, messenger.media, info);
    case MediaKind.voice:
      break; // played in place
  }
}

/// Hands a decrypted copy to the app that opens this kind of file. That app
/// then holds plaintext, which is why documents are opened only on request.
Future<void> _openFile(BuildContext context, MediaService media, MediaInfo info) async {
  final snack = ScaffoldMessenger.of(context);
  try {
    final plain = await media.plainCopy(info);
    final r = await OpenFilex.open(plain.path, type: info.mime);
    if (r.type != ResultType.done) {
      snack.showSnackBar(const SnackBar(content: Text('No app on this device can open this file.')));
      await media.discard(plain);
    }
    // Otherwise the copy is swept on the next start (the other app may still
    // be reading it).
  } on Object {
    snack.showSnackBar(const SnackBar(content: Text('This file could not be opened.')));
  }
}

// ------------------------------------------------------- photo and video

class _Visual extends StatelessWidget {
  const _Visual({required this.m, required this.index, required this.messenger, this.onDetails, this.height});
  final LocalMessage m;
  final int index;
  final Messenger messenger;
  final VoidCallback? onDetails;
  final double? height; // an album tile: fixed height, cropped

  MediaInfo get info => m.items[index];

  @override
  Widget build(BuildContext context) {
    final transfer = messenger.media.transfer(_key(m, index));
    final ratio = (info.width != null && info.height != null && info.height! > 0)
        ? (info.width! / info.height!).clamp(0.6, 1.9)
        : (info.kind == MediaKind.video ? 16 / 9 : 4 / 3);
    final ready = info.state == MediaState.ready && messenger.media.hasLocal(info);
    final picture = info.kind == MediaKind.photo && ready
        ? _DecryptedImage(info: info, media: messenger.media, fallback: _thumbOrGradient(info))
        : _thumbOrGradient(info);
    final tile = height != null;
    final overlay = transfer != null
        ? (tile && m.fromMe ? null : _progressOverlay(transfer, small: tile))
        : info.state == MediaState.expired
            ? _expiredTile()
            : info.kind == MediaKind.video
                ? (ready ? _playBadge() : (info.state == MediaState.remote ? _downloadPill(small: tile) : null))
                : null;
    final stack = Stack(fit: StackFit.expand, children: [
      picture,
      if (overlay != null) overlay,
      if (info.kind == MediaKind.video && info.durationMs != null)
        Positioned(left: 8, bottom: 8, child: _chip(formatDuration(info.durationMs))),
    ]);
    return GestureDetector(
      onTap: () {
        if (m.status == MessageStatus.failed) return onDetails?.call();
        unawaited(openMediaItem(context, messenger, m, index));
      },
      child: tile
          ? SizedBox(height: height, child: stack)
          : ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(aspectRatio: ratio.toDouble(), child: stack),
            ),
    );
  }

  String get _progressText {
    final tr = messenger.media.transfer(_key(m, index))!;
    final pct = (tr.fraction * 100).round();
    return tr.label ??
        (m.fromMe && info.state == MediaState.uploading ? 'Encrypting and sending · $pct%' : 'Downloading · $pct%');
  }

  Widget _progressOverlay(Transfer tr, {bool small = false}) => ColoredBox(
        color: const Color(0x73080C16),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: small ? 28 : 44,
              height: small ? 28 : 44,
              child: CircularProgressIndicator(
                value: tr.encrypting && tr.total <= 0 ? null : tr.fraction,
                strokeWidth: 3,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
            if (!small) ...[
              const SizedBox(height: 8),
              Text(_progressText,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white)),
            ],
          ]),
        ),
      );

  Widget _playBadge() => Center(
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Color(0xB3080C16), shape: BoxShape.circle),
          child: const SkyIcon(SkyIcons.play, size: 20, color: Colors.white, filled: true),
        ),
      );

  Widget _downloadPill({bool small = false}) => Center(
        child: Semantics(
          button: true,
          label: 'Download video, ${formatBytes(info.size)}',
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: small ? 9 : 14, vertical: small ? 7 : 9),
            decoration: BoxDecoration(color: const Color(0xB3080C16), borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const SkyIcon(SkyIcons.download, size: 16, color: Colors.white, stroke: 2.2),
              if (!small) ...[
                const SizedBox(width: 8),
                Text('Video · ${formatBytes(info.size)}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
              ],
            ]),
          ),
        ),
      );

  Widget _expiredTile() => const ColoredBox(
        color: Color(0xCC161E2F),
        child: Center(child: SkyIcon(SkyIcons.clock, size: 20, color: Color(0xFF8E9BB4))),
      );
}

Widget _thumbOrGradient(MediaInfo info) {
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

Widget _chip(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: const Color(0x99080C16), borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: const TextStyle(fontSize: 11.5, color: Color(0xFFE3E8F2))),
    );

/// Board 23: an album of 2 to 10 photos and videos. Four tiles at most; the
/// fourth says how many more there are.
class _Album extends StatelessWidget {
  const _Album({required this.m, required this.messenger, this.onDetails});
  final LocalMessage m;
  final Messenger messenger;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final n = m.items.length;
    Widget tile(int i, double h) => _Visual(m: m, index: i, messenger: messenger, onDetails: onDetails, height: h);
    Widget row(List<Widget> tiles) => Row(children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(child: tiles[i]),
          ],
        ]);
    final more = n - 4;
    final Widget grid = switch (n) {
      2 => row([tile(0, 160), tile(1, 160)]),
      3 => Column(children: [row([tile(0, 118), tile(1, 118)]), const SizedBox(height: 3), tile(2, 140)]),
      _ => Column(children: [
          row([tile(0, 118), tile(1, 118)]),
          const SizedBox(height: 3),
          row([
            tile(2, 118),
            Stack(fit: StackFit.passthrough, children: [
              tile(3, 118),
              if (more > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    // Taps reach the tile under it, which opens the album
                    // viewer at this photo; swipe on to the rest.
                    child: ColoredBox(
                      color: const Color(0x80080C16),
                      child: Center(
                        child: Text('+$more',
                            style: const TextStyle(
                                fontFamily: SkyFonts.display,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                    ),
                  ),
                ),
            ]),
          ]),
        ]),
    };
    return ClipRRect(borderRadius: BorderRadius.circular(14), child: grid);
  }
}

// ------------------------------------------------------------- view once

/// Board 24: a view-once photo or video. No preview, ever. The recipient
/// opens it once; the sender sees Delivered, then Opened.
class _ViewOnceBubble extends StatelessWidget {
  const _ViewOnceBubble({required this.m, required this.messenger});
  final LocalMessage m;
  final Messenger messenger;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final info = m.items.first;
    final opened = m.openedAt != null || (!m.fromMe && info.burned);
    final tr = messenger.media.transfer(_key(m, 0));
    final gone = !m.fromMe && info.state == MediaState.expired;
    final title = opened ? 'Opened' : (gone ? '${info.label} no longer available' : '${info.label} · view once');
    final String sub;
    if (tr != null) {
      sub = tr.label ?? '${m.fromMe ? 'Sending' : 'Downloading'} · ${(tr.fraction * 100).round()}%';
    } else if (m.fromMe) {
      sub = opened
          ? 'Opened · ${_clock(m.openedAt ?? m.sentAt)}'
          : '${switch (m.status) {
              MessageStatus.sending => 'Sending',
              MessageStatus.waiting => 'Waiting to send',
              MessageStatus.failed => 'Not sent',
              MessageStatus.sent => 'Sent',
              _ => 'Delivered',
            }} · ${_clock(m.sentAt)}';
    } else if (opened || gone) {
      sub = _clock(m.sentAt);
    } else {
      sub = info.state == MediaState.ready ? 'Tap to open · ${_clock(m.sentAt)}' : 'Tap to download · ${_clock(m.sentAt)}';
    }
    final ring = m.fromMe ? const Color(0xFFDDE5FC) : (opened || gone ? const Color(0xFF55637D) : t.caution);
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: m.fromMe ? t.bubbleOutgoing : (opened ? t.surface : t.bubbleIncoming),
        border: !m.fromMe && opened ? Border.all(color: t.border) : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(m.fromMe ? 18 : 5),
          bottomRight: Radius.circular(m.fromMe ? 5 : 18),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 2)),
          child: Text('1', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ring)),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(title,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: m.fromMe ? Colors.white : (opened ? t.textSecondary : t.textPrimary))),
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(fontSize: 11.5, color: m.fromMe ? const Color(0xFFDDE5FC) : t.textSecondary)),
        ]),
      ]),
    );
    if (m.fromMe || opened || gone) return bubble;
    return Semantics(
      button: true,
      label: 'View once ${info.label.toLowerCase()}. Opens one time.',
      child: GestureDetector(onTap: () => _open(context, info), child: bubble),
    );
  }

  Future<void> _open(BuildContext context, MediaInfo info) async {
    if (info.state != MediaState.ready || !messenger.media.hasLocal(info)) {
      if (info.state == MediaState.remote) unawaited(messenger.fetchMedia(m.id));
      return;
    }
    final from = messenger.contact(m.peerUserId)?.displayName ?? '';
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => info.kind == MediaKind.video
          ? VideoScreen(info: info, media: messenger.media, viewOnce: true, from: from)
          : PhotoViewerScreen(m: m, index: 0, media: messenger.media, from: from, viewOnce: true),
    ));
    // Closed: gone from this device, and from our other devices.
    await messenger.viewOnceOpened(m.id);
  }
}

// -------------------------------------------------------------- documents

class _FileRow extends StatelessWidget {
  const _FileRow({required this.m, required this.index, required this.messenger, this.onDetails});
  final LocalMessage m;
  final int index;
  final Messenger messenger;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final info = m.items[index];
    final tr = messenger.media.transfer(_key(m, index));
    final fg = m.fromMe ? Colors.white : t.textPrimary;
    final sub = m.fromMe ? const Color(0xFFDDE5FC) : t.textSecondary;
    final ready = info.state == MediaState.ready && messenger.media.hasLocal(info);
    final ext = info.name.contains('.') ? info.name.split('.').last.toUpperCase() : 'FILE';
    final line = tr != null
        ? (tr.label ??
            '${m.fromMe && info.state == MediaState.uploading ? 'Uploading' : 'Downloading'} ${formatProgress(tr.done, tr.total)}')
        : ready
            ? '${formatBytes(info.size)} · $ext'
            : info.state == MediaState.remote
                ? '${formatBytes(info.size)} · tap to download'
                : info.state == MediaState.expired
                    ? 'No longer available'
                    : formatBytes(info.size);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        if (m.status == MessageStatus.failed) return onDetails?.call();
        await openMediaItem(context, messenger, m, index);
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
                    value: tr.encrypting && tr.total <= 0 ? null : tr.fraction,
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

/// A photo, decrypted into memory, for the gallery grid (board 25).
class MediaThumbnail extends StatelessWidget {
  const MediaThumbnail({super.key, required this.info, required this.media});
  final MediaInfo info;
  final MediaService media;

  @override
  Widget build(BuildContext context) => info.kind == MediaKind.photo && info.state == MediaState.ready && media.hasLocal(info)
      ? _DecryptedImage(info: info, media: media, fallback: _thumbOrGradient(info))
      : _thumbOrGradient(info);
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

/// A voice message: play/pause, the loudness outline, the length. Used in a
/// chat bubble and in the gallery (board 25, [onSurface] true).
class VoiceRow extends StatefulWidget {
  const VoiceRow({super.key, required this.m, required this.messenger, this.onSurface = false});
  final LocalMessage m;
  final Messenger messenger;
  final bool onSurface;

  @override
  State<VoiceRow> createState() => _VoiceRowState();
}

class _VoiceRowState extends State<VoiceRow> {
  AudioPlayer? _player;
  File? _plain;
  double _position = 0; // 0..1
  bool _playing = false;
  StreamSubscription<Duration>? _posSub;

  MediaInfo get info => widget.m.items.first;

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
    final t = context.sky;
    final light = widget.m.fromMe && !widget.onSurface; // on the blue bubble
    final bars = info.wave.isNotEmpty
        ? info.wave
        : const [8, 14, 20, 12, 22, 26, 16, 10, 18, 24, 14, 8, 12, 20, 26, 18, 10, 14, 22, 16, 8, 12, 18, 24];
    final played = (bars.length * _position).round();
    final on = light ? Colors.white : t.accentText;
    final off = light ? Colors.white54 : const Color(0xFF45526E);
    final transfer = widget.messenger.media.transfer(_key(widget.m, 0));
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(children: [
        Semantics(
          button: true,
          label: '${_playing ? 'Pause' : 'Play'} voice message, ${formatDuration(info.durationMs)}',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: transfer != null ? null : _toggle,
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: light ? Colors.white : t.accentFill, shape: BoxShape.circle),
              child: transfer != null
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        value: transfer.encrypting && transfer.total <= 0 ? null : transfer.fraction,
                        color: light ? const Color(0xFF2A4FB8) : Colors.white,
                      ),
                    )
                  : SkyIcon(
                      _playing ? SkyIcons.pause : SkyIcons.play,
                      size: 14,
                      color: light ? const Color(0xFF2A4FB8) : Colors.white,
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
            style: TextStyle(fontSize: 11, color: light ? const Color(0xFFDDE5FC) : t.textSecondary)),
      ]),
    );
  }
}

// ----------------------------------------------------------------- viewer

/// Board 22 (and 24 in view-once mode): the photo viewer. Decrypted only
/// while shown. Saving a normal, unencrypted copy asks first; a view-once
/// photo cannot be saved, and the screen is kept out of screenshots where
/// the device allows it.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({
    super.key,
    required this.m,
    required this.media,
    required this.from,
    this.index = 0,
    this.viewOnce = false,
  });
  final LocalMessage m;
  final int index;
  final MediaService media;
  final String from;
  final bool viewOnce;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final Future<Uint8List> _bytes = widget.media.bytes(widget.m.items[widget.index]);
  bool? _protected;

  @override
  void initState() {
    super.initState();
    if (widget.viewOnce) {
      ScreenProtection.protect(true).then((ok) {
        if (mounted) setState(() => _protected = ok);
      });
    }
  }

  @override
  void dispose() {
    if (widget.viewOnce) unawaited(ScreenProtection.protect(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final m = widget.m;
    final when = m.sentAt.toLocal();
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
                  Text(widget.from,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
                  Text(_day(when) + _clock(when), style: TextStyle(fontSize: 12, color: t.textSecondary)),
                ]),
              ),
              if (widget.viewOnce)
                Container(
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: t.caution),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('View once', style: TextStyle(fontSize: 12, color: t.caution)),
                )
              else
                IconButton(
                  tooltip: 'Save to this device',
                  onPressed: () => _save(context),
                  icon: const SkyIcon(SkyIcons.download, size: 20, color: Color(0xFFE3E8F2), stroke: 2),
                ),
            ]),
          ),
          Expanded(
            child: FutureBuilder<Uint8List>(
              future: _bytes,
              builder: (context, snap) => snap.hasData
                  ? InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(snap.data!)))
                  : snap.hasError
                      ? Center(
                          child: Text('This photo could not be opened.', style: TextStyle(color: t.textSecondary)))
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
                widget.viewOnce
                    ? 'No save button, no forwarding. When you close this, it is deleted from this device and your '
                        'other devices.${_protected == false ? ' This device cannot block screenshots.' : ''}'
                    : 'Decrypted only while you look at it. “Save to this device” puts a normal, unencrypted copy '
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

  Future<void> _save(BuildContext context) => saveUnencryptedCopy(context, widget.media, widget.m.items[widget.index]);
}

/// Plays a video from a short-lived decrypted copy, deleted on close. In
/// view-once mode (board 24) the screen is kept out of screenshots where the
/// device allows it.
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.info, required this.media, this.viewOnce = false, this.from = ''});
  final MediaInfo info;
  final MediaService media;
  final bool viewOnce;
  final String from;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  File? _plain;
  VideoPlayerController? _video;
  Object? _error;
  bool? _protected;

  @override
  void initState() {
    super.initState();
    if (widget.viewOnce) {
      ScreenProtection.protect(true).then((ok) {
        if (mounted) setState(() => _protected = ok);
      });
    }
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
    if (widget.viewOnce) unawaited(ScreenProtection.protect(false));
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
            right: 12,
            child: Row(children: [
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const SkyIcon(SkyIcons.close, size: 20, color: Color(0xFFE3E8F2), stroke: 2.2),
              ),
              Expanded(
                child: Text(widget.from,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
              ),
              if (widget.viewOnce)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: t.caution),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('View once', style: TextStyle(fontSize: 12, color: t.caution)),
                ),
            ]),
          ),
          if (c != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: widget.viewOnce ? 56 : 20,
              child: VideoProgressIndicator(c, allowScrubbing: true),
            ),
          if (widget.viewOnce)
            Positioned(
              left: 20,
              right: 20,
              bottom: 12,
              child: Text(
                'When you close this, it is deleted from this device and your other devices.'
                '${_protected == false ? ' This device cannot block screenshots.' : ''}',
                style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
              ),
            ),
        ]),
      ),
    );
  }
}

/// "Save to this device" (board 22): asks first, then puts a normal,
/// unencrypted copy in the phone's gallery, or wherever the PC's save dialog
/// says.
Future<void> saveUnencryptedCopy(BuildContext context, MediaService media, MediaInfo info) async {
    final t = context.sky;
    final snack = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        title: const Text('Save an unencrypted copy?'),
        content: Text(
          '${Platform.isWindows ? 'The copy is a normal file on this PC.' : 'The copy goes into your photo gallery.'} '
          'Other apps, backups and anyone who can open this device can see it. Skyline cannot delete it '
          'later, even if the message disappears.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save copy')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final bytes = await media.bytes(info);
      if (Platform.isAndroid || Platform.isIOS) {
        // Into the gallery (board 22). The OS asks for permission the first time.
        if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
          snack.showSnackBar(const SnackBar(content: Text('Skyline was not allowed to add to your photos.')));
          return;
        }
        await Gal.putImageBytes(bytes, name: MediaService.safeName(info.name));
        snack.showSnackBar(const SnackBar(content: Text('Saved to your photos.')));
        return;
      }
      final path = await FilePicker.saveFile(fileName: MediaService.safeName(info.name), bytes: bytes);
      if (path != null && Platform.isWindows) await File(path).writeAsBytes(bytes);
      if (path != null) snack.showSnackBar(const SnackBar(content: Text('Saved.')));
    } on Object {
      snack.showSnackBar(const SnackBar(content: Text('The copy could not be saved.')));
    }
  }


/// An album, one photo or video per page (board 23): swipe, or use the
/// arrows (and arrow keys) on a PC. Photos not on this device yet fetch
/// themselves; videos show a play button (or a download button).
class AlbumViewerScreen extends StatefulWidget {
  const AlbumViewerScreen({
    super.key,
    required this.m,
    required this.initial,
    required this.messenger,
    required this.from,
  });
  final LocalMessage m;
  final int initial;
  final Messenger messenger;
  final String from;

  @override
  State<AlbumViewerScreen> createState() => _AlbumViewerScreenState();
}

class _AlbumViewerScreenState extends State<AlbumViewerScreen> {
  late LocalMessage _m = widget.m;
  late final PageController _pages = PageController(initialPage: widget.initial);
  late int _page = widget.initial;
  final _focus = FocusNode();

  Messenger get messenger => widget.messenger;

  @override
  void initState() {
    super.initState();
    messenger.addListener(_reload);
    _fetch(_page);
  }

  @override
  void dispose() {
    messenger.removeListener(_reload);
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  // Downloads finish in the background: pick up the new state.
  Future<void> _reload() async {
    final fresh = await messenger.store.message(_m.id);
    if (fresh != null && mounted) setState(() => _m = fresh);
  }

  void _fetch(int i) {
    final info = _m.items[i];
    if (info.kind == MediaKind.photo && info.state == MediaState.remote) {
      unawaited(messenger.fetchMedia(_m.id, i));
    }
  }

  void _go(int delta) {
    final to = (_page + delta).clamp(0, _m.items.length - 1);
    if (to != _page) {
      _pages.animateToPage(to, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  bool _ready(MediaInfo i) => i.state == MediaState.ready && messenger.media.hasLocal(i);

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final n = _m.items.length;
    final current = _m.items[_page];
    final when = _m.sentAt.toLocal();
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
          _go(1);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _go(-1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
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
                    Text(widget.from,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
                    Text(_clock(when), style: TextStyle(fontSize: 12, color: t.textSecondary)),
                  ]),
                ),
                Semantics(
                  liveRegion: true,
                  child: Text('${_page + 1} of $n',
                      style: TextStyle(fontFamily: SkyFonts.mono, fontSize: 13, color: t.textSecondary)),
                ),
                IconButton(
                  tooltip: 'Save to this device',
                  onPressed: current.kind == MediaKind.photo && _ready(current)
                      ? () => saveUnencryptedCopy(context, messenger.media, current)
                      : null,
                  icon: SkyIcon(SkyIcons.download,
                      size: 20,
                      color: current.kind == MediaKind.photo && _ready(current)
                          ? const Color(0xFFE3E8F2)
                          : const Color(0xFF45526E),
                      stroke: 2),
                ),
              ]),
            ),
            Expanded(
              child: Stack(children: [
                ListenableBuilder(
                  listenable: messenger.media,
                  builder: (context, _) => PageView.builder(
                    controller: _pages,
                    itemCount: n,
                    onPageChanged: (i) {
                      setState(() => _page = i);
                      _fetch(i);
                    },
                    itemBuilder: (context, i) => _buildPage(context, i),
                  ),
                ),
                if (desktop && _page > 0)
                  Positioned(
                    left: 8,
                    top: 0,
                    bottom: 0,
                    child: Center(child: _arrow('Previous', SkyIcons.back, () => _go(-1))),
                  ),
                if (desktop && _page < n - 1)
                  Positioned(
                    right: 8,
                    top: 0,
                    bottom: 0,
                    child: Center(child: _arrow('Next', SkyIcons.chevron, () => _go(1))),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_m.text.isNotEmpty) ...[
                  Text(_m.text, style: TextStyle(fontSize: 14.5, color: t.textPrimary)),
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
      ),
    );
  }

  Widget _arrow(String label, SkyIcons icon, VoidCallback onTap) => IconButton(
        tooltip: label,
        onPressed: onTap,
        style: IconButton.styleFrom(backgroundColor: const Color(0x99141B2A), fixedSize: const Size(44, 44)),
        icon: SkyIcon(icon, size: 20, color: const Color(0xFFE3E8F2), stroke: 2.2),
      );

  // One photo or video.
  Widget _buildPage(BuildContext context, int i) {
    final t = context.sky;
    final info = _m.items[i];
    final tr = messenger.media.transfer(Messenger.transferKey(_m.id, i));
    if (info.state == MediaState.expired) {
      return Center(
        child: Text('${info.label} no longer available. Files are kept on the server for 30 days.',
            textAlign: TextAlign.center, style: TextStyle(color: t.textSecondary)),
      );
    }
    if (info.kind == MediaKind.photo && _ready(info)) {
      final cached = messenger.media.cached(info);
      return InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: cached != null
              ? Image.memory(cached, gaplessPlayback: true)
              : FutureBuilder<Uint8List>(
                  future: messenger.media.bytes(info),
                  builder: (context, snap) => snap.hasData
                      ? Image.memory(snap.data!, gaplessPlayback: true)
                      : const CircularProgressIndicator(),
                ),
        ),
      );
    }
    // Not decrypted yet (or a video): its preview, with what to do next.
    final Widget action;
    if (tr != null) {
      action = SizedBox(
        width: 48,
        height: 48,
        child: CircularProgressIndicator(value: tr.fraction, color: Colors.white, backgroundColor: Colors.white24),
      );
    } else if (info.kind == MediaKind.video && _ready(info)) {
      action = Semantics(
        button: true,
        label: 'Play video',
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => VideoScreen(info: info, media: messenger.media, from: widget.from),
          )),
          child: Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Color(0xB3080C16), shape: BoxShape.circle),
            child: const SkyIcon(SkyIcons.play, size: 26, color: Colors.white, filled: true),
          ),
        ),
      );
    } else if (info.state == MediaState.remote) {
      action = FilledButton.icon(
        onPressed: () => messenger.fetchMedia(_m.id, i),
        icon: const SkyIcon(SkyIcons.download, size: 16, color: Colors.white, stroke: 2.2),
        label: Text('${info.kind == MediaKind.video ? 'Video' : 'Photo'} · ${formatBytes(info.size)}'),
      );
    } else {
      action = const SizedBox.shrink();
    }
    final ratio = (info.width != null && info.height != null && info.height! > 0)
        ? (info.width! / info.height!).clamp(0.5, 2.0).toDouble()
        : 4 / 3;
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: Stack(fit: StackFit.expand, children: [
          _thumbOrGradient(info),
          Center(child: action),
        ]),
      ),
    );
  }
}
