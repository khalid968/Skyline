// Phase 10 end to end: a one-to-one call between two real devices through a
// RUNNING throwaway backend and the coturn relay (docker compose). Setup goes
// as Signal-encrypted messages; the connection must be relayed (never
// direct); the call's own data channel carries data both ways; the chats get
// their call lines (board 35). No camera or microphone: captureMedia is off.
// Same --dart-defines as groups_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show TransceiverDirection;
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/calls/data/call_service.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/domain/models.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const aliceId = String.fromEnvironment('ALICE_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobId = String.fromEnvironment('BOB_ID');
const bobCode = String.fromEnvironment('BOB_CODE');

/// The chat's call lines, oldest first (the store lists newest first).
Future<List<Map<String, Object?>>> callLines(Messenger m, String peer) async {
  final calls = [for (final x in await m.store.messages(peer)) if (x.notice == NoticeType.call) x]
    ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
  return [for (final x in calls) x.noticeData];
}

Future<void> idle(CallService c) => eventually(() async => c.current == null ? true : null);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('a relayed, end-to-end encrypted call', (_) async {
    expect(bobCode, isNotEmpty, reason: 'run with the fixture --dart-defines');
    final alice = await device(aliceCode, 'Alice test PC');
    final bob = await device(bobCode, 'Bob test PC');
    const ring = Duration(seconds: 6);
    final aCalls = CallService(messenger: alice, api: alice.api, captureMedia: false, ringFor: ring);
    final bCalls = CallService(messenger: bob, api: bob.api, captureMedia: false, ringFor: ring);
    addTearDown(() {
      aCalls.dispose();
      bCalls.dispose();
      alice.dispose();
      bob.dispose();
    });
    for (final d in [alice, bob]) {
      await eventually(() async => d.connection == ConnectionStatus.online ? true : null);
      await d.refreshContacts();
    }

    // 1. Alice calls, Bob's device rings, Bob answers.
    await aCalls.start(bobId, video: false);
    expect(aCalls.current?.phase, CallPhase.outgoing);
    // ignore: avoid_print

    final ringing = await eventually(() async => bCalls.current);
    expect(ringing.phase, CallPhase.incoming);
    expect(ringing.peer, aliceId);
    expect(ringing.outgoing, isFalse);
    await bCalls.accept();

    // Both ends connect, and only through the relay.
    await eventually(() async => aCalls.current?.phase == CallPhase.connected ? true : null);
    await eventually(() async => bCalls.current?.phase == CallPhase.connected ? true : null);
    await eventually(() async => aCalls.lastCandidateType != null ? true : null);
    expect(aCalls.lastCandidateType, 'relay');
    await eventually(() async => bCalls.lastCandidateType != null ? true : null);
    expect(bCalls.lastCandidateType, 'relay');

    // Video can flow both ways: the answerer took over the offer's video
    // channel (a camera or a screen share only swaps the track in).
    expect(await aCalls.videoDirection(), TransceiverDirection.SendRecv);
    expect(await bCalls.videoDirection(), TransceiverDirection.SendRecv);
    // The call's own encrypted channel works both ways.
    await eventually(() async {
      await aCalls.sendProbe('from alice');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return bCalls.lastProbe == 'from alice' ? true : null;
    });
    await bCalls.sendProbe('from bob');
    await eventually(() async => aCalls.lastProbe == 'from bob' ? true : null);

    // Alice hangs up; both ends stop, and both chats say "Voice call".
    await Future<void>.delayed(const Duration(seconds: 1));
    await aCalls.hangUp();
    await idle(aCalls);
    await idle(bCalls);
    final aLine = (await callLines(alice, bobId)).single;
    expect(aLine['outcome'], 'completed');
    expect(aLine['outgoing'], isTrue);
    expect(aLine['seconds'] as int, greaterThanOrEqualTo(1));
    final bLine = (await callLines(bob, aliceId)).single;
    expect(bLine['outcome'], 'completed');
    expect(bLine['outgoing'], isFalse);

    // 2. Bob declines a video call: "Declined" for Alice.
    await aCalls.start(bobId, video: true);
    await eventually(() async => bCalls.current?.phase == CallPhase.incoming ? true : null);
    expect(bCalls.current!.video, isTrue);
    await bCalls.decline();
    await idle(aCalls);
    await idle(bCalls);
    expect((await callLines(alice, bobId)).last['outcome'], 'declined');
    expect((await callLines(alice, bobId)).last['video'], isTrue);

    // 3. Nobody answers: "No answer" for Alice, a missed call for Bob,
    //    which counts as unread.
    await bob.markRead(aliceId);
    await aCalls.start(bobId, video: false);
    await eventually(() async => bCalls.current?.phase == CallPhase.incoming ? true : null);
    await idle(aCalls);
    await idle(bCalls);
    expect((await callLines(alice, bobId)).last['outcome'], 'noAnswer');
    expect((await callLines(bob, aliceId)).last['outcome'], 'missed');
    expect((await bob.store.chat(aliceId))!.unread, greaterThan(0));
    expect((await bob.store.chat(aliceId))!.lastText, 'Missed voice call');

    // 4. Alice gives up before Bob answers: Bob's phone stops ringing.
    await aCalls.start(bobId, video: false);
    await eventually(() async => bCalls.current?.phase == CallPhase.incoming ? true : null);
    await aCalls.hangUp();
    await idle(bCalls);
    expect((await callLines(bob, aliceId)).last['outcome'], 'missed');

    // 5. The caller's clock is five minutes behind (an emulator after the
    //    laptop slept): the call still rings, because freshness is judged by
    //    how long the server held the offer, not by the caller's clock.
    await alice.sendCallSignal(bobId, {
      'callId': 'skewed-clock-call',
      'action': 'offer',
      'sdp': 'v=0',
      'video': false,
      'sentAt': DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
    });
    final skewed = await eventually(() async => bCalls.current);
    expect(skewed.id, 'skewed-clock-call');
    expect(skewed.phase, CallPhase.incoming);
    await bCalls.decline();
    await idle(bCalls);
  });
}
