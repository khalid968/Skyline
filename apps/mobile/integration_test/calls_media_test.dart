// Real camera video both ways between two call services on ONE Android
// emulator (its virtual camera and microphone; never run on a PC with a real
// camera). Proves that video leaves the CALLER and the ANSWERER and is decoded
// on the other side, by WebRTC's own statistics.
//   (same --dart-defines as groups_test.dart; the emulator app needs camera
//    and microphone permission granted beforehand, e.g. adb shell pm grant)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoView;
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/calls/data/call_service.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const bobId = String.fromEnvironment('BOB_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobCode = String.fromEnvironment('BOB_CODE');

int stat(String s, String key) => int.parse(RegExp('$key=' r'(\d+)').firstMatch(s)!.group(1)!);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('camera video flows from the caller and from the answerer', (tester) async {
    if (!Platform.isAndroid) return; // an emulator's virtual camera only
    final alice = await device(aliceCode, 'Alice test phone');
    final bob = await device(bobCode, 'Bob test phone');
    final a = CallService(messenger: alice, api: alice.api);
    final b = CallService(messenger: bob, api: bob.api);
    addTearDown(() {
      a.dispose();
      b.dispose();
      alice.dispose();
      bob.dispose();
    });
    for (final d in [alice, bob]) {
      await eventually(() async => d.connection == ConnectionStatus.online ? true : null);
      await d.refreshContacts();
    }

    await a.start(bobId, video: true);
    await eventually(() async => b.current?.phase == CallPhase.incoming ? true : null);
    await b.accept();
    await eventually(() async => a.current?.phase == CallPhase.connected ? true : null, within: const Duration(seconds: 30));
    await eventually(() async => b.current?.phase == CallPhase.connected ? true : null, within: const Duration(seconds: 30));
    // Both remote videos on screen, as in the app: a decoder whose output is
    // never drawn can stall, which would make the counts meaningless.
    await tester.pumpWidget(MaterialApp(
      home: Row(children: [
        Expanded(child: RTCVideoView(a.remoteRenderer)),
        Expanded(child: RTCVideoView(b.remoteRenderer)),
      ]),
    ));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    final sa = await a.debugVideoStats();
    final sb = await b.debugVideoStats();
    // ignore: avoid_print
    print('DBG caller $sa | answerer $sb');
    expect(stat(sa, 'sentBytes'), greaterThan(0), reason: 'the caller sends video');
    expect(stat(sb, 'framesDecoded'), greaterThan(0), reason: 'the answerer decodes the caller');
    expect(stat(sb, 'sentBytes'), greaterThan(0), reason: 'the answerer sends video');
    expect(stat(sa, 'framesDecoded'), greaterThan(0), reason: 'the caller decodes the answerer');
    await a.hangUp();
    await eventually(() async => a.current == null && b.current == null ? true : null);
  });
}
