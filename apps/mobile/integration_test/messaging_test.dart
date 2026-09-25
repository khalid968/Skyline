// Phase 8a end to end, inside the real app build: two devices (each its own
// encrypted vault and the real libsignal core) activate against a RUNNING
// backend, find each other through the admin-made contact link, and talk.
//
// Needs a throwaway backend (apps/backend/scripts/e2e-fixture.js create) and:
//   flutter test integration_test/messaging_test.dart -d windows \
//     --dart-define=SKYLINE_API=http://localhost:3078 \
//     --dart-define=ALICE_ID=... --dart-define=ALICE_CODE=... \
//     --dart-define=BOB_ID=...   --dart-define=BOB_CODE=...
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/api/api_client.dart';
import 'package:skyline/core/api/session.dart';
import 'package:skyline/core/config.dart';
import 'package:skyline/core/crypto/device_crypto.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/auth/data/activation_service.dart';
import 'package:skyline/features/media/data/media_service.dart';
import 'package:skyline/features/messages/data/local_store.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/domain/models.dart';
import 'package:skyline/src/rust/frb_generated.dart';

const aliceId = String.fromEnvironment('ALICE_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobId = String.fromEnvironment('BOB_ID');
const bobCode = String.fromEnvironment('BOB_CODE');

Future<Messenger> device(String code, String name) async {
  final crypto = await CryptoDevice.openInMemory();
  final sessions = MemorySessionStore();
  final api = ApiClient(base: AppConfig.apiBase, sessions: sessions, crypto: crypto);
  final session = await ActivationService(api: api, crypto: crypto, sessions: sessions)
      .activate(code: code, deviceName: name);
  final tmp = await Directory.systemTemp.createTemp('skyline-test-');
  final m = Messenger(
    api: api,
    crypto: crypto,
    store: LocalStore(crypto),
    realtime: RealtimeClient(api: api, uri: AppConfig.socketUri),
    session: session,
    media: MediaService(
      api: api,
      dir: Directory('${tmp.path}${Platform.pathSeparator}media'),
      viewDir: Directory('${tmp.path}${Platform.pathSeparator}view'),
    ),
  );
  await m.start();
  return m;
}

/// Polls until [check] holds (the other side is asynchronous: socket nudge,
/// pull, decrypt, store).
Future<T> eventually<T>(Future<T?> Function() check, {Duration within = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(within);
  while (DateTime.now().isBefore(end)) {
    final v = await check();
    if (v != null) return v;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TestFailure('timed out');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('two devices talk through the real server', (_) async {
    expect(aliceCode, isNotEmpty, reason: 'run with the fixture --dart-defines');
    final alice = await device(aliceCode, 'Alice test PC');
    final bob = await device(bobCode, 'Bob test PC');
    addTearDown(() {
      alice.dispose();
      bob.dispose();
    });

    // Both are online, and each finds the other through the admin's link.
    await eventually(() async => alice.connection == ConnectionStatus.online ? true : null);
    await eventually(() async => bob.connection == ConnectionStatus.online ? true : null);
    await alice.refreshContacts();
    await bob.refreshContacts();
    expect(alice.contacts.map((c) => c.userId), [bobId]);
    expect(bob.contacts.map((c) => c.userId), [aliceId]);

    // Alice writes; the server nudges Bob, Bob pulls, decrypts and stores it.
    final sent = await alice.sendText(bobId, 'Hello Bob, this is end-to-end encrypted.');
    expect(sent.status, MessageStatus.sent);
    final got = await eventually(() => bob.store.message(sent.id));
    expect(got.text, 'Hello Bob, this is end-to-end encrypted.');
    expect(got.fromMe, isFalse);
    expect((await bob.store.chat(aliceId))!.unread, 1);

    // Bob's device acknowledged it: Alice sees two ticks.
    await eventually(() async =>
        (await alice.store.message(sent.id))!.status == MessageStatus.delivered ? true : null);

    // Bob opens the chat: unread clears and Alice sees "read".
    await bob.markRead(aliceId);
    expect((await bob.store.chat(aliceId))!.unread, 0);
    await eventually(() async =>
        (await alice.store.message(sent.id))!.status == MessageStatus.read ? true : null);

    // And back.
    final reply = await bob.sendText(aliceId, 'Got it, Alice.');
    final back = await eventually(() => alice.store.message(reply.id));
    expect(back.text, 'Got it, Alice.');

    // Media (boards 20-22). A photo downloads by itself and decrypts to the
    // exact bytes; a 9 MB document (two 8 MB parts) waits for a tap.
    final dir = await Directory.systemTemp.createTemp('skyline-media-src-');
    // A 3000x2000 camera JPEG that records where it was taken (EXIF GPS).
    final original = img.Image(width: 3000, height: 2000)..clear(img.ColorRgb8(58, 99, 216));
    original.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(51, 1);
    original.exif.imageIfd['Make'] = img.IfdValueAscii('SkylineTestCam');
    final photoBytes = img.encodeJpg(original, quality: 95);
    expect(img.decodeJpgExif(photoBytes)!.imageIfd['Make'], isNotNull, reason: 'the fixture really has EXIF');
    final photoFile = File('${dir.path}${Platform.pathSeparator}site-north.jpg')..writeAsBytesSync(photoBytes);
    final photo = await alice.sendMedia(bobId, photoFile, MediaKind.photo, caption: 'North elevation, today');
    expect(photo.status, MessageStatus.sent);
    expect(photo.media!.state, MediaState.ready);
    expect(photo.media!.thumb, isNotNull);
    final gotPhoto = await eventually(() async {
      final m = await bob.store.message(photo.id);
      return m?.media?.state == MediaState.ready ? m : null;
    });
    expect(gotPhoto.text, 'North elevation, today');
    // What arrives is the photo, made smaller, with the camera and location
    // details gone.
    final received = await bob.media.bytes(gotPhoto.media!);
    final decoded = img.decodeJpg(received)!;
    expect((decoded.width, decoded.height), (2048, 1365));
    expect(decoded.getPixel(10, 10).b, closeTo(216, 3));
    final exif = img.decodeJpgExif(received);
    expect(exif == null || (exif.gpsIfd.isEmpty && exif.imageIfd['Make'] == null), isTrue);
    expect(received.length, lessThan(photoBytes.length));
    expect(gotPhoto.media!.name, 'site-north.jpg');
    expect((await bob.store.chat(aliceId))!.lastText, 'Photo · North elevation, today');

    final docBytes = List<int>.generate(9 * 1024 * 1024 + 123, (i) => (i * 31 + 7) & 0xff);
    final docFile = File('${dir.path}${Platform.pathSeparator}Site_Survey_v3.pdf')..writeAsBytesSync(docBytes);
    final doc = await alice.sendMedia(bobId, docFile, MediaKind.file);
    expect(doc.status, MessageStatus.sent);
    final gotDoc = await eventually(() => bob.store.message(doc.id));
    expect(gotDoc.media!.state, MediaState.remote); // documents wait for a tap
    expect(gotDoc.media!.name, 'Site_Survey_v3.pdf');
    await bob.fetchMedia(doc.id);
    final fetched = (await bob.store.message(doc.id))!;
    expect(fetched.media!.state, MediaState.ready);
    final plain = await bob.media.plainCopy(fetched.media!);
    expect(plain.readAsBytesSync(), docBytes);
    await bob.media.discard(plain);
    expect(plain.existsSync(), isFalse);
    // What sits on Bob's disk is ciphertext, not the document.
    final kept = bob.media.fileOf(fetched.media!).readAsBytesSync();
    expect(kept.length, docBytes.length + 16);
    expect(kept.sublist(0, 64), isNot(docBytes.sublist(0, 64)));

    // Several at once (board 23): three photos and a PDF make an album of
    // three (one message, one caption) and a separate document message.
    final albumFiles = [
      for (var i = 0; i < 3; i++)
        File('${dir.path}${Platform.pathSeparator}album-$i.png')
          ..writeAsBytesSync(img.encodePng(img.Image(width: 400, height: 300)..clear(img.ColorRgb8(40 * i, 90, 160)))),
    ];
    final pdf = File('${dir.path}${Platform.pathSeparator}notes.pdf')..writeAsBytesSync(List<int>.filled(5000, 1));
    final sent2 = await alice.sendFiles(
      bobId,
      [for (final f in albumFiles) OutgoingFile(f, MediaKind.photo), OutgoingFile(pdf, MediaKind.file)],
      caption: 'Site visit, north side',
    );
    expect(sent2, hasLength(2));
    expect(sent2.first.items, hasLength(3));
    expect(sent2.first.text, 'Site visit, north side');
    expect(sent2.last.items.single.name, 'notes.pdf');
    expect(sent2.every((m) => m.status == MessageStatus.sent), isTrue);
    final album = await eventually(() async {
      final m = await bob.store.message(sent2.first.id);
      return m != null && m.items.every((i) => i.state == MediaState.ready) ? m : null;
    });
    expect(album.items, hasLength(3));
    for (var i = 0; i < 3; i++) {
      final px = img.decodePng(await bob.media.bytes(album.items[i]))!.getPixel(5, 5);
      expect(px.r, closeTo(40 * i, 2));
    }
    expect((await bob.store.chat(aliceId))!.lastText, isNot(contains('view once')));

    // View once (board 24): no preview travels; Alice cannot reopen it; Bob
    // opens it once, then it is gone on his side and Alice sees Opened.
    final secret = File('${dir.path}${Platform.pathSeparator}secret.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 300, height: 300)..clear(img.ColorRgb8(200, 10, 10))));
    final once = await alice.sendMedia(bobId, secret, MediaKind.photo, viewOnce: true);
    expect(once.status, MessageStatus.sent);
    final aliceCopy = (await alice.store.message(once.id))!;
    expect(aliceCopy.viewOnce, isTrue);
    expect(aliceCopy.items.single.burned, isTrue, reason: 'the sender cannot reopen it');
    final bobOnce = await eventually(() async {
      final m = await bob.store.message(once.id);
      return m?.items.single.state == MediaState.ready ? m : null;
    });
    expect(bobOnce.viewOnce, isTrue);
    expect(bobOnce.items.single.thumb, isNull, reason: 'no preview outlives the viewing');
    expect(img.decodePng(await bob.media.bytes(bobOnce.items.single)), isNotNull);
    final onDisk = bob.media.fileOf(bobOnce.items.single);
    await bob.viewOnceOpened(once.id);
    final after = (await bob.store.message(once.id))!;
    expect(after.items.single.burned, isTrue);
    expect(after.openedAt, isNotNull);
    expect(onDisk.existsSync(), isFalse);
    await eventually(() async => (await alice.store.message(once.id))!.openedAt != null ? true : null);

    // A disappearing-message timer is announced on both sides.
    await alice.setTimer(bobId, 3600);
    await eventually(() async => (await bob.store.chat(aliceId))!.timerSeconds == 3600 ? true : null);
    final notices = (await bob.store.messages(aliceId)).where((m) => m.notice == NoticeType.timerChanged);
    expect(notices, isNotEmpty);

    // Safety numbers agree on both sides.
    final bobDevice = (await alice.store.devicesOf(bobId)).single;
    final aliceDevice = (await bob.store.devicesOf(aliceId)).single;
    expect(bobDevice.deviceNumber, 1);
    expect(aliceDevice.deviceNumber, 1);
  });
}
