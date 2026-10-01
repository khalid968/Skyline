// Board 49 on Windows: with the window closed (hidden), Skyline keeps
// running; a message shows a notification that names only who it is from
// (or nothing at all), never its text; a muted chat stays silent; a call shows
// one too. Real devices, real vaults, a RUNNING throwaway backend. Same
// --dart-defines as calls_test.dart. Windows only.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/platform/desktop_shell.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/calls/data/call_service.dart';
import 'package:skyline/features/calls/data/ringtone.dart';
import 'package:skyline/features/settings/data/device_prefs.dart';
import 'package:skyline/src/rust/frb_generated.dart';
import 'package:window_manager/window_manager.dart';

import 'messaging_test.dart' show device, eventually;

const aliceId = String.fromEnvironment('ALICE_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobId = String.fromEnvironment('BOB_ID');
const bobCode = String.fromEnvironment('BOB_CODE');

/// No chime in the test: the audio player would outlive the test's widgets.
class _Silent extends Ringtone {
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('closed to the background, notifications still come', (tester) async {
    expect(bobCode, isNotEmpty, reason: 'run with the fixture --dart-defines');
    await DesktopShell.init();
    final prefs = DevicePrefs();
    await DesktopShell.attach(prefs);
    expect(prefs.startupApplied, isTrue);
    expect(prefs.startWithWindows, isFalse, reason: 'a development build never starts itself');

    final alice = await device(aliceCode, 'Alice test PC');
    final bob = await device(bobCode, 'Bob test PC');
    final aCalls = CallService(
        messenger: alice, api: alice.api, captureMedia: false, ringFor: const Duration(seconds: 8), ringtone: _Silent());
    final bCalls = CallService(
        messenger: bob, api: bob.api, captureMedia: false, ringFor: const Duration(seconds: 8), ringtone: _Silent());
    DesktopShell.watch(messenger: bob, calls: bCalls);
    addTearDown(() async {
      DesktopShell.unwatch();
      aCalls.dispose();
      bCalls.dispose();
      alice.dispose();
      bob.dispose();
      await windowManager.setPreventClose(false);
      await windowManager.show();
    });
    for (final d in [alice, bob]) {
      await eventually(() async => d.connection == ConnectionStatus.online ? true : null);
      await d.refreshContacts();
    }
    final aliceName = bob.contact(aliceId)!.displayName;

    // Closing the window with "keep running" on only hides it.
    expect(prefs.keepRunning, isTrue);
    await windowManager.show();
    // The runner shows the window after its first frame; close only once it
    // is up, or that late show would undo the hide.
    await eventually(() async => await windowManager.isVisible() ? true : null);
    await Future<void>.delayed(const Duration(seconds: 1));
    await windowManager.close();
    await eventually(() async => await windowManager.isVisible() ? null : true);

    // 1. Hidden: a message names its sender, never its text.
    DesktopShell.lastNotice = null;
    await alice.sendText(bobId, 'the secret plan');
    final n1 = await eventually(() async => DesktopShell.lastNotice);
    expect(n1, ('New message from $aliceName', 'chat:$aliceId'));
    expect(n1.$1.contains('secret'), isFalse);

    // 2. "Show who a message is from" off: only "New message".
    prefs.update(showSender: false);
    await Future<void>.delayed(const Duration(seconds: 6)); // past the per-chat pause
    DesktopShell.lastNotice = null;
    await alice.sendText(bobId, 'second');
    expect(await eventually(() async => DesktopShell.lastNotice), ('New message', 'chat:$aliceId'));
    prefs.update(showSender: true);

    // 3. A muted chat stays silent.
    await bob.setMuted(aliceId, true);
    await Future<void>.delayed(const Duration(seconds: 6));
    DesktopShell.lastNotice = null;
    final quiet = await alice.sendText(bobId, 'muted');
    await eventually(() async => await bob.store.message(quiet.id));
    expect(DesktopShell.lastNotice, isNull);
    await bob.setMuted(aliceId, false);

    // 4. A call while hidden: a notification with the caller's name.
    DesktopShell.lastNotice = null;
    await aCalls.start(bobId, video: false);
    final call = await eventually(() async => bCalls.current);
    final n4 = await eventually(() async => DesktopShell.lastNotice);
    expect(n4, (aliceName, 'call:open:${call.id}'));
    await bCalls.decline();
    await eventually(() async => aCalls.current == null && bCalls.current == null ? true : null);

    // 5. In front: no notifications.
    await DesktopShell.showWindow();
    await eventually(() async => await windowManager.isVisible() ? true : null);
    await Future<void>.delayed(const Duration(seconds: 6));
    DesktopShell.lastNotice = null;
    final seen = await alice.sendText(bobId, 'while looking');
    await eventually(() async => await bob.store.message(seen.id));
    if (await windowManager.isFocused()) expect(DesktopShell.lastNotice, isNull);
  });
}
