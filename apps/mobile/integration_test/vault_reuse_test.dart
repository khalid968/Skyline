// Found in use (2026-09-29): a Windows app was revoked, then activated for a
// different account on top of the same vault. The vault keeps its first
// address for good, so the new account ran on the old identity and nothing
// could be decrypted on either side. Owner decision: a vault serves one
// activation; the app erases it and starts fresh. Runs offline, with the real
// native crypto core:
//
//   flutter test integration_test/vault_reuse_test.dart -d windows
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/api/session.dart';
import 'package:skyline/core/app/app_controller.dart';
import 'package:skyline/core/crypto/device_crypto.dart';
import 'package:skyline/src/rust/frb_generated.dart';

const oldAccount = '6f0b6a1e-0000-4000-8000-0000000000a1';
const newAccount = '6f0b6a1e-0000-4000-8000-0000000000b2';

class MemoryKeyStore implements StorageKeyStore {
  Uint8List? key;
  @override
  Future<Uint8List?> read() async => key;
  @override
  Future<void> write(Uint8List k) async => key = k;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('skyline-vault-reuse'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Windows may still hold a handle for a moment
    }
  });

  test('a vault activated for another account is erased and made fresh', () async {
    final path = '${dir.path}${Platform.pathSeparator}skyline-vault.db';
    final keys = MemoryKeyStore();

    // The old account's device: its identity, bound to its address.
    final old = await openDeviceCrypto(vaultPath: path, keys: keys);
    final oldIdentity = (await old.identity()).identityKey;
    await old.setLocalAddress(userId: oldAccount, deviceNumber: 1);
    old.dispose();
    final oldKey = keys.key;

    // The same app, now holding a login for a different account.
    final sessions = MemorySessionStore()
      ..session = Session(
      userId: newAccount,
      deviceId: '6f0b6a1e-0000-4000-8000-0000000000d2',
      deviceNumber: 1,
      accessToken: 'skd_test',
      accessExpiresAt: DateTime.now().add(const Duration(minutes: 10)),
      refreshToken: 'skd_refresh',
    );
    final app = AppController(sessions: sessions, keys: keys, vaultPath: path);
    await app.boot();

    // Back to activation, with the login gone and a new storage key.
    expect(app.phase, AppPhase.activate);
    expect(await sessions.read(), isNull);
    expect(keys.key, isNot(equals(oldKey)));

    // A brand-new identity, free to take the new account's address.
    final fresh = app.crypto!;
    expect((await fresh.identity()).identityKey, isNot(equals(oldIdentity)));
    await fresh.setLocalAddress(userId: newAccount, deviceNumber: 2);
  });

  // Needs a RUNNING throwaway server that doesn't know this login (any fresh
  // e2e fixture): --dart-define=SKYLINE_API=http://localhost:3078
  test('a login the server refuses erases the vault and asks for activation', () async {
    final path = '${dir.path}${Platform.pathSeparator}skyline-vault.db';
    final keys = MemoryKeyStore();
    final d = await openDeviceCrypto(vaultPath: path, keys: keys);
    final identity = (await d.identity()).identityKey;
    await d.setLocalAddress(userId: newAccount, deviceNumber: 1);
    d.dispose();
    final sessions = MemorySessionStore()
      ..session = Session(
        userId: newAccount,
        deviceId: '6f0b6a1e-0000-4000-8000-0000000000d2',
        deviceNumber: 1,
        accessToken: 'skd_stale',
        accessExpiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        refreshToken: 'skd_unknown0000000000000000000000000000000000000',
      );
    final app = AppController(sessions: sessions, keys: keys, vaultPath: path);
    await app.boot();
    expect(app.phase, AppPhase.ready);
    // The refresh is refused: signed out, so the vault is erased.
    for (var i = 0; i < 100 && app.phase != AppPhase.activate; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(app.phase, AppPhase.activate);
    expect((await app.crypto!.identity()).identityKey, isNot(equals(identity)));
  }, skip: const String.fromEnvironment('SKYLINE_API').isEmpty ? 'needs a throwaway server' : false);

  test('a vault that belongs to the login keeps working', () async {
    final path = '${dir.path}${Platform.pathSeparator}skyline-vault.db';
    final keys = MemoryKeyStore();
    final d = await openDeviceCrypto(vaultPath: path, keys: keys);
    final identity = (await d.identity()).identityKey;
    await d.setLocalAddress(userId: newAccount, deviceNumber: 1);
    d.dispose();

    final app = AppController(
      sessions: MemorySessionStore()
        ..session = Session(
        userId: newAccount,
        deviceId: '6f0b6a1e-0000-4000-8000-0000000000d2',
        deviceNumber: 1,
        accessToken: 'skd_test',
        accessExpiresAt: DateTime.now().add(const Duration(minutes: 10)),
        refreshToken: 'skd_refresh',
      ),
      keys: keys,
      vaultPath: path,
    );
    await app.boot();
    expect(app.phase, AppPhase.ready);
    expect((await app.crypto!.identity()).identityKey, equals(identity));
  });
}
