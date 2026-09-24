// The crypto core running inside the real app build (Windows / Android): the
// native library built by cargokit from crypto-core/ffi, called from Dart.
//
//   flutter test integration_test/crypto_test.dart -d windows
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/crypto/device_crypto.dart';
import 'package:skyline/src/rust/frb_generated.dart';

const alice = '6f0b6a1e-0000-4000-8000-00000000000a';
const bob = '6f0b6a1e-0000-4000-8000-00000000000b';

class MemoryKeyStore implements StorageKeyStore {
  Uint8List? key;
  @override
  Future<Uint8List?> read() async => key;
  @override
  Future<void> write(Uint8List k) async => key = k;
}

Future<PreKeyBundle> publish(CryptoDevice d, int deviceNumber) async {
  final id = await d.identity();
  final oneTime = await d.newOneTimePreKeys(count: 1);
  final kyber = await d.newKyberPreKeys(count: 1);
  return PreKeyBundle(
    registrationId: id.registrationId,
    deviceNumber: deviceNumber,
    identityKey: id.identityKey,
    signedPreKey: await d.newSignedPreKey(),
    kyberPreKey: kyber.single,
    preKey: oneTime.single,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('two devices talk through the native crypto core', (_) async {
    final a = await CryptoDevice.openInMemory();
    final b = await CryptoDevice.openInMemory();
    await a.setLocalAddress(userId: alice, deviceNumber: 1);
    await b.setLocalAddress(userId: bob, deviceNumber: 1);

    await a.startSession(userId: bob, bundle: await publish(b, 1));
    final first = await a.encrypt(
      userId: bob,
      deviceNumber: 1,
      plaintext: utf8.encode('hello from Dart'),
    );
    expect(first.kind, EnvelopeKind.preKey);
    final read = await b.decrypt(userId: alice, deviceNumber: 1, envelope: first);
    expect(utf8.decode(read), 'hello from Dart');

    final reply = await b.encrypt(
      userId: alice,
      deviceNumber: 1,
      plaintext: utf8.encode('hi'),
    );
    expect(utf8.decode(await a.decrypt(userId: bob, deviceNumber: 1, envelope: reply)), 'hi');

    final sa = await a.safetyNumber(
      theirUserId: bob,
      theirDeviceNumber: 1,
      theirIdentityKey: (await b.identity()).identityKey,
    );
    final sb = await b.safetyNumber(
      theirUserId: alice,
      theirDeviceNumber: 1,
      theirIdentityKey: (await a.identity()).identityKey,
    );
    expect(sa.displayable, sb.displayable);
  });

  testWidgets('errors arrive in Dart as typed CryptoExceptions', (_) async {
    final a = await CryptoDevice.openInMemory();
    await expectLater(
      a.encrypt(userId: bob, deviceNumber: 1, plaintext: [1]),
      throwsA(isA<CryptoException>().having((e) => e.kind, 'kind', CryptoErrorKind.noLocalAddress)),
    );
  });

  testWidgets('the vault survives restarts with its keystore key, and nothing opens it without', (_) async {
    final dir = await Directory.systemTemp.createTemp('skyline-vault-test');
    final path = '${dir.path}${Platform.pathSeparator}vault.db';
    final keys = MemoryKeyStore();
    try {
      final first = await openDeviceCrypto(vaultPath: path, keys: keys);
      expect(keys.key, hasLength(32), reason: 'a key is created on first run');
      final identity = (await first.identity()).identityKey;
      first.dispose();

      final again = await openDeviceCrypto(vaultPath: path, keys: keys);
      expect((await again.identity()).identityKey, identity);
      again.dispose();

      // The keystore lost its key (reset phone, cleared credentials): the old
      // vault must refuse to open, never be silently replaced.
      await expectLater(
        openDeviceCrypto(vaultPath: path, keys: MemoryKeyStore()),
        throwsA(isA<CryptoException>().having((e) => e.kind, 'kind', CryptoErrorKind.vaultLocked)),
      );
    } finally {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may hold the SQLite file briefly; a temp dir is fine to leave.
      }
    }
  });
}
