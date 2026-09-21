import {
  BadRequestException,
  ForbiddenException,
  HttpException,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
import {
  AllExceptionsFilter,
  PublicBodyException,
} from './all-exceptions.filter';

// Runs the filter against a fake HTTP host and returns what the client would get.
function run(exception, { type = 'http', headersSent = false } = {}) {
  const sent = { status: undefined, body: undefined, calls: 0 };
  const res = {
    headersSent,
    status(s) {
      sent.status = s;
      return this;
    },
    json(b) {
      sent.body = b;
      sent.calls++;
      return this;
    },
  };
  const host = {
    getType: () => type,
    switchToHttp: () => ({
      getResponse: () => res,
      getRequest: () => ({ method: 'GET', url: '/x?secret=1', id: 'r1' }),
    }),
  };
  const filter = new AllExceptionsFilter();
  filter.logger = { error: jest.fn() };
  filter.catch(exception, host);
  return { ...sent, logger: filter.logger };
}

describe('AllExceptionsFilter', () => {
  describe('every 404 is identical, whatever produced it', () => {
    const producers = {
      'a guard with no message': new NotFoundException(),
      'a service naming the missing thing': new NotFoundException(
        'User 4f2a not found',
      ),
      'a service leaking a table': new NotFoundException(
        'no row in users for id 7',
      ),
      'the router': new HttpException('Cannot GET /nope', 404),
      'an object body': new NotFoundException({ message: 'x', extra: 'y' }),
    };

    it('renders one status and one body for all of them', () => {
      const seen = new Set(
        Object.values(producers).map((e) => JSON.stringify(run(e).body)),
      );
      expect(seen.size).toBe(1);
      expect(run(new NotFoundException()).body).toEqual({
        statusCode: 404,
        error: 'Not Found',
        message: 'Not Found',
      });
    });
  });

  it('gives 401 and 403 a fixed generic message, ignoring whatever was thrown', () => {
    expect(
      run(new UnauthorizedException('token expired at 12:00')).body.message,
    ).toBe('Unauthorized');
    expect(
      run(new ForbiddenException('you lack users.rename')).body.message,
    ).toBe('Forbidden');
  });

  describe('400', () => {
    it("keeps a LIST of validation messages, which describe the caller's own input", () => {
      const out = run(
        new BadRequestException([
          'name must be a string',
          'count must not be less than 1',
        ]),
      );
      expect(out.status).toBe(400);
      expect(out.body.message).toEqual([
        'name must be a string',
        'count must not be less than 1',
      ]);
    });

    it('replaces any other message with a generic one, such as a body parser internal', () => {
      expect(
        run(new BadRequestException('Unexpected end of JSON input')).body
          .message,
      ).toBe('Bad Request');
    });
  });

  it('maps an Express body-parser style error to its status with generic text', () => {
    const tooBig = Object.assign(new Error('request entity too large'), {
      status: 413,
      expose: true,
    });
    const out = run(tooBig);
    expect(out.status).toBe(413);
    expect(out.body).toEqual({
      statusCode: 413,
      error: 'Payload Too Large',
      message: 'Payload Too Large',
    });
  });

  describe('unexpected errors', () => {
    it('become a generic 500 and never expose the message, SQL, or stack', () => {
      const out = run(new Error('relation "secret_table" does not exist'));
      expect(out.status).toBe(500);
      expect(JSON.stringify(out.body)).not.toMatch(
        /secret_table|relation|stack|at /,
      );
      expect(out.body.message).toBe('Internal Server Error');
    });

    it('are logged with the detail the client is denied, and the request id', () => {
      const out = run(new Error('boom detail'));
      expect(out.logger.error).toHaveBeenCalledTimes(1);
      const [line] = out.logger.error.mock.calls[0];
      expect(line).toContain('boom detail');
      expect(line).toContain('r1');
    });

    it('do not log the query string, which can carry tokens', () => {
      const [line] = run(new Error('x')).logger.error.mock.calls[0];
      expect(line).not.toContain('secret=1');
    });

    it('treat a non-Error thrown value as a 500 as well', () => {
      expect(run('a string was thrown').status).toBe(500);
      expect(run(undefined).status).toBe(500);
    });
  });

  describe('PublicBodyException', () => {
    it('publishes its body for a 5xx, which is what a readiness failure needs', () => {
      const body = { status: 'unavailable', checks: { database: 'down' } };
      const out = run(new PublicBodyException(503, body));
      expect(out.status).toBe(503);
      expect(out.body).toEqual(body);
    });

    it('is IGNORED for a 4xx, so it can never be used to tell one 404 from another', () => {
      const out = run(
        new PublicBodyException(404, {
          secret: 'this user exists but is not linked to you',
        }),
      );
      expect(out.status).toBe(404);
      expect(out.body).toEqual({
        statusCode: 404,
        error: 'Not Found',
        message: 'Not Found',
      });
    });
  });

  it('does nothing for a non-HTTP context', () => {
    expect(run(new Error('x'), { type: 'ws' }).calls).toBe(0);
  });

  it('does not write a second response once headers are sent', () => {
    expect(run(new NotFoundException(), { headersSent: true }).calls).toBe(0);
  });
});
