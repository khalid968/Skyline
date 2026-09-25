// Push, for real, on an Android device or emulator with Google Play: this
// device activates, registers its token with the Skyline server, and then
// waits for a genuine wake-up sent through Firebase (from the host, by the
// test runner). The wake-up must carry nothing but {"t":"inbox"}.
//
// Grant the notification permission first, or Android 13+ waits for a tap:
//   adb shell pm grant com.skyline.skyline android.permission.POST_NOTIFICATIONS
//   (after the first install), then
//   flutter test integration_test/push_test.dart -d emulator-5554 \
//     --dart-define=SKYLINE_API=http://10.0.2.2:3078 --dart-define=BOB_CODE=...
import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/api/api_client.dart';
import 'package:skyline/core/api/session.dart';
import 'package:skyline/core/config.dart';
import 'package:skyline/core/crypto/device_crypto.dart';
import 'package:skyline/core/push/push.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/auth/data/activation_service.dart';
import 'package:skyline/features/media/data/media_service.dart';
import 'package:skyline/features/messages/data/local_store.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/src/rust/frb_generated.dart';

const bobCode = String.fromEnvironment('BOB_CODE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init();
    await initPush();
  });

  testWidgets('a real Firebase wake-up reaches this device, and carries nothing', (_) async {
    expect(bobCode, isNotEmpty, reason: 'run with --dart-define=BOB_CODE');
    final crypto = await CryptoDevice.openInMemory();
    final sessions = MemorySessionStore();
    final api = ApiClient(base: AppConfig.apiBase, sessions: sessions, crypto: crypto);
    final session = await ActivationService(api: api, crypto: crypto, sessions: sessions)
        .activate(code: bobCode, deviceName: 'Push test phone');
    final messenger = Messenger(
      api: api,
      crypto: crypto,
      store: LocalStore(crypto),
      realtime: RealtimeClient(api: api, uri: AppConfig.socketUri),
      session: session,
      media: MediaService(
        api: api,
        dir: Directory('${Directory.systemTemp.path}/skyline-push-media'),
        viewDir: Directory('${Directory.systemTemp.path}/skyline-push-view'),
      ),
    );

    final got = Completer<RemoteMessage>();
    final sub = FirebaseMessaging.onMessage.listen((m) {
      if (!got.isCompleted) got.complete(m);
    });
    final registrar = PushRegistrar(api: api, messenger: messenger);
    await registrar.start();
    // ignore: avoid_print
    print('PUSH_STATUS ${registrar.lastStatus}');
    expect(registrar.lastStatus, contains('registered'));
    // The host sees the token in the database and sends a wake-up through
    // Google now.
    // ignore: avoid_print
    print('PUSH_TEST_READY ${session.deviceId}');

    final m = await got.future.timeout(const Duration(minutes: 3));
    await sub.cancel();
    expect(m.data, {'t': 'inbox'});
    expect(m.notification, isNull, reason: 'data-only: Google shows nothing');
  });
}
