import { Catch, HttpException, HttpStatus, Logger } from '@nestjs/common';

// Turns every failure into one consistent, deliberately unrevealing response.
//
// The important property is sameness. A user probing for people outside their
// contact graph must not be able to tell "does not exist" from "exists but is
// not linked to you", so every 404 has the identical status and body no matter
// which layer produced it: a guard, a service, or the router itself.
//
// Nothing internal ever reaches the client: no stack traces, no SQL, no
// constraint names, no paths. The details go to the log, keyed by request id.

const GENERIC = {
  [HttpStatus.UNAUTHORIZED]: 'Unauthorized',
  [HttpStatus.FORBIDDEN]: 'Forbidden',
  [HttpStatus.NOT_FOUND]: 'Not Found',
};

const STATUS_TEXT = {
  [HttpStatus.BAD_REQUEST]: 'Bad Request',
  [HttpStatus.UNAUTHORIZED]: 'Unauthorized',
  [HttpStatus.FORBIDDEN]: 'Forbidden',
  [HttpStatus.NOT_FOUND]: 'Not Found',
  [HttpStatus.METHOD_NOT_ALLOWED]: 'Method Not Allowed',
  [HttpStatus.CONFLICT]: 'Conflict',
  [HttpStatus.PAYLOAD_TOO_LARGE]: 'Payload Too Large',
  [HttpStatus.UNSUPPORTED_MEDIA_TYPE]: 'Unsupported Media Type',
  [HttpStatus.UNPROCESSABLE_ENTITY]: 'Unprocessable Entity',
  [HttpStatus.TOO_MANY_REQUESTS]: 'Too Many Requests',
  [HttpStatus.INTERNAL_SERVER_ERROR]: 'Internal Server Error',
  [HttpStatus.SERVICE_UNAVAILABLE]: 'Service Unavailable',
};

// Errors raised by Express body parsing are not HttpExceptions but carry an
// http-errors style status and an `expose` flag saying the client may see it.
function statusOf(exception) {
  if (exception instanceof HttpException) return exception.getStatus();
  const s = exception && (exception.status || exception.statusCode);
  if (
    exception &&
    exception.expose === true &&
    Number.isInteger(s) &&
    s >= 400 &&
    s < 500
  )
    return s;
  return HttpStatus.INTERNAL_SERVER_ERROR;
}

function messageOf(status, exception) {
  if (GENERIC[status]) return GENERIC[status];
  if (status >= 500) return 'Internal Server Error';

  // A 400 keeps its message ONLY when it is a list of validation results,
  // which our ValidationPipe produces and which describe the caller's own
  // input. Any other 400 message is generic: Nest wraps body-parser failures in
  // a BadRequestException whose text is the parser's ("Unexpected end of JSON
  // input"), and that is an implementation detail we do not hand out.
  if (status === HttpStatus.BAD_REQUEST && exception instanceof HttpException) {
    const body = exception.getResponse();
    const m = typeof body === 'object' && body !== null ? body.message : body;
    if (Array.isArray(m)) return m;
  }
  return STATUS_TEXT[status] || 'Error';
}

// For the rare server error whose body the thrower has deliberately decided is
// safe to publish, such as the up/down list in a readiness failure. Honoured
// for 5xx, and for 409 (a send whose device list is stale lists the devices to
// fix). Every other 4xx body stays generic (see the sameness rule above), so
// this can never be used to make a 404 distinguishable from another 404.
export class PublicBodyException extends HttpException {
  constructor(status, body) {
    super(body, status);
    this.publicBody = body;
  }
}

@Catch()
export class AllExceptionsFilter {
  constructor() {
    this.logger = new Logger('Exceptions');
  }

  catch(exception, host) {
    if (host.getType() !== 'http') return;

    const ctx = host.switchToHttp();
    const res = ctx.getResponse();
    const req = ctx.getRequest();

    const status = statusOf(exception);

    if (status >= 500) {
      this.logger.error(
        `${req.method} ${(req.originalUrl || req.url || '').split('?')[0]} failed (request ${req.id || 'n/a'}): ${exception && exception.message}`,
        exception && exception.stack,
      );
    }

    if (res.headersSent) return;

    if (
      exception instanceof PublicBodyException &&
      (status >= 500 || status === 409)
    ) {
      res.status(status).json(exception.publicBody);
      return;
    }

    res.status(status).json({
      statusCode: status,
      error: STATUS_TEXT[status] || 'Error',
      message: messageOf(status, exception),
    });
  }
}
