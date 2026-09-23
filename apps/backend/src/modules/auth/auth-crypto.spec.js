import crypto from 'crypto';
import {
  generateActivationCode,
  normalizeActivationCode,
  hashActivationCode,
  hashToken,
  newToken,
  tokenKind,
  TOKEN_PREFIX,
  decodeFixed,
  verifyEd25519,
  signedMessage,
  seal,
  open,
  deriveKey,
} from './auth-crypto';

const pepper = Buffer.from('test-pepper-test-pepper-test-pepper');

describe('activation codes', () => {
  it('have the SKY-XXXXX-XXXXX-XXXXX-XXXXX shape in the Crockford alphabet', () => {
    for (let i = 0; i < 200; i++) {
      expect(generateActivationCode()).toMatch(
        /^SKY(-[0-9ABCDEFGHJKMNPQRSTVWXYZ]{5}){4}$/,
      );
    }
  });

  it('do not repeat', () => {
    const seen = new Set(Array.from({ length: 2000 }, generateActivationCode));
    expect(seen.size).toBe(2000);
  });

  it('normalise the ways a person might type one', () => {
    const code = 'SKY-4F2A0-99XD1-7C1BK-M3PQR';
    const canonical = '4F2A099XD17C1BKM3PQR';
    for (const typed of [
      code,
      code.toLowerCase(),
      '4F2A0-99XD1-7C1BK-M3PQR',
      ' sky 4f2a0 99xd1 7c1bk m3pqr ',
      'SKY-4F2AO-99XDI-7CLBK-M3PQR', // O for 0, I and L for 1
    ]) {
      expect(normalizeActivationCode(typed)).toBe(canonical);
    }
  });

  it.each([
    ['too short', 'SKY-4F2A0-99XD1'],
    ['too long', 'SKY-4F2A0-99XD1-7C1BK-M3PQR-X'],
    ['a character outside the alphabet', 'SKY-4F2A0-99XD1-7C1BK-M3PQU'],
    ['punctuation', 'SKY-4F2A0-99XD1-7C1BK-M3PQ!'],
    ['not a string', 12345],
    ['absurdly long', 'A'.repeat(1000)],
  ])('reject %s', (_label, input) => {
    expect(normalizeActivationCode(input)).toBeNull();
  });

  it('hash identically however they were typed, and differently under another pepper', () => {
    const a = hashActivationCode(
      pepper,
      normalizeActivationCode('SKY-4F2A0-99XD1-7C1BK-M3PQR'),
    );
    const b = hashActivationCode(
      pepper,
      normalizeActivationCode('sky-4f2ao-99xdi-7clbk-m3pqr'),
    );
    expect(a.equals(b)).toBe(true);
    expect(a).toHaveLength(32);
    const other = hashActivationCode(
      Buffer.from('another-pepper-entirely-different'),
      '4F2A099XD17C1BKM3PQR',
    );
    expect(a.equals(other)).toBe(false);
  });

  it('never hash the same as a token with the same text (domain separation)', () => {
    expect(hashActivationCode(pepper, 'X').equals(hashToken(pepper, 'X'))).toBe(
      false,
    );
  });
});

describe('tokens', () => {
  it.each(Object.entries(TOKEN_PREFIX))(
    '%s tokens are recognised by their prefix',
    (kind, prefix) => {
      const t = newToken(prefix);
      expect(t.startsWith(prefix)).toBe(true);
      expect(tokenKind(t)).toBe(kind);
    },
  );

  it('reject anything that is not exactly a well-formed token', () => {
    const good = newToken(TOKEN_PREFIX.deviceAccess);
    for (const bad of [
      good.slice(0, -1),
      `${good}x`,
      `xx_${good.slice(4)}`,
      '',
      null,
      'skd_',
      `${good} `,
    ]) {
      expect(tokenKind(bad)).toBeNull();
    }
  });
});

describe('Ed25519', () => {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const raw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
  const sign = (msg, key = privateKey) =>
    crypto.sign(null, Buffer.from(msg), key);

  it('accepts a genuine signature', () => {
    const m = signedMessage.activation('ABC');
    expect(verifyEd25519(raw, m, sign(m))).toBe(true);
  });

  it('rejects a signature over a different message', () => {
    expect(
      verifyEd25519(
        raw,
        signedMessage.activation('ABC'),
        sign(signedMessage.activation('ABD')),
      ),
    ).toBe(false);
  });

  it('an activation signature covers the Signal identity, not just the code', () => {
    const signed = sign(signedMessage.activation('ABC', 'BQidentityA', 42));
    expect(
      verifyEd25519(raw, signedMessage.activation('ABC', 'BQidentityB', 42), signed),
    ).toBe(false);
    expect(
      verifyEd25519(raw, signedMessage.activation('ABC', 'BQidentityA', 43), signed),
    ).toBe(false);
  });

  it('rejects a signature for another purpose, even over the same text', () => {
    const forActivation = sign(signedMessage.activation('X'));
    expect(
      verifyEd25519(raw, signedMessage.refresh('X', ''), forActivation),
    ).toBe(false);
  });

  it("rejects someone else's key", () => {
    const other = crypto.generateKeyPairSync('ed25519').privateKey;
    const m = signedMessage.activation('ABC');
    expect(verifyEd25519(raw, m, sign(m, other))).toBe(false);
  });

  it('returns false rather than throwing on garbage', () => {
    expect(verifyEd25519(Buffer.alloc(32), 'm', Buffer.alloc(64))).toBe(false);
    expect(verifyEd25519(Buffer.alloc(5), 'm', Buffer.alloc(3))).toBe(false);
  });

  it('decodes base64 and base64url to an exact length only', () => {
    const b = crypto.randomBytes(32);
    expect(decodeFixed(b.toString('base64'), 32).equals(b)).toBe(true);
    expect(decodeFixed(b.toString('base64url'), 32).equals(b)).toBe(true);
    expect(decodeFixed(b.toString('base64'), 64)).toBeNull();
    expect(decodeFixed('not base64 !!', 32)).toBeNull();
    expect(decodeFixed(undefined, 32)).toBeNull();
  });
});

describe('sealing the 2FA secret', () => {
  const key = deriveKey('some-operator-secret', 'totp');

  it('round-trips', () => {
    expect(
      open(key, seal(key, Buffer.from('JBSWY3DPEHPK3PXP'))).toString(),
    ).toBe('JBSWY3DPEHPK3PXP');
  });

  it('produces different ciphertext every time', () => {
    expect(
      seal(key, Buffer.from('same')).equals(seal(key, Buffer.from('same'))),
    ).toBe(false);
  });

  it('refuses to open with the wrong key or after tampering', () => {
    const sealed = seal(key, Buffer.from('secret'));
    expect(() => open(deriveKey('another', 'totp'), sealed)).toThrow();
    const tampered = Buffer.from(sealed);
    tampered[tampered.length - 1] ^= 1;
    expect(() => open(key, tampered)).toThrow();
  });
});
