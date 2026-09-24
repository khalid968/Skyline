import 'dart:convert';

import '../../../core/api/api_client.dart';
import '../../../core/crypto/device_crypto.dart';

/// Publishes whatever of this device's prekeys the key directory is missing:
/// everything on first activation, then top-ups when one-time keys run low.
///
/// Uploads go in small batches. A Kyber public key is about 1.6 KB (2.1 KB as
/// base64) and the server accepts 100 KB per request, so 50 of them in one
/// upload is refused (413). Safe to call repeatedly: a device whose upload
/// failed is repaired on its next sync.
Future<void> publishPreKeys(ApiClient api, CryptoDevice crypto) async {
  const low = 20;
  const target = 50;
  const kyberBatch = 20;

  final counts = await api.get('/me/keys') as Map<String, Object?>;

  final base = <String, Object?>{};
  if (counts['signedPreKey'] == null) {
    base['signedPreKey'] = _signed(await crypto.newSignedPreKey());
  }
  if (counts['lastResortKyberPreKeyId'] == null) {
    base['lastResortKyberPreKey'] = _signed(await crypto.newLastResortKyberPreKey());
  }
  final ec = counts['oneTimePreKeys']! as int;
  if (ec < low) {
    base['oneTimePreKeys'] = [
      for (final k in await crypto.newOneTimePreKeys(count: target - ec))
        {'keyId': k.keyId, 'publicKey': base64.encode(k.publicKey)},
    ];
  }
  if (base.isNotEmpty) await api.put('/me/keys', base);

  var kyber = counts['kyberPreKeys']! as int;
  if (kyber < low) {
    while (kyber < target) {
      final n = (target - kyber).clamp(1, kyberBatch);
      await api.put('/me/keys', {
        'kyberPreKeys': [for (final k in await crypto.newKyberPreKeys(count: n)) _signed(k)],
      });
      kyber += n;
    }
  }
}

Map<String, Object?> _signed(SignedPreKey k) => {
      'keyId': k.keyId,
      'publicKey': base64.encode(k.publicKey),
      'signature': base64.encode(k.signature),
    };
