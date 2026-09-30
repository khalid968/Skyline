import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/auth/data/activation_service.dart';
import '../../features/calls/data/call_service.dart';
import '../../features/calls/data/ringer.dart';
import '../../features/media/data/media_service.dart';
import '../../features/messages/data/local_store.dart';
import '../../features/messages/data/messenger.dart';
import '../../features/settings/data/app_lock.dart';
import '../../features/updates/data/release_service.dart';
import '../../features/updates/data/update_installer.dart';
import '../api/api_client.dart';
import '../api/session.dart';
import '../config.dart';
import '../crypto/device_crypto.dart';
import '../push/push.dart';
import '../realtime/realtime_client.dart';
import '../theme/appearance.dart';

enum AppPhase { loading, activate, ready, vaultLocked, failed }

/// Opens the device's vault, finds out whether this device is activated, and
/// owns the long-lived services. The router follows [phase].
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({SessionStore? sessions, StorageKeyStore? keys, this.vaultPath})
      : sessions = sessions ?? SecureSessionStore(),
        keys = keys ?? SecureStorageKeyStore();

  final SessionStore sessions;
  final StorageKeyStore keys;
  final String? vaultPath;
  Directory? _dataDir;

  AppPhase phase = AppPhase.loading;
  CryptoDevice? crypto;
  ApiClient? api;
  ReleaseService? releases;

  /// Board 44: exists from the start (defaults) and loads the person's
  /// choices once the vault is open.
  final appearance = Appearance();

  /// Board 43: downloads and hands over an update (one at a time).
  final installer = UpdateInstaller();
  LocalStore? store;
  Messenger? messenger;
  CallService? calls;
  ActivationService? activation;
  AppLock? lock;
  PushRegistrar? push;
  NativeRinging? ringing;

  Future<void> boot() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      final path = vaultPath ?? await _defaultVaultPath();
      _dataDir = File(path).parent;
      crypto = await openDeviceCrypto(vaultPath: path, keys: keys);
      api = ApiClient(base: AppConfig.apiBase, sessions: sessions, crypto: crypto!);
      store = LocalStore(crypto!);
      await appearance.load(store!);
      activation = ActivationService(api: api!, crypto: crypto!, sessions: sessions);
      // Board 42: needs no session, so it also works before activation.
      releases = ReleaseService(api: api!)..start();
      lock = AppLock(crypto: crypto!, store: store!);
      await lock!.load();
      final session = await sessions.read();
      if (session == null) {
        phase = AppPhase.activate;
      } else if (!await _vaultBelongsTo(session)) {
        // This vault was activated for another account (or device) before:
        // the app was revoked, then activated again on top of it. Nothing it
        // sends or receives can work, and it holds someone else's identity.
        // Retire this device on the server and start fresh (2026-09-29).
        try {
          await api!.post('/me/devices/${session.deviceId}/revoke');
        } on Object {
          // best effort: the new activation makes a new device anyway
        }
        await _eraseAndRestart();
        return;
      } else {
        await _startMessenger(session);
      }
    } on CryptoException catch (e) {
      phase = e.kind == CryptoErrorKind.vaultLocked ? AppPhase.vaultLocked : AppPhase.failed;
    } on Object {
      phase = AppPhase.failed;
    }
    notifyListeners();
  }

  /// Does this vault belong to [session]'s account and device? The vault
  /// takes its address once, for good: setting the same one again is fine, an
  /// unset one is set now, and a different one is refused.
  Future<bool> _vaultBelongsTo(Session session) async {
    try {
      await crypto!.setLocalAddress(userId: session.userId, deviceNumber: session.deviceNumber);
      return true;
    } on CryptoException {
      return false;
    }
  }

  /// Owner decision 2026-09-29: a vault serves one activation. Once this
  /// device is revoked (or the account suspended), it must be activated again
  /// as a new device, so the old vault, its messages and its keys are erased
  /// and a fresh one is made. Nothing of the previous account carries over.
  Future<void> _eraseAndRestart() async {
    phase = AppPhase.loading;
    notifyListeners();
    WidgetsBinding.instance.removeObserver(this);
    releases?.dispose();
    releases = null;
    lock?.dispose();
    lock = null;
    activation = null;
    store = null;
    api = null;
    final c = crypto;
    crypto = null;
    c?.dispose();
    try {
      await eraseDeviceVault(vaultPath: vaultPath ?? await _defaultVaultPath(), keys: keys);
    } on Object {
      phase = AppPhase.failed;
      notifyListeners();
      return;
    }
    await CallerNames.clear();
    await sessions.clear();
    await boot();
  }

  /// Called by the activation screen once the server has accepted the code.
  Future<void> activated(Session session) async {
    await _startMessenger(session);
    notifyListeners();
  }

  Future<void> _startMessenger(Session session) async {
    final m = Messenger(
      api: api!,
      crypto: crypto!,
      store: store!,
      realtime: RealtimeClient(api: api!, uri: AppConfig.socketUri),
      session: session,
      // Encrypted media next to the vault; plaintext viewing copies in the
      // OS temp folder, swept at every start.
      media: MediaService(
        api: api!,
        dir: Directory('${_dataDir!.path}${Platform.pathSeparator}media'),
        viewDir: Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}'
            '${AppConfig.tagged('skyline-view')}'),
      ),
    );
    m.addListener(_watchSignedOut);
    messenger = m;
    calls = CallService(messenger: m, api: api!);
    phase = AppPhase.ready;
    await m.start();
    // Answered on the phone's own ringing screen (Phase 14c): take the call
    // as soon as its offer is fetched and decrypted.
    ringing = NativeRinging(onAccepted: () {
      calls?.acceptWhenRinging();
      unawaited(m.sync().catchError((Object _) {}));
    });
    unawaited(ringing!.start());
    push = PushRegistrar(api: api!, messenger: m);
    unawaited(push!.start());
  }

  /// Phase 14a: on phones, the connection follows the app. In the background
  /// the socket is closed (pushes take over); back in front it reconnects at
  /// once and fetches anything new. Desktops keep their socket: they get no
  /// pushes, and a minimised window must still receive.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final m = messenger;
    if (m == null || !(Platform.isAndroid || Platform.isIOS)) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Not during a call: switching apps mid-call (a screen share) must not
      // cut the call's signalling.
      if (calls?.current != null) return;
      unawaited(m.paused());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(m.resumed());
    }
  }

  void _watchSignedOut() {
    final m = messenger;
    if (m == null || !m.signedOut) return;
    // The device was revoked or the account suspended. It can only come back
    // as a new device with a new code, and a vault serves one activation: it
    // is erased and a fresh one made (owner decision 2026-09-29).
    m.removeListener(_watchSignedOut);
    // Not here: we are inside the messenger's own notifyListeners, and a
    // ChangeNotifier must not be disposed during its notification (found in
    // use: the assertion aborted the whole sign-out). Right after it instead.
    scheduleMicrotask(() => _tearDownSignedOut(m));
  }

  void _tearDownSignedOut(Messenger m) {
    unawaited(ringing?.dispose());
    ringing = null;
    unawaited(CallerNames.clear());
    unawaited(push?.stop());
    push = null;
    calls?.dispose(); // ends any call in progress
    calls = null;
    m.dispose();
    if (messenger == m) messenger = null;
    unawaited(_eraseAndRestart());
  }

  static Future<String> _defaultVaultPath() async {
    // A build for a named server keeps its vault (and media) in a folder of
    // its own; the development build stays where it always was.
    final base = (await getApplicationSupportDirectory()).path;
    final tag = AppConfig.storageTag;
    final dir = tag.isEmpty ? base : '$base${Platform.pathSeparator}$tag';
    await Directory(dir).create(recursive: true);
    return '$dir${Platform.pathSeparator}skyline-vault.db';
  }
}

final appControllerProvider = ChangeNotifierProvider<AppController>((ref) {
  final c = AppController();
  unawaited(c.boot());
  return c;
});
