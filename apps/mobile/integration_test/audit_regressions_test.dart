// Security audit 2026-10-31, kept as regression tests: a modified client
// (played here with the fixture's throwaway accounts) tries what the audit
// found possible, against the real app code and a RUNNING throwaway backend.
// Same --dart-defines as groups_test.dart.
//   - a group-mate who is NOT a contact (carol -> alice) cannot write to us
//     directly by hiding a message in a group key share
//   - a timer message cannot reuse an existing message id to replace it
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/crypto/device_crypto.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/domain/models.dart';
import 'package:skyline/src/rust/frb_generated.dart';
import 'package:uuid/uuid.dart';

import 'groups_test.dart' show aliceCode, aliceId, arrives, bobCode, bobId, carolCode, carolId, groupId;
import 'messaging_test.dart' show device, eventually;

const _uuid = Uuid();

/// [content] encrypted pairwise from [from] to each of [to]'s [devices], as
/// the envelopes the server takes.
Future<List<Map<String, Object?>>> seal(Messenger from, String to, List<int> devices, Map<String, Object?> content) async {
  final bytes = utf8.encode(jsonEncode(content));
  return [
    for (final n in devices)
      await from.crypto.encrypt(userId: to, deviceNumber: n, plaintext: bytes).then((e) => {
            'userId': to,
            'deviceNumber': n,
            'kind': e.kind == EnvelopeKind.preKey ? 'prekey' : 'whisper',
            'body': base64.encode(e.body),
          }),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('what a modified client tried in the audit stays refused', (_) async {
    expect(groupId, isNotEmpty, reason: 'run with the fixture --dart-defines');
    final alice = await device(aliceCode, 'Alice test');
    final bob = await device(bobCode, 'Bob test');
    final carol = await device(carolCode, 'Carol test');
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
    expect(alice.contacts.map((c) => c.userId), isNot(contains(carolId)));

    // ---- A direct message hidden in a group key share.
    // A normal group message first: carol now has a pairwise session with alice.
    final hi = await carol.sendText(groupId, 'Carol in the group.');
    expect((await arrives(alice, hi.id)).text, 'Carol in the group.');
    final aliceDevices = [for (final d in carol.group(groupId)!.member(aliceId)!.devices) d.deviceNumber];
    final hidden = _uuid.v4();
    await carol.api.post('/groups/$groupId/key-shares', {
      'messageId': _uuid.v4(),
      'envelopes': await seal(carol, aliceId, aliceDevices, {
        'v': 1,
        'type': 'text',
        'id': hidden,
        'peer': aliceId,
        'body': 'a direct message from someone who is not a contact',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      }),
    });
    // The group keeps working afterwards: a later message still arrives.
    final after = await carol.sendText(groupId, 'Still in the group.');
    expect((await arrives(alice, after.id)).peerUserId, groupId);
    await alice.sync();
    expect(await alice.store.message(hidden), isNull, reason: 'non-skey content in a key share is dropped');
    expect(await alice.store.chat(carolId), isNull, reason: 'no direct chat with a non-contact');

    // ---- A timer message reusing one of bob's own message ids.
    final mine = await bob.sendText(aliceId, 'Bob wrote this one.');
    await arrives(alice, mine.id);
    final bobDevices = [for (final d in alice.contacts.firstWhere((c) => c.userId == bobId).devices) d.deviceNumber];
    final timerId = _uuid.v4();
    await alice.api.post('/users/$bobId/messages', {
      'messageId': timerId,
      'envelopes': await seal(alice, bobId, bobDevices, {
        'v': 1,
        'type': 'timer',
        'id': mine.id,
        'peer': bobId,
        'seconds': 3600,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      }),
    });
    // Then a genuine timer change, so we know the first one was processed.
    await alice.setTimer(bobId, 86400);
    await eventually(() async => (await bob.store.chat(aliceId))!.timerSeconds == 86400 ? true : null);
    final kept = (await bob.store.message(mine.id))!;
    expect(kept.kind, MessageKind.text, reason: 'the existing message is not replaced');
    expect(kept.fromMe, isTrue);
    expect(kept.text, 'Bob wrote this one.');
  });
}
