// Removes anything sensitive from a value before it is logged.
//
// Skyline's promise is that the server holds only ciphertext and minimal
// metadata, so the log must not become a side door around that. Redaction is
// by KEY NAME, deliberately broad: over-redacting a harmless field costs a
// little debuggability, under-redacting a secret costs a breach.

const REDACTED = '[REDACTED]';

// A key is sensitive if, ignoring case and punctuation, it contains any of these.
const SENSITIVE_FRAGMENTS = [
  'password',
  'passwd',
  'secret',
  'token',
  'authorization',
  'cookie',
  'ciphertext',
  'privatekey',
  'identitykey',
  'activationcode',
  'codehash',
  'refresh',
  'signature',
  'apikey',
];

// Short words that would false-positive as substrings ("shipping", "opinion",
// "statusCode") are matched only as the WHOLE key.
const SENSITIVE_EXACT = new Set(['pin', 'code', 'otp', 'key', 'hash']);

const MAX_DEPTH = 6;

function isSensitiveKey(key) {
  const flat = String(key)
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
  if (SENSITIVE_EXACT.has(flat)) return true;
  return SENSITIVE_FRAGMENTS.some((f) => flat.includes(f));
}

export function redact(value, depth = 0) {
  if (value === null || value === undefined) return value;
  if (Buffer.isBuffer(value)) return `[binary ${value.length} bytes]`;
  if (typeof value !== 'object') return value;
  if (depth >= MAX_DEPTH) return '[max depth]';

  if (value instanceof Error) {
    // Message and name are useful; the stack is logged separately by the caller.
    return { name: value.name, message: value.message };
  }
  if (Array.isArray(value)) return value.map((v) => redact(v, depth + 1));

  const out = {};
  for (const [k, v] of Object.entries(value)) {
    out[k] = isSensitiveKey(k) ? REDACTED : redact(v, depth + 1);
  }
  return out;
}

export { REDACTED, isSensitiveKey };
