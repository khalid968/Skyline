// Cross-device call, answering half: run on WINDOWS at the same time as
// cross_caller_test.dart on the Android emulator. Bob (no camera, no
// microphone) answers, shows Alice's video on screen, and checks that it is
// received AND decoded, the way the app shows it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoView;
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/calls/data/call_service.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const bobCode = String.fromEnvironment('BOB_CODE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets("Bob sees Alice's camera", (tester) async {
    if (!Platform.isWindows) return;
    late CallService b;
    await tester.runAsync(() async {
      final bob = await device(bobCode, 'Bob Windows');
      b = CallService(messenger: bob, api: bob.api, captureMedia: false);
      await eventually(() async => bob.connection == ConnectionStatus.online ? true : null);
      await bob.refreshContacts();
      await eventually(() async => b.current?.phase == CallPhase.incoming ? true : null, within: const Duration(minutes: 8));
      await b.accept();
      await eventually(() async => b.current?.phase == CallPhase.connected ? true : null, within: const Duration(seconds: 30));
    });
    await tester.pumpWidget(MaterialApp(home: RTCVideoView(b.remoteRenderer)));
    for (var i = 0; i < 150; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    final stats = await tester.runAsync(() => b.debugVideoStats());
    // ignore: avoid_print
    print('DBG callee $stats');
    // ignore: avoid_print
    print('DBG callee ice ${await tester.runAsync(() => b.debugIce())}');
    expect(int.parse(RegExp(r'framesDecoded=(\d+)').firstMatch(stats!)!.group(1)!), greaterThan(0));
    expect(b.remoteRenderer.videoWidth, greaterThan(0), reason: 'a picture reached the screen');
  });
}
