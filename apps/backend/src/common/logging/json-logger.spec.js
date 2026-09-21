import { JsonLogger } from './json-logger';

const capture = () => {
  const out = [];
  const err = [];
  return {
    out,
    err,
    sink: {
      stdout: { write: (s) => out.push(s) },
      stderr: { write: (s) => err.push(s) },
    },
  };
};

describe('JsonLogger', () => {
  it('writes one parseable JSON object per line', () => {
    const c = capture();
    new JsonLogger('log', c.sink).log('hello', 'MyContext');
    expect(c.out).toHaveLength(1);
    expect(c.out[0].endsWith('\n')).toBe(true);
    const parsed = JSON.parse(c.out[0]);
    expect(parsed).toMatchObject({
      level: 'log',
      message: 'hello',
      context: 'MyContext',
    });
    expect(parsed.time).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it('sends errors and warnings to stderr and the rest to stdout', () => {
    const c = capture();
    const logger = new JsonLogger('verbose', c.sink);
    logger.error('bad');
    logger.warn('hmm');
    logger.log('fine');
    expect(c.err).toHaveLength(2);
    expect(c.out).toHaveLength(1);
  });

  it('respects the configured level', () => {
    const c = capture();
    const logger = new JsonLogger('warn', c.sink);
    logger.log('ignored');
    logger.debug('ignored');
    logger.warn('kept');
    logger.error('kept');
    expect(c.out).toHaveLength(0);
    expect(c.err).toHaveLength(2);
  });

  it('is completely silent at level "silent"', () => {
    const c = capture();
    const logger = new JsonLogger('silent', c.sink);
    logger.error('nothing');
    logger.log('nothing');
    expect(c.out).toHaveLength(0);
    expect(c.err).toHaveLength(0);
  });

  it('redacts sensitive fields in structured events', () => {
    const c = capture();
    new JsonLogger('log', c.sink).event('log', 'request', {
      method: 'POST',
      headers: { authorization: 'Bearer secret-token-value' },
      pin: '4711',
    });
    const line = c.out[0];
    expect(line).not.toContain('secret-token-value');
    expect(line).not.toContain('4711');
    expect(JSON.parse(line).method).toBe('POST');
  });

  it('redacts an object passed as the message itself', () => {
    const c = capture();
    new JsonLogger('log', c.sink).log({ password: 'hunter2', user: 'sarah' });
    expect(c.out[0]).not.toContain('hunter2');
    expect(c.out[0]).toContain('sarah');
  });

  it('includes a stack when Nest passes one with an error', () => {
    const c = capture();
    new JsonLogger('log', c.sink).error('failed', 'Error: x\n  at y', 'Ctx');
    const parsed = JSON.parse(c.err[0]);
    expect(parsed.stack).toContain('Error: x');
    expect(parsed.context).toBe('Ctx');
  });
});
