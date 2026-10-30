import { Dependencies, Logger } from '@nestjs/common';
import { WebSocketGateway } from '@nestjs/websockets';
import { WS_AUTHENTICATOR } from './ws-authenticator';
import { AccountService } from '../authorization/account.service';
import { ConnectionRegistry } from './connection-registry';

const HEARTBEAT_MS = 30000;

// Server-to-client push. Inbound frames are ignored: in Skyline the client
// SENDS over authenticated REST (where the contact graph is enforced per
// request) and RECEIVES over this socket. Keeping the socket one-directional
// removes a whole class of "send a message by writing to the socket" bugs that
// would bypass the REST guards.
@WebSocketGateway({ path: '/ws', maxPayload: 16 * 1024 })
@Dependencies(WS_AUTHENTICATOR, AccountService, ConnectionRegistry)
export class EventsGateway {
  constructor(authenticator, accounts, registry) {
    this.authenticator = authenticator;
    this.accounts = accounts;
    this.registry = registry;
    this.logger = new Logger('WebSocket');
    this.timer = null;
  }

  onModuleInit() {
    this.timer = setInterval(
      () => this.sweep().catch((e) => this.logger.error(e.message)),
      HEARTBEAT_MS,
    );
    this.timer.unref();
  }

  onModuleDestroy() {
    clearInterval(this.timer);
  }

  async handleConnection(client, request) {
    try {
      const principal = await this.authenticator.authenticate(request);
      const account = principal
        ? await this.accounts.loadActive(principal.userId, principal.deviceId)
        : null;

      // One generic refusal for every reason, as with HTTP.
      if (!account) return client.close(1008, 'unauthorized');
      // The client may have hung up while we were checking.
      if (client.readyState !== client.OPEN) return;

      client.isAlive = true;
      client.on('pong', () => {
        client.isAlive = true;
      });
      this.registry.add({
        socket: client,
        userId: account.userId,
        deviceId: account.deviceId,
        // Real sign-ins always carry it; only the test authenticator omits it.
        sessionId: principal.sessionId,
      });
      client.send(JSON.stringify({ type: 'ready' }));
    } catch (err) {
      this.logger.error(`connection setup failed: ${err.message}`);
      client.close(1011, 'error');
    }
  }

  handleDisconnect(client) {
    this.registry.remove(client);
  }

  // Runs on a timer. Drops dead connections, and closes any whose account was
  // suspended, whose device was revoked, or whose session ended (logout,
  // refresh-token reuse) since they connected. Deliveries are already refused
  // for those the instant it happens (FanoutService); this just stops an
  // inert socket lingering.
  async sweep() {
    const conns = this.registry.all();
    if (conns.length === 0) return;

    for (const c of conns) {
      if (c.socket.isAlive === false) {
        c.socket.terminate();
        continue;
      }
      c.socket.isAlive = false;
      c.socket.ping();
    }

    const live = await this.accounts.liveDeviceIds(
      conns.map((c) => c.deviceId),
    );
    for (const c of conns) {
      if (!live.has(c.deviceId))
        this.registry.disconnectDevice(c.deviceId, 1008, 'revoked');
    }

    const withSession = conns.filter((c) => c.sessionId);
    if (withSession.length === 0) return;
    const liveSessions = await this.accounts.liveSessionIds(
      withSession.map((c) => c.sessionId),
    );
    for (const c of withSession) {
      if (!liveSessions.has(c.sessionId))
        this.registry.disconnectSession(c.sessionId);
    }
  }
}
