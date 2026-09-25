import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../messages/domain/models.dart';
import 'media_format.dart';

/// A file the person chose to send. [temporary] files are plaintext copies
/// we made (a camera shot, the picker's copy on a phone) and are deleted once
/// encrypted; on Windows the picker returns the person's own file, which we
/// never touch.
class PickedMedia {
  PickedMedia(this.file, this.kind, this.name, {this.temporary = false});
  final File file;
  final MediaKind kind;
  final String name;
  final bool temporary;

  Future<void> discard() async {
    if (!temporary) return;
    try {
      await file.delete();
    } on FileSystemException {
      // already gone
    }
  }
}

enum _Source { photos, camera, video, file }

bool get _hasCamera => Platform.isAndroid || Platform.isIOS;

/// The most files one send can carry (board 23).
const maxPick = 10;

/// Board 20: the attach menu. Returns the chosen files (up to [maxPick]),
/// or null.
Future<List<PickedMedia>?> showAttachSheet(BuildContext context) async {
  final t = context.sky;
  final options = [
    (_Source.photos, 'Photos', SkyIcons.photo, const Color(0xFF3A63D8)),
    if (_hasCamera) (_Source.camera, 'Camera', SkyIcons.camera, const Color(0xFF2C7F6B)),
    (_Source.video, 'Video', SkyIcons.video, const Color(0xFF7A5AF0)),
    (_Source.file, 'File', SkyIcons.file, const Color(0xFFC1743A)),
  ];
  final choice = await showModalBottomSheet<_Source>(
    context: context,
    backgroundColor: t.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            for (final o in options)
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => Navigator.pop(ctx, o.$1),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(children: [
                      Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: o.$4, borderRadius: BorderRadius.circular(18)),
                        child: SkyIcon(o.$3, size: 24, color: Colors.white),
                      ),
                      const SizedBox(height: 8),
                      Text(o.$2, style: const TextStyle(fontSize: 12.5, color: Color(0xFFD5DCEA))),
                    ]),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          Text(
            'Up to 10 at a time, 2 GB each. Photos, videos, voice messages and documents are all encrypted '
            'on this device first; the server only ever stores unreadable bytes.',
            style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
          ),
        ]),
      ),
    ),
  );
  if (choice == null) return null;
  final picked = await _pick(choice, maxPick);
  return picked.isEmpty ? null : picked;
}

/// Opens the picker for [source]. Anything past [room] files is dropped
/// (and, on phones, the picker's copies deleted).
Future<List<PickedMedia>> _pick(_Source source, int room) async {
  if (room <= 0) return const [];
  if (source == _Source.camera) {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera);
    if (shot == null) return const [];
    return [PickedMedia(File(shot.path), MediaKind.photo, shot.name, temporary: true)];
  }
  final result = await FilePicker.pickFiles(
    allowMultiple: true,
    type: switch (source) {
      _Source.photos => FileType.image,
      _Source.video => FileType.video,
      _ => FileType.any,
    },
  );
  final kind = switch (source) {
    _Source.photos => MediaKind.photo,
    _Source.video => MediaKind.video,
    _ => MediaKind.file,
  };
  // On phones the picker hands us its own copies (safe to delete); on
  // Windows they are the person's original files.
  final phone = Platform.isAndroid || Platform.isIOS;
  final all = [
    for (final f in result?.files ?? const <PlatformFile>[])
      if (f.path != null) PickedMedia(File(f.path!), kind, f.name, temporary: phone),
  ];
  for (final extra in all.skip(room)) {
    await extra.discard();
  }
  return all.take(room).toList();
}

/// What the preview returns: the files still chosen, the caption, and
/// whether it is view-once (board 24).
class PreviewResult {
  PreviewResult(this.items, this.caption, {this.viewOnce = false});
  final List<PickedMedia> items;
  final String caption;
  final bool viewOnce;
}

/// Boards 20, 23 and 24: the preview with a caption, for one file or
/// several. Returns what to send, or null if the person backed out (the
/// caller then discards the files).
Future<PreviewResult?> showMediaPreview(BuildContext context, List<PickedMedia> media, {required String peerName}) =>
    Navigator.of(context).push<PreviewResult>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PreviewScreen(media: media, peerName: peerName),
    ));

class _PreviewScreen extends StatefulWidget {
  const _PreviewScreen({required this.media, required this.peerName});
  final List<PickedMedia> media;
  final String peerName;

  @override
  State<_PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<_PreviewScreen> {
  final _caption = TextEditingController();
  late final List<PickedMedia> _items = [...widget.media];
  int _current = 0;
  bool _viewOnce = false;

  PickedMedia get _shown => _items[_current.clamp(0, _items.length - 1)];

  /// View once is for a single photo or video (board 24), including a
  /// picture or video picked through File.
  bool get _canViewOnce => _items.length == 1 && _visualKind(_items.first) != null;

  static MediaKind? _visualKind(PickedMedia p) {
    if (p.kind == MediaKind.photo || p.kind == MediaKind.video) return p.kind;
    final ext = p.name.contains('.') ? p.name.split('.').last.toLowerCase() : '';
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'}.contains(ext)) return MediaKind.photo;
    if (const {'mp4', 'mov', 'm4v', 'webm', 'avi', 'mkv'}.contains(ext)) return MediaKind.video;
    return null;
  }

  void _toggleViewOnce() {
    if (!_canViewOnce) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_items.length > 1
            ? 'View once works with one photo or video at a time. Remove the others to use it.'
            : 'View once works with photos and videos.'),
      ));
      return;
    }
    setState(() => _viewOnce = !_viewOnce);
  }

  /// What is sent: with view once, a picture picked through File goes as a
  /// photo (a view-once message is always a photo or a video).
  List<PickedMedia> get _toSend => [
        for (final p in _items)
          _viewOnce && p.kind == MediaKind.file && _visualKind(p) != null
              ? PickedMedia(p.file, _visualKind(p)!, p.name, temporary: p.temporary)
              : p,
      ];

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _remove(int i) async {
    if (_items.length == 1) return;
    final gone = _items.removeAt(i);
    await gone.discard();
    setState(() {
      if (_current >= _items.length) _current = _items.length - 1;
      if (!_canViewOnce) _viewOnce = false;
    });
  }

  Future<void> _add() async {
    final more = await _pick(_sourceFor(_shown.kind), maxPick - _items.length);
    if (!mounted || more.isEmpty) return;
    setState(() {
      _items.addAll(more);
      _current = _items.length - 1;
      if (!_canViewOnce) _viewOnce = false;
    });
  }

  static _Source _sourceFor(MediaKind k) => switch (k) {
        MediaKind.photo => _Source.photos,
        MediaKind.video => _Source.video,
        _ => _Source.file,
      };

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final m = _shown;
    final label = '${m.name} · ${formatBytes(m.file.lengthSync())}';
    return Scaffold(
      backgroundColor: const Color(0xFF070A12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF070A12),
        leading: IconButton(
          tooltip: 'Cancel',
          onPressed: () => Navigator.pop(context),
          icon: SkyIcon(SkyIcons.close, size: 20, color: t.textPrimary, stroke: 2.2),
        ),
        title: Text('To ${widget.peerName}', style: TextStyle(fontSize: 15.5, color: t.textPrimary)),
        actions: [
          if (_items.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text('${_current + 1} of ${_items.length}',
                    style: TextStyle(fontFamily: SkyFonts.mono, fontSize: 13, color: t.textSecondary)),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(18, 10, 18, 10),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: BorderRadius.circular(16)),
              child: Stack(fit: StackFit.expand, children: [
                if (m.kind == MediaKind.photo)
                  Image.file(m.file,
                      key: ValueKey(m.file.path),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stack) => _bigIcon(m.kind, t))
                else
                  _bigIcon(m.kind, t),
                Positioned(
                  left: 12,
                  bottom: 12,
                  right: 12,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0x99080C16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Color(0xFFE3E8F2))),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          // Board 23: the strip. Tap to look, x to drop, + to add more.
          SizedBox(
            height: 70,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
              children: [
                for (var i = 0; i < _items.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _StripTile(
                      item: _items[i],
                      selected: i == _current,
                      canRemove: _items.length > 1,
                      onTap: () => setState(() => _current = i),
                      onRemove: () => _remove(i),
                    ),
                  ),
                if (_items.length < maxPick && _shown.kind != MediaKind.voice)
                  Semantics(
                    button: true,
                    label: 'Add more',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _add,
                      child: Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF33405C)),
                        ),
                        child: SkyIcon(SkyIcons.plus, size: 20, color: t.textSecondary, stroke: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_viewOnce)
            Container(
              margin: const EdgeInsets.fromLTRB(18, 6, 18, 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF161E2F),
                border: Border.all(color: t.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const _OnceBadge(on: true, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'View once: ${widget.peerName.split(' ').first} can open it one time, then it is gone from '
                    'their devices and yours. Screenshots are blocked on Android and Windows, but nothing stops a '
                    'second camera.',
                    style: const TextStyle(fontSize: 12, height: 1.5, color: Color(0xFFC4CDDF)),
                  ),
                ),
              ]),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
              child: Row(children: [
                SkyIcon(SkyIcons.lock, size: 14, color: t.accentText, stroke: 2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _items.length > 1
                        ? 'Up to 10 at a time. Each one is encrypted on this device with its own key.'
                        : 'Encrypted on this device before it leaves. Kept on the server for 30 days.',
                    style: TextStyle(fontSize: 12, color: t.textSecondary),
                  ),
                ),
              ]),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
            decoration: BoxDecoration(color: t.ground, border: Border(top: BorderSide(color: t.border))),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _caption,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: 'Add a caption',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22)),
                  ),
                  style: TextStyle(fontSize: 14.5, color: t.textPrimary),
                ),
              ),
              // Always shown, so it can be found; greyed when it cannot apply.
              const SizedBox(width: 8),
              Tooltip(
                message: _canViewOnce ? 'View once' : 'View once: one photo or video at a time',
                child: Semantics(
                  button: true,
                  toggled: _viewOnce,
                  label: 'View once',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _toggleViewOnce,
                    child: Opacity(opacity: _canViewOnce ? 1 : 0.45, child: _OnceBadge(on: _viewOnce, size: 40)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Badge(
                isLabelVisible: _items.length > 1,
                label: Text('${_items.length}'),
                backgroundColor: t.textPrimary,
                textColor: t.ground,
                child: IconButton.filled(
                  tooltip: _items.length > 1
                      ? 'Send ${_items.length} items'
                      : switch (m.kind) {
                          MediaKind.photo => 'Send photo',
                          MediaKind.video => 'Send video',
                          _ => 'Send file',
                        },
                  style: IconButton.styleFrom(fixedSize: const Size(44, 44)),
                  onPressed: () => Navigator.pop(
                    context,
                    PreviewResult(_toSend, _caption.text.trim(), viewOnce: _viewOnce && _canViewOnce),
                  ),
                  icon: const SkyIcon(SkyIcons.send, size: 19, color: Colors.white, stroke: 2),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _bigIcon(MediaKind kind, SkylineTokens t) => Center(
        child: SkyIcon(
          kind == MediaKind.video ? SkyIcons.video : (kind == MediaKind.photo ? SkyIcons.photo : SkyIcons.file),
          size: 64,
          color: t.accentText,
          stroke: 1.4,
        ),
      );
}

class _StripTile extends StatelessWidget {
  const _StripTile({
    required this.item,
    required this.selected,
    required this.canRemove,
    required this.onTap,
    required this.onRemove,
  });
  final PickedMedia item;
  final bool selected;
  final bool canRemove;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return SizedBox(
      width: 58,
      height: 58,
      child: Stack(clipBehavior: Clip.none, children: [
        Semantics(
          button: true,
          selected: selected,
          label: item.name,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 56,
              height: 56,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: item.kind == MediaKind.file ? const Color(0xFFC1743A) : t.surfaceRaised,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: selected ? t.accentText : Colors.transparent, width: 2),
              ),
              child: item.kind == MediaKind.photo
                  ? Image.file(item.file,
                      fit: BoxFit.cover,
                      cacheWidth: 112,
                      errorBuilder: (context, error, stack) =>
                          const Center(child: SkyIcon(SkyIcons.photo, size: 20, color: Colors.white)))
                  : Center(
                      child: SkyIcon(item.kind == MediaKind.video ? SkyIcons.video : SkyIcons.file,
                          size: 20, color: Colors.white)),
            ),
          ),
        ),
        if (canRemove)
          Positioned(
            top: -7,
            right: -7,
            child: Semantics(
              button: true,
              label: 'Remove ${item.name}',
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.surfaceRaised,
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF33405C)),
                  ),
                  child: SkyIcon(SkyIcons.close, size: 10, color: t.textPrimary, stroke: 3),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Board 24's dashed "1": view once, on (amber) or off.
class _OnceBadge extends StatelessWidget {
  const _OnceBadge({required this.on, required this.size});
  final bool on;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final c = on ? t.caution : const Color(0xFF8E9BB4);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? const Color(0xFF3A2A10) : (size > 30 ? t.surfaceRaised : Colors.transparent),
        shape: BoxShape.circle,
        border: Border.all(color: on ? c : const Color(0xFF33405C), width: 2),
      ),
      child: Text('1',
          style: TextStyle(
              fontFamily: SkyFonts.display, fontSize: size > 30 ? 15 : 11, fontWeight: FontWeight.w700, color: c)),
    );
  }
}
