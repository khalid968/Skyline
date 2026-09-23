// A stand-in for a phone's keys in backend tests: an Ed25519 signing key (the
// device credential) and a Signal-style identity (a Curve25519 PUBLIC key in
// libsignal's serialized form, 0x05 then 32 bytes, plus a registration id).
//
// Only the public identity key matters to the server, so Node's X25519 is
// enough here. Real Signal keys come from libsignal on the device (Phase 7);
// crypto-core's own tests cover those.
import crypto from 'crypto';
import {
  normalizeActivationCode,
  signedMessage,
} from '../../src/modules/auth/auth-crypto';

export function newIdentityKey() {
  const { publicKey } = crypto.generateKeyPairSync('x25519');
  const raw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
  return Buffer.concat([Buffer.from([5]), raw]).toString('base64');
}

export function newDeviceKey() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  return {
    publicKey: Buffer.from(
      publicKey.export({ format: 'jwk' }).x,
      'base64url',
    ).toString('base64'),
    sign: (message) =>
      crypto
        .sign(null, Buffer.from(message, 'utf8'), privateKey)
        .toString('base64'),
    identityKey: newIdentityKey(),
    registrationId: 1 + crypto.randomInt(16383),
  };
}

// The signing, identity and signature fields of an activation request.
// `signedCode` lets a test sign something other than the code it sends.
export function activationFields(code, key, signedCode) {
  const normalized =
    signedCode ?? (normalizeActivationCode(code) || String(code));
  return {
    signingKey: key.publicKey,
    identityKey: key.identityKey,
    registrationId: key.registrationId,
    signature: key.sign(
      signedMessage.activation(
        normalized,
        key.identityKey,
        key.registrationId,
      ),
    ),
  };
}
