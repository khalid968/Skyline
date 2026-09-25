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
    final photoBytes = img.encodePng(img.Image(width: 640, height: 480)..clear(img.ColorRgb8(58, 99, 216)));
    final photoFile = File('${dir.path}${Platform.pathSeparator}site-north.png')..writeAsBytesSync(photoBytes);
    final photo = await alice.sendMedia(bobId, photoFile, MediaKind.photo, caption: 'North elevation, today');
    expect(photo.status, MessageStatus.sent);
    expect(photo.media!.state, MediaState.ready);
    expect(photo.media!.thumb, isNotNull);
    final gotPhoto = await eventually(() async {
      final m = await bob.store.message(photo.id);
      return m?.media?.state == MediaState.ready ? m : null;
    });
    expect(gotPhoto.text, 'North elevation, today');
    expect(await bob.media.bytes(gotPhoto.media!), photoBytes);
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
