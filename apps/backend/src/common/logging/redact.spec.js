import { redact, REDACTED, isSensitiveKey } from './redact';

describe('redact', () => {
  it.each([
    'password',
    'Authorization',
    'refresh_token',
    'refreshToken',
    'x-api-key',
    'activation_code',
    'activationCode',
    'code_hash',
    'ciphertext',
    'private_key',
    'identity_key',
    'cookie',
    'set-cookie',
    'pin',
    'PIN',
    'code',
    'otp',
  ])('treats %s as sensitive', (key) => {
    expect(isSensitiveKey(key)).toBe(true);
  });

  it.each([
    'statusCode',
    'shipping',
    'opinion',
    'username',
    'chatId',
    'userId',
    'method',
    'url',
  ])('does not over-match the harmless key %s', (key) => {
    expect(isSensitiveKey(key)).toBe(false);
  });

  it('redacts nested values, including inside arrays', () => {
    const out = redact({
      user: 'sarah',
      body: { password: 'hunter2', nested: [{ token: 'abc' }, { ok: 1 }] },
    });
    expect(out.user).toBe('sarah');
    expect(out.body.password).toBe(REDACTED);
    expect(out.body.nested[0].token).toBe(REDACTED);
    expect(out.body.nested[1].ok).toBe(1);
  });

  it('never reproduces a secret anywhere in the serialized output', () => {
    const out = JSON.stringify(
      redact({
        headers: { authorization: 'Bearer eyJsecret' },
        deeply: { in: { here: { pin: '4711' } } },
      }),
    );
    expect(out).not.toContain('eyJsecret');
    expect(out).not.toContain('4711');
  });

  it('summarises binary data instead of printing it', () => {
    expect(redact({ blob: Buffer.from('opaque bytes') }).blob).toBe(
      '[binary 12 bytes]',
    );
  });

  it('keeps an error name and message but drops other properties', () => {
    const err = new Error('boom');
    err.password = 'leak';
    const out = redact({ err });
    expect(out.err).toEqual({ name: 'Error', message: 'boom' });
  });

  it('stops at a maximum depth rather than recursing forever on cyclic data', () => {
    const a = { name: 'a' };
    a.self = a;
    expect(() => redact(a)).not.toThrow();
  });

  it('passes primitives and null through unchanged', () => {
    expect(redact(42)).toBe(42);
    expect(redact('text')).toBe('text');
    expect(redact(null)).toBeNull();
    expect(redact(undefined)).toBeUndefined();
  });
});
