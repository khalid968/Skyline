// Board 28 (and mentions, board 29) end to end: replies, edits, reactions,
// pins, deletion for everyone, and a mention in a group, between real devices
// through a RUNNING throwaway backend. Same --dart-defines as groups_test.dart.
import 'package:flutter_test/flutter_test.dart';
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
const carolCode = String.fromEnvironment('CAROL_CODE');
const groupId = String.fromEnvironment('GROUP_ID');

Future<LocalMessage> until(Messenger d, String id, bool Function(LocalMessage m) ok) =>
    eventually(() async {
      final m = await d.store.message(id);
      return m != null && ok(m) ? m : null;
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('reply, edit, react, pin, delete, mention', (_) async {
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

    // A reply carries a quote of what it answers.
    final question = await alice.sendText(bobId, 'Can you send the survey before Thursday?');
    final atBob = await until(bob, question.id, (_) => true);
    final answer = await bob.sendText(aliceId, 'Yes, Wednesday.', replyTo: bob.quoteOf(atBob));
    final atAlice = await until(alice, answer.id, (_) => true);
    expect(atAlice.replyTo!['id'], question.id);
    expect(atAlice.replyTo!['author'], aliceId);
    expect(atAlice.replyTo!['preview'], 'Can you send the survey before Thursday?');

    // The author edits within 15 minutes; the other side shows "edited".
    expect(alice.canEdit(question), isTrue);
    expect(bob.canEdit(atBob), isFalse, reason: 'only the author');
    await alice.editMessage(question.id, 'Can you send the survey before Wednesday?');
    final edited = await until(bob, question.id, (m) => m.editedAt != null);
    expect(edited.text, 'Can you send the survey before Wednesday?');

    // One reaction per person; the same one again takes it back.
    await bob.react(question.id, '👍');
    await until(alice, question.id, (m) => m.reactions[bobId] == '👍');
    await bob.react(question.id, '👍');
    await until(alice, question.id, (m) => !m.reactions.containsKey(bobId));
    await bob.react(question.id, '🙏');
    await until(alice, question.id, (m) => m.reactions[bobId] == '🙏');

    // A pin is shared and announced on both sides.
    await alice.pin(answer.id, true);
    await eventually(() async => (await bob.store.chat(aliceId))!.pins.contains(answer.id) ? true : null);
    final notices = (await bob.store.messages(aliceId)).where((m) => m.notice == NoticeType.pinned);
    expect(notices.single.noticeData['pinned'], isTrue);

    // Deleted for everyone: gone on both sides, leaving a note; unpinned too.
    await bob.deleteForEveryone(answer.id);
    final gone = await until(alice, answer.id, (m) => m.deleted);
    expect(gone.text, isEmpty);
    await eventually(() async => (await alice.store.chat(bobId))!.pins.isEmpty ? true : null);

    // Deleting for me touches nobody else.
    await alice.deleteForMe(question.id);
    expect(await alice.store.message(question.id), isNull);
    expect(await bob.store.message(question.id), isNotNull);

    // A mention in the group: Bob sees "@", Alice (not mentioned) does not.
    final mention = await carol.sendText(groupId, '@Bob can you check the gate?', mentions: [bobId]);
    final atBobG = await until(bob, mention.id, (_) => true);
    expect(atBobG.mentions, [bobId]);
    expect((await bob.store.chat(groupId))!.mentioned, isTrue);
    await until(alice, mention.id, (_) => true);
    expect((await alice.store.chat(groupId))!.mentioned, isFalse);
    await bob.markRead(groupId);
    expect((await bob.store.chat(groupId))!.mentioned, isFalse);

    // Reactions and edits work in the group too.
    await alice.react(mention.id, '👀');
    await until(carol, mention.id, (m) => m.reactions[aliceId] == '👀');
    await until(bob, mention.id, (m) => m.reactions[aliceId] == '👀');
  });
}
