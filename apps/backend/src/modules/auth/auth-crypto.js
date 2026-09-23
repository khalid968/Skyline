import crypto from 'crypto';

// Thin wrappers over Node's built-in, vetted primitives (HMAC-SHA256, Ed25519,
// AES-256-GCM, CSPRNG). Nothing here invents cryptography; it only fixes how
// Skyline uses these primitives so every caller does it the same way.

// ---------------------------------------------------------------------------
// Activation codes: SKY-XXXXX-XXXXX-XXXXX-XXXXX
// ---------------------------------------------------------------------------

// Crockford base32: no I, L, O or U, so a code read aloud or copied by hand
// cannot be confused. 20 characters x 5 bits = 100 bits of entropy.
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const CODE_CHARS = 20;

export function generateActivationCode() {
  let raw = '';
  for (let i = 0; i < CODE_CHARS; i++)
    raw += CROCKFORD[crypto.randomInt(CROCKFORD.length)];
  return `SKY-${raw.match(/.{5}/g).join('-')}`;
}

// Accepts what a person might type: any case, spaces or dashes anywhere, the
// SKY prefix present or not, and the look-alikes O->0, I/L->1. Returns the 20
// canonical characters, or null if it cannot possibly be a code.
export function normalizeActivationCode(input) {
  if (typeof input !== 'string' || input.length > 64) return null;
  let s = input.toUpperCase().replace(/[\s-]/g, '');
  if (s.length === CODE_CHARS + 3 && s.startsWith('SKY')) s = s.slice(3);
  s = s.replace(/O/g, '0').replace(/[IL]/g, '1');
  if (s.length !== CODE_CHARS) return null;
  for (const ch of s) if (!CROCKFORD.includes(ch)) return null;
  return s;
}

// ---------------------------------------------------------------------------
// Keyed hashing. Codes and tokens are stored ONLY as these hashes.
// ---------------------------------------------------------------------------

// Each kind of secret is hashed under its own label, so a value valid as one
// kind can never match a stored hash of another kind.
function keyedHash(pepper, label, value) {
  return crypto
    .createHmac('sha256', pepper)
    .update(`skyline:${label}:v1:`)
    .update(value)
    .digest();
}

export const hashActivationCode = (pepper, normalizedCode) =>
  keyedHash(pepper, 'activation', normalizedCode);

export const hashToken = (pepper, token) => keyedHash(pepper, 'token', token);

// ---------------------------------------------------------------------------
// Bearer tokens
// ---------------------------------------------------------------------------

// The prefix says which kind of session a token belongs to, so a device token
// can never be looked up as a dashboard token or the other way round.
export const TOKEN_PREFIX = {
  deviceAccess: 'skd_',
  deviceRefresh: 'skr_',
  dashboard: 'ska_',
  mfaPending: 'skm_',
};

const TOKEN_BODY = /^[A-Za-z0-9_-]{43}$/; // 32 random bytes, base64url, no padding

export function newToken(prefix) {
  return prefix + crypto.randomBytes(32).toString('base64url');
}

export function tokenKind(token) {
  if (typeof token !== 'string') return null;
  for (const [kind, prefix] of Object.entries(TOKEN_PREFIX)) {
    if (token.startsWith(prefix) && TOKEN_BODY.test(token.slice(prefix.length)))
      return kind;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Ed25519 device signatures
// ---------------------------------------------------------------------------

// What a device signs. Versioned and labelled so a signature made for one
// purpose can never be replayed for another.
export const signedMessage = {
  activation: (normalizedCode) => `skyline-activate:v1:${normalizedCode}`,
  refresh: (timestamp, refreshToken) =>
    `skyline-refresh:v1:${timestamp}:${refreshToken}`,
};

// Decodes base64 or base64url and insists on an exact length, so malformed
// input is rejected before it reaches any crypto call.
export function decodeFixed(value, bytes) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(value))
    return null;
  const buf = Buffer.from(
    value.replace(/-/g, '+').replace(/_/g, '/'),
    'base64',
  );
  return buf.length === bytes ? buf : null;
}

export function verifyEd25519(publicKeyRaw, message, signature) {
  try {
    const key = crypto.createPublicKey({
      key: {
        kty: 'OKP',
        crv: 'Ed25519',
        x: publicKeyRaw.toString('base64url'),
      },
      format: 'jwk',
    });
    return crypto.verify(null, Buffer.from(message, 'utf8'), key, signature);
  } catch {
    return false; // not a valid point, wrong length, anything: it did not verify
  }
}

// ---------------------------------------------------------------------------
// Encryption at rest for the 2FA secret (AES-256-GCM)
// ---------------------------------------------------------------------------

// Layout: 12-byte nonce | 16-byte tag | ciphertext.
export function seal(key, plaintext) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), body]);
}

export function open(key, sealed) {
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    key,
    sealed.subarray(0, 12),
  );
  decipher.setAuthTag(sealed.subarray(12, 28));
  return Buffer.concat([
    decipher.update(sealed.subarray(28)),
    decipher.final(),
  ]);
}

// Turns an operator-supplied secret string into a 32-byte key.
export const deriveKey = (secret, label) =>
  crypto
    .createHash('sha256')
    .update(`skyline:${label}:v1:`)
    .update(secret)
    .digest();

// A password someone else chooses for an operator (a new admin or moderator, or
// a reset by the owner). Shown once; the operator must replace it before doing
// anything else (admin_credentials.must_change_password). 100 bits, lower case,
// grouped so it can be read out over a phone call.
export function generateTemporaryPassword() {
  let raw = '';
  for (let i = 0; i < 20; i++)
    raw += CROCKFORD[crypto.randomInt(CROCKFORD.length)];
  return raw.toLowerCase().match(/.{5}/g).join('-');
}
