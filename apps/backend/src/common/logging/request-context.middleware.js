import { randomUUID } from 'crypto';

// Gives every request an id and writes one access-log line when it finishes.
//
// This is middleware rather than an interceptor on purpose: guards run before
// interceptors, so an interceptor would never see a request a guard rejected,
// and rejected requests are exactly the ones worth seeing.
//
// Only the path is logged, never the query string (which can carry tokens),
// and never a request or response body.

// An inbound id is honoured only if it is short and boring, so a caller cannot
// inject newlines or huge strings into the logs.
const SAFE_ID = /^[A-Za-z0-9_-]{8,64}$/;

export function requestContext(logger) {
  return function requestContextMiddleware(req, res, next) {
    const inbound = req.headers['x-request-id'];
    req.id =
      typeof inbound === 'string' && SAFE_ID.test(inbound)
        ? inbound
        : randomUUID();
    res.setHeader('x-request-id', req.id);

    const started = process.hrtime.bigint();
    res.on('finish', () => {
      const ms = Number(process.hrtime.bigint() - started) / 1e6;
      logger.event(
        res.statusCode >= 500 ? 'error' : 'log',
        'request',
        {
          requestId: req.id,
          method: req.method,
          path: (req.originalUrl || req.url || '').split('?')[0],
          status: res.statusCode,
          ms: Math.round(ms * 10) / 10,
          userId: (req.principal && req.principal.userId) || undefined,
        },
        'HTTP',
      );
    });

    next();
  };
}
