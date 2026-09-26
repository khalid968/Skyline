// Cross-device call, caller half: run on the ANDROID EMULATOR (its virtual
// camera) at the same time as cross_callee_test.dart on Windows, against the
// same throwaway server. Alice calls Bob with video and holds the call.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/calls/data/call_service.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const bobId = String.fromEnvironment('BOB_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('Alice calls Bob with her camera on', (_) async {
    if (!Platform.isAndroid) return;
    final alice = await device(aliceCode, 'Alice emulator');
    final a = CallService(messenger: alice, api: alice.api);
    await eventually(() async => alice.connection == ConnectionStatus.online ? true : null);
    await alice.refreshContacts();
    // Bob's Windows device is online first (the runner starts it earlier).
    await a.start(bobId, video: true);
    await eventually(() async => a.current?.phase == CallPhase.connected ? true : null, within: const Duration(seconds: 60))
        .catchError((Object _) => false);
    await Future<void>.delayed(const Duration(seconds: 20));
    // ignore: avoid_print
    print('DBG caller phase=${a.current?.phase} ${await a.debugVideoStats()}');
    // ignore: avoid_print
    print('DBG caller ice ${await a.debugIce()}');
    await a.hangUp();
    await Future<void>.delayed(const Duration(seconds: 3));
    a.dispose();
    alice.dispose();
  });
}
