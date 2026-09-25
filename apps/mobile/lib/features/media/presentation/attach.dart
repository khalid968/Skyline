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

/// Board 20: the attach menu. Returns the chosen file, or null.
Future<PickedMedia?> showAttachSheet(BuildContext context) async {
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
            'Up to 2 GB per file. Photos, videos, voice messages and documents are all encrypted on this '
            'device first; the server only ever stores unreadable bytes.',
            style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
          ),
        ]),
      ),
    ),
  );
  if (choice == null) return null;
  return _pick(choice);
}

Future<PickedMedia?> _pick(_Source source) async {
  if (source == _Source.camera) {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera);
    if (shot == null) return null;
    return PickedMedia(File(shot.path), MediaKind.photo, shot.name, temporary: true);
  }
  final result = await FilePicker.pickFiles(
    type: switch (source) {
      _Source.photos => FileType.image,
      _Source.video => FileType.video,
      _ => FileType.any,
    },
  );
  final f = result?.files.singleOrNull;
  if (f == null || f.path == null) return null;
  final kind = switch (source) {
    _Source.photos => MediaKind.photo,
    _Source.video => MediaKind.video,
    _ => MediaKind.file,
  };
  // On phones the picker hands us its own copy (safe to delete); on Windows
  // it is the person's original file.
  return PickedMedia(File(f.path!), kind, f.name, temporary: Platform.isAndroid || Platform.isIOS);
}

/// Board 20: the preview with a caption. Returns the caption to send with,
/// or null if the person backed out.
Future<String?> showMediaPreview(BuildContext context, PickedMedia media, {required String peerName}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PreviewScreen(media: media, peerName: peerName),
    ));

class _PreviewScreen extends StatefulWidget {
  const _PreviewScreen({required this.media, required this.peerName});
  final PickedMedia media;
  final String peerName;

  @override
  State<_PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<_PreviewScreen> {
  final _caption = TextEditingController();
  late final int _size = widget.media.file.lengthSync();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final m = widget.media;
    final label = '${m.name} · ${formatBytes(_size)}';
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
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(18),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: BorderRadius.circular(16)),
              child: Stack(fit: StackFit.expand, children: [
                if (m.kind == MediaKind.photo)
                  Image.file(m.file, fit: BoxFit.contain, errorBuilder: (context, error, stack) => _bigIcon(m.kind, t))
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
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: Row(children: [
              SkyIcon(SkyIcons.lock, size: 14, color: t.accentText, stroke: 2),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Encrypted on this device before it leaves. Kept on the server for 30 days.',
                    style: TextStyle(fontSize: 12, color: t.textSecondary)),
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
                  autofocus: false,
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
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: switch (m.kind) {
                  MediaKind.photo => 'Send photo',
                  MediaKind.video => 'Send video',
                  _ => 'Send file',
                },
                style: IconButton.styleFrom(fixedSize: const Size(44, 44)),
                onPressed: () => Navigator.pop(context, _caption.text.trim()),
                icon: const SkyIcon(SkyIcons.send, size: 19, color: Colors.white, stroke: 2),
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
