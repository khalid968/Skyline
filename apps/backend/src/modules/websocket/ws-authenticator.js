import { Injectable } from '@nestjs/common';

export const WS_AUTHENTICATOR = 'WS_AUTHENTICATOR';

// The seam Phase 5 fills. An authenticator turns the HTTP upgrade request into
// `{ userId, deviceId }`, or null. The gateway then re-checks that account and
// device against the database before letting the socket in.
//
// The default denies everyone. A WebSocket that anyone can open is a way to
// receive other people's traffic, so until real authentication exists the
// safe behaviour is that nobody connects.
@Injectable()
export class DenyAllWsAuthenticator {
  async authenticate() {
    return null;
  }
}
