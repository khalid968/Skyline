// Boards 20-22, rendered for real: two devices exchange a photo, a video, a
// document and a voice message through a RUNNING throwaway backend, then the
// conversation screen is drawn on each side and saved as PNGs to compare
// with the approved boards.
//
//   flutter test integration_test/media_ui_test.dart -d windows \
//     --dart-define=SKYLINE_API=http://localhost:3078 \
//     --dart-define=ALICE_ID=... --dart-define=ALICE_CODE=... \
//     --dart-define=BOB_ID=...   --dart-define=BOB_CODE=... \
//     --dart-define=SHOTS=C:/path/to/folder
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/app/app_controller.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/core/theme/app_theme.dart';
import 'package:skyline/features/media/presentation/attach.dart';
import 'package:skyline/features/media/presentation/media_gallery_screen.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/domain/models.dart';
import 'package:skyline/features/messages/presentation/conversation_screen.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const aliceId = String.fromEnvironment('ALICE_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobId = String.fromEnvironment('BOB_ID');
const bobCode = String.fromEnvironment('BOB_CODE');
const shots = String.fromEnvironment('SHOTS');

final _frame = GlobalKey();

Future<void> _show(WidgetTester tester, Messenger me, String peer, {Widget? screen}) async {
  // Unmount the previous screen: the frame's GlobalKey would otherwise
  // carry its state (and its messenger) over.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  final app = AppController()..messenger = me;
  await tester.pumpWidget(ProviderScope(
    key: ValueKey(me.me),
    overrides: [appControllerProvider.overrideWith((ref) => app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      // The frame wraps the navigator, so sheets and dialogs are captured too.
      builder: (context, child) => Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: _frame,
          child: SizedBox(
            width: 390,
            height: 844,
            child: MediaQuery(data: const MediaQueryData(size: Size(390, 844)), child: child!),
          ),
        ),
      ),
      home: screen ?? ConversationScreen(peer: peer),
    ),
  ));
  await _settle(tester);
}

/// Lets decryption (real async work in Rust) finish between frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final boundary = _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  final f = File('$shots${Platform.pathSeparator}$name.png');
  await f.writeAsBytes(bytes!);
}

/// A second of a 440 Hz tone, as WAV: a stand-in voice message.
Uint8List _tone() {
  const rate = 8000;
  final pcm = BytesBuilder();
  for (var i = 0; i < rate; i++) {
    final v = (8000 * (i % 18 < 9 ? 1 : -1)).toInt();
    pcm.add([v & 0xff, (v >> 8) & 0xff]);
  }
  final data = pcm.toBytes();
  final h = ByteData(44)
    ..setUint32(0, 0x52494646)
    ..setUint32(4, 36 + data.length, Endian.little)
    ..setUint32(8, 0x57415645)
    ..setUint32(12, 0x666d7420)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x64617461)
    ..setUint32(40, data.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...data]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('media in a chat, both sides', (tester) async {
    expect(shots, isNotEmpty, reason: 'pass --dart-define=SHOTS=<folder>');
    late Messenger alice;
    late Messenger bob;
    await tester.runAsync(() async {
      alice = await device(aliceCode, 'Alice test PC');
      bob = await device(bobCode, 'Bob test PC');
      await eventually(() async => alice.connection == ConnectionStatus.online ? true : null);
      await eventually(() async => bob.connection == ConnectionStatus.online ? true : null);
      await alice.refreshContacts();
      await bob.refreshContacts();

      final dir = await Directory.systemTemp.createTemp('skyline-ui-');
      String p(String n) => '${dir.path}${Platform.pathSeparator}$n';
      await bob.sendText(aliceId, 'Can you send me the site photos and the survey PDF?');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // A warm gradient "photo".
      final photo = img.Image(width: 800, height: 600);
      for (var y = 0; y < 600; y++) {
        for (var x = 0; x < 800; x++) {
          photo.setPixelRgb(x, y, 127 + x * 100 ~/ 800, 106 + y * 80 ~/ 600, 78 + (x + y) * 90 ~/ 1400);
        }
      }
      File(p('entrance.jpg')).writeAsBytesSync(img.encodeJpg(photo, quality: 85));
      await alice.sendMedia(bobId, File(p('entrance.jpg')), MediaKind.photo, caption: 'The new entrance');

      File(p('walkthrough.mp4')).writeAsBytesSync(List<int>.filled(300 * 1024, 7));
      await alice.sendMedia(bobId, File(p('walkthrough.mp4')), MediaKind.video, durationMs: 161000);

      File(p('Site_Survey_v3.pdf')).writeAsBytesSync(List<int>.filled(1200 * 1024, 3));
      await alice.sendMedia(bobId, File(p('Site_Survey_v3.pdf')), MediaKind.file);

      File(p('voice.wav')).writeAsBytesSync(_tone());
      await alice.sendMedia(bobId, File(p('voice.wav')), MediaKind.voice,
          durationMs: 42000,
          wave: const [8, 14, 20, 12, 22, 26, 16, 10, 18, 24, 14, 8, 12, 20, 26, 18, 10, 14, 22, 16, 8, 12, 18, 24],
          name: 'Voice message.wav');

      // Board 23: five photos at once, as one album.
      final album = <OutgoingFile>[];
      for (var n = 0; n < 5; n++) {
        final pic = img.Image(width: 600, height: 450);
        for (var y = 0; y < 450; y += 3) {
          for (var x = 0; x < 600; x += 3) {
            img.fillRect(pic, x1: x, y1: y, x2: x + 3, y2: y + 3,
                color: img.ColorRgb8(60 + n * 35, 80 + y * 90 ~/ 450, 120 + x * 80 ~/ 600));
          }
        }
        final f = File(p('visit-$n.jpg'))..writeAsBytesSync(img.encodeJpg(pic, quality: 80));
        album.add(OutgoingFile(f, MediaKind.photo));
      }
      await alice.sendFiles(bobId, album, caption: 'Site visit, north side');

      // Board 24: a view-once photo.
      File(p('secret.jpg')).writeAsBytesSync(img.encodeJpg(photo, quality: 80));
      await alice.sendMedia(bobId, File(p('secret.jpg')), MediaKind.photo, viewOnce: true);

      // Bob's photos and voice message fetch themselves; the others wait.
      await eventually(() async {
        final ms = await bob.store.messages(aliceId);
        final ready = [for (final m in ms) ...m.items].where((i) => i.state == MediaState.ready).length;
        return ready >= 8 ? true : null;
      });
    });

    await _show(tester, bob, aliceId);
    await _shot(tester, '21-bob-receives');

    await _show(tester, alice, bobId);
    await _shot(tester, '20-alice-sent');

    // The attach menu (board 20).
    await tester.tap(find.byTooltip('Attach'));
    await _settle(tester);
    await _shot(tester, '20-attach-sheet');

    // Board 25: Bob's gallery.
    await _show(tester, bob, aliceId, screen: const MediaGalleryScreen(peer: aliceId));
    await _shot(tester, '25-gallery-media');
    await tester.tap(find.text('Files'));
    await _settle(tester);
    await _shot(tester, '25-gallery-files');

    // Board 23: the preview with several files picked; board 24: one photo,
    // view once switched on.
    late List<PickedMedia> picks;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('skyline-pick-');
      picks = [
        for (var n = 0; n < 4; n++)
          PickedMedia(
            File('${dir.path}${Platform.pathSeparator}pick-$n.jpg')
              ..writeAsBytesSync(img.encodeJpg(img.Image(width: 300, height: 220)..clear(img.ColorRgb8(50 + n * 40, 100, 170)))),
            MediaKind.photo,
            'pick-$n.jpg',
          ),
      ];
    });
    await _show(tester, alice, bobId, screen: Builder(builder: (context) {
      return Scaffold(body: Center(child: FilledButton(
        onPressed: () => showMediaPreview(context, picks, peerName: 'Bob Example'),
        child: const Text('open preview'),
      )));
    }));
    await tester.tap(find.text('open preview'));
    await _settle(tester);
    await _shot(tester, '23-preview-several');
    await _show(tester, alice, bobId, screen: Builder(builder: (context) {
      return Scaffold(body: Center(child: FilledButton(
        onPressed: () => showMediaPreview(context, [picks.first], peerName: 'Bob Example'),
        child: const Text('open preview'),
      )));
    }));
    await tester.tap(find.text('open preview'));
    await _settle(tester);
    await tester.tap(find.text('1').last); // the view-once toggle
    await _settle(tester);
    await _shot(tester, '24-preview-view-once');

    await tester.runAsync(() async {
      alice.dispose();
      bob.dispose();
    });
  });
}
