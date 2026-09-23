import { Injectable, Dependencies } from '@nestjs/common';
import { SessionService } from '../authorization/session.service';

export const WS_AUTHENTICATOR = 'WS_AUTHENTICATOR';

// Turns a WebSocket upgrade request into `{ userId, deviceId }`, or null. The
// gateway then re-checks that account and device against the database before
// letting the socket in.
//
// Only a DEVICE access token is accepted: the socket delivers a member's
// messages, and a dashboard login has no business receiving them.
//
// The token is read from the Authorization header, which native clients (the
// Flutter app) can set. `?token=` is accepted as a fallback for clients that
// cannot set headers on a WebSocket; query strings are never logged.
@Injectable()
@Dependencies(SessionService)
export class TokenWsAuthenticator {
  constructor(sessions) {
    this.sessions = sessions;
  }

  async authenticate(request) {
    const token =
      bearer(request.headers && request.headers.authorization) ||
      fromQuery(request.url);
    if (!token) return null;
    const principal = await this.sessions.resolveDeviceAccess(token);
    return principal
      ? { userId: principal.userId, deviceId: principal.deviceId }
      : null;
  }
}

// Kept for tests and as the safe fallback: denies everyone.
@Injectable()
export class DenyAllWsAuthenticator {
  async authenticate() {
    return null;
  }
}

function bearer(header) {
  return typeof header === 'string' && header.startsWith('Bearer ')
    ? header.slice('Bearer '.length).trim()
    : null;
}

function fromQuery(url) {
  try {
    return new URL(url, 'http://localhost').searchParams.get('token');
  } catch {
    return null;
  }
}
