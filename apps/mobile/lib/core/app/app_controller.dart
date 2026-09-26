import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/auth/data/activation_service.dart';
import '../../features/calls/data/call_service.dart';
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
class AppController extends ChangeNotifier {
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

  Future<void> boot() async {
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
    push = PushRegistrar(api: api!, messenger: m);
    unawaited(push!.start());
  }

  void _watchSignedOut() {
    final m = messenger;
    if (m == null || !m.signedOut) return;
    // The device was revoked or the account suspended. The vault stays (its
    // history is still this person's), but this device must be activated
    // again with a new code to talk to anyone.
    m.removeListener(_watchSignedOut);
    unawaited(push?.stop());
    push = null;
    calls?.dispose(); // ends any call in progress
    calls = null;
    unawaited(sessions.clear());
    m.dispose();
    messenger = null;
    phase = AppPhase.activate;
    notifyListeners();
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
