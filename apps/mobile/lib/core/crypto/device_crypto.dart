import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../../src/rust/api/crypto.dart';

export '../../src/rust/api/crypto.dart'
    show
        CryptoDevice,
        CryptoException,
        CryptoErrorKind,
        DeviceIdentity,
        Envelope,
        EnvelopeKind,
        OneTimePreKey,
        PreKeyBundle,
        SafetyNumber,
        SignedPreKey;

/// Where the vault's storage key lives. In the app: the OS keystore (iOS
/// Keychain, Android Keystore-backed storage, Windows Credential Manager with
/// DPAPI). Tests substitute an in-memory one.
abstract class StorageKeyStore {
  Future<Uint8List?> read();
  Future<void> write(Uint8List key);
}

class SecureStorageKeyStore implements StorageKeyStore {
  SecureStorageKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              // Only while this device is unlocked, and never synced or backed
              // up to another device: the vault is bound to this device.
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  static const _name = 'skyline.vault.storage-key.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read() async {
    final hex = await _storage.read(key: _name);
    return hex == null ? null : _fromHex(hex);
  }

  @override
  Future<void> write(Uint8List key) =>
      _storage.write(key: _name, value: _toHex(key));
}

/// Opens this device's crypto vault, creating it (and its storage key) on first
/// run. The key is 32 bytes from the platform CSPRNG, stored ONLY in the
/// keystore; the vault file holds nothing readable without it.
///
/// If the keystore lost its key but the vault file survives, the vault cannot
/// be opened ([CryptoErrorKind.vaultLocked]) and is never overwritten: the
/// device needs a new activation code, like a new phone.
Future<CryptoDevice> openDeviceCrypto({
  required String vaultPath,
  required StorageKeyStore keys,
}) async {
  var key = await keys.read();
  if (key == null) {
    key = _randomKey();
    await keys.write(key);
  }
  return CryptoDevice.open(path: vaultPath, storageKey: key);
}

/// The device's crypto, opened once per app run. Everything that encrypts,
/// decrypts or signs goes through this.
final deviceCryptoProvider = FutureProvider<CryptoDevice>((ref) async {
  final dir = await getApplicationSupportDirectory();
  await Directory(dir.path).create(recursive: true);
  return openDeviceCrypto(
    vaultPath: '${dir.path}${Platform.pathSeparator}skyline-vault.db',
    keys: SecureStorageKeyStore(),
  );
});

Uint8List _randomKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
}

String _toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
