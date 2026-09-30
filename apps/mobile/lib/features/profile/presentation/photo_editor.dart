import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../data/profile_photos.dart';

/// Board 46: take, choose or remove your profile photo.
Future<void> changeProfilePhoto(BuildContext context, ProfilePhotos photos) async {
  final t = context.sky;
  final canCamera = Platform.isAndroid || Platform.isIOS;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: t.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (canCamera)
            _SheetRow(icon: SkyIcons.camera, label: 'Take a photo', onTap: () => Navigator.pop(ctx, 'camera')),
          _SheetRow(icon: SkyIcons.photo, label: 'Choose from photos', onTap: () => Navigator.pop(ctx, 'gallery')),
          if (photos.hasMine)
            _SheetRow(
              icon: SkyIcons.trash,
              label: 'Remove photo (back to initials)',
              danger: true,
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          const SizedBox(height: 6),
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ]),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (choice == 'remove') {
      await photos.removeMine();
      return;
    }
    final picked = await ImagePicker().pickImage(
      source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
    );
    if (picked == null || !context.mounted) return;
    final bytes = await picked.readAsBytes();
    if (!context.mounted) return;
    final jpeg = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CropPage(original: bytes)),
    );
    if (jpeg == null) return;
    await photos.setMine(jpeg);
  } on Object {
    messenger.showSnackBar(const SnackBar(content: Text("Couldn't update your photo. Check your connection and try again.")));
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.icon, required this.label, required this.onTap, this.danger = false});
  final SkyIcons icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final color = danger ? t.danger : t.textPrimary;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
        child: Row(children: [
          SkyIcon(icon, size: 20, color: danger ? t.danger : t.accentText, stroke: 2),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: TextStyle(fontSize: 15, color: color))),
        ]),
      ),
    );
  }
}

/// "Move and scale": pinch or drag inside the circle, then Save. The result
/// is redrawn at 512 px and encoded as a fresh JPEG, so no location or camera
/// details survive, before it is encrypted.
class _CropPage extends StatefulWidget {
  const _CropPage({required this.original});
  final Uint8List original;

  @override
  State<_CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<_CropPage> {
  final _frame = GlobalKey();
  bool _saving = false;

  static const _out = 512;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final box = _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final shot = await box.toImage(pixelRatio: _out / box.size.width);
      final rgba = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);
      final image = img.Image.fromBytes(
        width: shot.width,
        height: shot.height,
        bytes: rgba!.buffer,
        numChannels: 4,
      );
      final square = img.copyResize(image, width: _out, height: _out);
      final jpeg = Uint8List.fromList(img.encodeJpg(square, quality: 85));
      if (mounted) Navigator.pop(context, jpeg);
    } on Object {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05070C),
      appBar: AppBar(
        backgroundColor: const Color(0xFF05070C),
        foregroundColor: Colors.white,
        leading: TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Color(0xFFC4CDDF))),
        ),
        leadingWidth: 90,
        title: const Text('Move and scale', style: TextStyle(color: Colors.white)),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(72, 36)),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final side = (box.maxWidth < box.maxHeight - 120 ? box.maxWidth : box.maxHeight - 120) - 48;
          return Column(children: [
            Expanded(
              child: Center(
                child: SizedBox(
                  width: side,
                  height: side,
                  child: Stack(children: [
                    // What is inside this square is what gets saved.
                    RepaintBoundary(
                      key: _frame,
                      child: ClipRect(
                        child: InteractiveViewer(
                          minScale: 1,
                          maxScale: 5,
                          child: SizedBox(
                            width: side,
                            height: side,
                            child: Image.memory(widget.original, fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    ),
                    // The circle it will be shown in.
                    IgnorePointer(
                      child: CustomPaint(size: Size(side, side), painter: _CircleMask()),
                    ),
                  ]),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Text(
                'Pinch to zoom, drag to move. The photo is made smaller and its location and camera details are '
                "removed before it's encrypted.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.5, color: Color(0xFF8E9BB4)),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}

class _CircleMask extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect)
      ..addOval(rect);
    canvas.drawPath(shade, Paint()..color = const Color(0x99000000));
    canvas.drawOval(
      rect.deflate(1),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CircleMask old) => false;
}
