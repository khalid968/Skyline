// Phase 8b groups end to end, inside the real app build: three devices (each
// its own vault and the real libsignal core) in one admin-made group, through
// a RUNNING throwaway backend. Carol is in the group but NOT linked to Alice.
//
//   flutter test integration_test/groups_test.dart -d windows \
//     --dart-define=SKYLINE_API=http://localhost:3078 \
//     --dart-define=ALICE_ID=... --dart-define=ALICE_CODE=... \
//     --dart-define=BOB_ID=...   --dart-define=BOB_CODE=... \
//     --dart-define=CAROL_ID=... --dart-define=CAROL_CODE=... \
//     --dart-define=GROUP_ID=...
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/domain/models.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const aliceId = String.fromEnvironment('ALICE_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobId = String.fromEnvironment('BOB_ID');
const bobCode = String.fromEnvironment('BOB_CODE');
const carolId = String.fromEnvironment('CAROL_ID');
const carolCode = String.fromEnvironment('CAROL_CODE');
const groupId = String.fromEnvironment('GROUP_ID');

Future<LocalMessage> arrives(Messenger d, String id) => eventually(() => d.store.message(id));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('three devices in a group through the real server', (_) async {
    expect(groupId, isNotEmpty, reason: 'run with the fixture --dart-defines');
    final alice = await device(aliceCode, 'Alice test PC');
    final bob = await device(bobCode, 'Bob test PC');
    final carol = await device(carolCode, 'Carol test PC');
    addTearDown(() {
      alice.dispose();
      bob.dispose();
      carol.dispose();
    });
    for (final d in [alice, bob, carol]) {
      await eventually(() async => d.connection == ConnectionStatus.online ? true : null);
      await d.refreshContacts();
      await d.refreshGroups();
    }
    final g = alice.group(groupId)!;
    expect(g.name, 'Test group');
    expect(g.member(carolId)!.linked, isFalse, reason: 'carol shares the group, not a link');
    expect(alice.contacts.map((c) => c.userId), isNot(contains(carolId)));
    expect((await alice.store.chat(groupId))!.isGroup, isTrue);

    // Alice writes once; both others read it, carol without being a contact.
    final hello = await alice.sendText(groupId, 'Hello group, one ciphertext for all of you.');
    expect(hello.status, MessageStatus.sent);
    for (final d in [bob, carol]) {
      final got = await arrives(d, hello.id);
      expect(got.text, 'Hello group, one ciphertext for all of you.');
      expect(got.senderUserId, aliceId);
      expect(got.senderName, 'Alice Example');
      expect(got.peerUserId, groupId);
    }
    expect((await carol.store.chat(groupId))!.lastText, startsWith('Alice: Hello group'));
    // No direct chat with alice appeared on carol's side.
    expect(await carol.store.chat(aliceId), isNull);

    // Each member has their own sender key.
    final reply = await bob.sendText(groupId, 'Bob here.');
    expect((await arrives(alice, reply.id)).senderName, 'Bob Example');
    expect((await arrives(carol, reply.id)).text, 'Bob here.');
    final fromCarol = await carol.sendText(groupId, 'Carol here, not linked to Alice.');
    expect((await arrives(alice, fromCarol.id)).text, 'Carol here, not linked to Alice.');

    // A photo in the group: carol can fetch it (the server checks membership).
    final dir = await Directory.systemTemp.createTemp('skyline-group-');
    final photo = File('${dir.path}${Platform.pathSeparator}group.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 200, height: 150)..clear(img.ColorRgb8(20, 160, 90))));
    final sentPhoto = await alice.sendMedia(groupId, photo, MediaKind.photo, caption: 'For everyone');
    expect(sentPhoto.status, MessageStatus.sent);
    final carolPhoto = await eventually(() async {
      final m = await carol.store.message(sentPhoto.id);
      return m?.media?.state == MediaState.ready ? m : null;
    });
    expect(img.decodePng(await carol.media.bytes(carolPhoto.media!))!.getPixel(3, 3).g, closeTo(160, 2));

    // Any member may set the timer; everyone sees who did.
    await carol.setTimer(groupId, 86400);
    await eventually(() async => (await alice.store.chat(groupId))!.timerSeconds == 86400 ? true : null);
    final notice = (await alice.store.messages(groupId)).firstWhere((m) => m.notice == NoticeType.timerChanged);
    expect(notice.noticeData['name'], 'Carol Example');

    // Carol leaves. Alice's next message starts a new sender key (carol held
    // the old one) and never reaches carol.
    final before = await alice.store.setting('skOut:$groupId') as Map<String, Object?>;
    await carol.leaveGroup(groupId);
    expect((await carol.store.chat(groupId))!.left, isTrue);
    await eventually(() async {
      final ms = await alice.store.messages(groupId);
      return ms.any((m) => m.notice == NoticeType.groupEvent && m.noticeData['event'] == 'group_member_left')
          ? true
          : null;
    });
    final after = await alice.sendText(groupId, 'Only Bob and I now.');
    expect(after.status, MessageStatus.sent);
    final rotated = await alice.store.setting('skOut:$groupId') as Map<String, Object?>;
    expect(rotated['dist'], isNot(before['dist']), reason: 'a new sender key after someone left');
    expect(rotated['shared'], isNot(contains(contains(carolId))));
    expect((await arrives(bob, after.id)).text, 'Only Bob and I now.');
    await Future<void>.delayed(const Duration(seconds: 2));
    await carol.sync();
    expect(await carol.store.message(after.id), isNull, reason: 'carol is out');
  });
}
