// Real WebSockets, real Redis pub/sub, real database, and two backend instances.
// The rule under test: an event NEVER reaches a device whose user is outside the
// sender's contact graph, decided at DELIVERY time, so revoking a link or a
// device stops delivery on a socket that is already open. This is obligation #2
// in docs/architecture/contact-graph.md and must never be deleted or weakened.
import WebSocket from 'ws';
import {
  createTestDatabase,
  mkUser,
  mkDevice,
  link,
  mkGroup,
} from '../db/harness';
import { createTestApp, newChannel } from './app-harness';
import { FanoutService } from '../../src/modules/websocket/fanout.service';
import { EventsGateway } from '../../src/modules/websocket/events.gateway';
import { DenyAllWsAuthenticator } from '../../src/modules/websocket/ws-authenticator';
import { RedisService } from '../../src/redis/redis.module';

// A WebSocket client that records everything it is sent.
class Client {
  constructor(url) {
    this.messages = [];
    this.closeCode = undefined;
    this.ws = new WebSocket(url);
    this.closed = new Promise((resolve) => {
      this.ws.on('close', (code) => {
        this.closeCode = code;
        resolve(code);
      });
    });
    this.ws.on('message', (data) =>
      this.messages.push(JSON.parse(data.toString())),
    );
    this.ws.on('error', () => {}); // a refused upgrade surfaces as 'close'
  }

  async waitFor(type, ms = 3000) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      const i = this.messages.findIndex((m) => m.type === type);
      if (i >= 0) return this.messages.splice(i, 1)[0];
      await new Promise((r) => setTimeout(r, 15));
    }
    return null;
  }

  // Resolves true if NOTHING but 'ready' arrives for `ms`.
  async receivesNothing(ms = 500) {
    await new Promise((r) => setTimeout(r, ms));
    return this.messages.filter((m) => m.type !== 'ready').length === 0;
  }

  close() {
    this.ws.close();
  }
}

describe('WebSocket fan-out (real sockets, Redis, database)', () => {
  let db;
  let A; // backend instance A
  let admin;
  const clients = [];

  const person = async (name) => {
    const u = await mkUser(db.client, name);
    u.device = await mkDevice(db.client, u.id);
    return u;
  };
  const connect = async (app, u, device = u.device) => {
    const c = new Client(
      `ws://localhost:${app.port}/ws?user=${u.id}&device=${device}`,
    );
    clients.push(c);
    return c;
  };
  const connected = async (app, u, device) => {
    const c = await connect(app, u, device);
    expect(await c.waitFor('ready')).not.toBeNull();
    return c;
  };
  const send = (app, from, to, payload = { n: 1 }) =>
    app.app.get(FanoutService).publish({
      type: 'message.new',
      senderUserId: from.id,
      recipientUserIds: Array.isArray(to) ? to.map((u) => u.id) : [to.id],
      payload,
    });
  const revokeLink = (a, b) =>
    db.client.query(
      `UPDATE contact_links SET revoked_at = now()
        WHERE user_a_id = LEAST($1::uuid,$2::uuid) AND user_b_id = GREATEST($1::uuid,$2::uuid) AND revoked_at IS NULL`,
      [a.id, b.id],
    );

  beforeAll(async () => {
    db = await createTestDatabase('fanout');
    admin = await mkUser(db.client, 'admin', { role: 'admin' });
    A = await createTestApp({ db, listen: true });
  }, 90000);

  afterEach(() => {
    while (clients.length) clients.pop().close();
  });

  afterAll(async () => {
    await A.close();
    await db.drop();
  });

  describe('who may connect', () => {
    it('refuses everyone by default: the Phase 4 authenticator denies all', async () => {
      expect(await new DenyAllWsAuthenticator().authenticate()).toBeNull();
    });

    it('closes a connection that presents no identity', async () => {
      const c = new Client(`ws://localhost:${A.port}/ws`);
      expect(await c.closed).toBe(1008);
    });

    it("closes a connection presenting someone else's device", async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      const c = await connect(A, alice, bob.device);
      expect(await c.closed).toBe(1008);
    });

    it('closes a connection from a suspended account or a revoked device', async () => {
      const s = await person('sus');
      await db.client.query(
        `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
        [s.id],
      );
      expect(await (await connect(A, s)).closed).toBe(1008);

      const r = await person('rev');
      await db.client.query(
        `UPDATE devices SET revoked_at = now() WHERE id = $1`,
        [r.device],
      );
      expect(await (await connect(A, r)).closed).toBe(1008);
    });

    it('admits a valid account and says ready', async () => {
      const alice = await person('alice');
      const c = await connect(A, alice);
      expect(await c.waitFor('ready')).toEqual({ type: 'ready' });
    });

    it('replaces an earlier socket from the same device rather than keeping two', async () => {
      const alice = await person('alice');
      const first = await connected(A, alice);
      const second = await connected(A, alice);
      expect(await first.closed).toBe(1000);
      expect(second.closeCode).toBeUndefined();
    });
  });

  describe('delivery follows the contact graph', () => {
    it('delivers to a linked contact', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      await link(db.client, alice.id, bob.id, admin.id);
      const c = await connected(A, alice);

      await send(A, bob, alice, { n: 42 });

      expect(await c.waitFor('message.new')).toEqual({
        type: 'message.new',
        from: bob.id,
        payload: { n: 42 },
      });
    });

    it('delivers to someone who shares a group', async () => {
      const alice = await person('alice');
      const carol = await person('carol');
      await mkGroup(db.client, admin.id, [alice.id, carol.id]);
      const c = await connected(A, alice);

      await send(A, carol, alice);

      expect(await c.waitFor('message.new')).not.toBeNull();
    });

    it("NEVER delivers to a user outside the sender's graph, even if they are connected", async () => {
      const bob = await person('bob');
      const dave = await person('dave'); // no links at all
      const c = await connected(A, dave);

      await send(A, bob, dave);

      expect(await c.receivesNothing()).toBe(true);
    });

    it('delivers to the linked recipient and not to the unlinked one, in the same event', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      const dave = await person('dave');
      await link(db.client, alice.id, bob.id, admin.id);
      const forAlice = await connected(A, alice);
      const forDave = await connected(A, dave);

      await send(A, bob, [alice, dave]);

      expect(await forAlice.waitFor('message.new')).not.toBeNull();
      expect(await forDave.receivesNothing()).toBe(true);
    });

    it('does not chain: a contact of a contact receives nothing', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      const eve = await person('eve');
      await link(db.client, alice.id, bob.id, admin.id);
      await link(db.client, bob.id, eve.id, admin.id); // eve knows bob, not alice
      const c = await connected(A, eve);

      await send(A, alice, eve);

      expect(await c.receivesNothing()).toBe(true);
    });

    it("reaches the sender's own other devices, so a phone's message shows up on the desktop", async () => {
      const alice = await person('alice');
      const desktop = await mkDevice(db.client, alice.id);
      const c = await connected(A, alice, desktop);

      await send(A, alice, alice);

      expect(await c.waitFor('message.new')).not.toBeNull();
    });
  });

  describe('revocation takes effect on a socket that is ALREADY OPEN', () => {
    it('stops delivering the instant a link is revoked, without a reconnect, and resumes when re-granted', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      await link(db.client, alice.id, bob.id, admin.id);
      const c = await connected(A, alice);

      await send(A, bob, alice, { n: 1 });
      expect(await c.waitFor('message.new')).not.toBeNull();

      await revokeLink(alice, bob);
      await send(A, bob, alice, { n: 2 });
      expect(await c.receivesNothing()).toBe(true);
      expect(c.closeCode).toBeUndefined(); // the socket itself stayed open

      await link(db.client, alice.id, bob.id, admin.id);
      await send(A, bob, alice, { n: 3 });
      const again = await c.waitFor('message.new');
      expect(again.payload).toEqual({ n: 3 });
    });

    it('stops delivering when the recipient is suspended, and the sweep then closes their socket', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      await link(db.client, alice.id, bob.id, admin.id);
      const c = await connected(A, alice);

      await db.client.query(
        `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
        [alice.id],
      );
      await send(A, bob, alice);
      expect(await c.receivesNothing()).toBe(true);

      await A.app.get(EventsGateway).sweep();
      expect(await c.closed).toBe(1008);
    });

    it('stops delivering when the recipient device is revoked, and the sweep closes it', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      await link(db.client, alice.id, bob.id, admin.id);
      const c = await connected(A, alice);

      await db.client.query(
        `UPDATE devices SET revoked_at = now() WHERE id = $1`,
        [alice.device],
      );
      await send(A, bob, alice);
      expect(await c.receivesNothing()).toBe(true);

      await A.app.get(EventsGateway).sweep();
      expect(await c.closed).toBe(1008);
    });

    it('leaves a still-valid neighbour untouched when the sweep closes someone else', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      const cAlice = await connected(A, alice);
      const cBob = await connected(A, bob);
      await db.client.query(
        `UPDATE devices SET revoked_at = now() WHERE id = $1`,
        [alice.device],
      );

      await A.app.get(EventsGateway).sweep();

      expect(await cAlice.closed).toBe(1008);
      expect(cBob.closeCode).toBeUndefined();
    });
  });

  describe('across more than one backend instance', () => {
    let A2;
    let B;
    let shared;

    beforeAll(async () => {
      shared = newChannel();
      // Two independent backends, one database, one Redis channel.
      A2 = await createTestApp({ db, listen: true, channel: shared });
      B = await createTestApp({ db, listen: true, channel: shared });
    }, 90000);

    afterAll(async () => {
      await A2.close();
      await B.close();
    });

    it('delivers an event published on one instance to a socket connected to another, exactly once', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      await link(db.client, alice.id, bob.id, admin.id);
      const onA = await connected(A2, alice); // alice is connected to instance A2 only

      await send(B, bob, alice, { via: 'B' }); // the event enters through instance B

      const got = await onA.waitFor('message.new');
      expect(got.payload).toEqual({ via: 'B' });
      expect(await onA.receivesNothing()).toBe(true); // and not a second copy
    });

    it('still enforces the graph on the receiving instance', async () => {
      const bob = await person('bob');
      const dave = await person('dave');
      const onA = await connected(A2, dave);

      await send(B, bob, dave);

      expect(await onA.receivesNothing()).toBe(true);
    });
  });

  describe('bad input', () => {
    it('ignores junk on the Redis channel and keeps delivering afterwards', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      await link(db.client, alice.id, bob.id, admin.id);
      const c = await connected(A, alice);
      const redis = A.app.get(RedisService);

      await redis.publish(A.channel, 'this is not json');
      await redis.publish(A.channel, JSON.stringify({ type: 'message.new' }));
      await redis.publish(
        A.channel,
        JSON.stringify({
          type: 'x',
          senderUserId: 'nope',
          recipientUserIds: [],
          payload: {},
        }),
      );
      await send(A, bob, alice, { after: 'junk' });

      expect((await c.waitFor('message.new')).payload).toEqual({
        after: 'junk',
      });
    });

    it('refuses to publish a malformed event at all', () => {
      const fan = A.app.get(FanoutService);
      const ok = {
        type: 'message.new',
        senderUserId: admin.id,
        recipientUserIds: [admin.id],
        payload: {},
      };
      expect(() => fan.publish(ok)).not.toThrow();

      const bad = [
        { ...ok, type: 'Bad Type!' },
        { ...ok, type: undefined },
        { ...ok, senderUserId: 'not-a-uuid' },
        { ...ok, recipientUserIds: [] },
        { ...ok, recipientUserIds: ['not-a-uuid'] },
        { ...ok, recipientUserIds: Array(1001).fill(admin.id) },
        { ...ok, payload: null },
        { ...ok, payload: { blob: 'x'.repeat(70 * 1024) } },
      ];
      for (const e of bad)
        expect(() => fan.publish(e)).toThrow(/invalid event/);
    });

    it('ignores whatever a client sends, since clients send over authenticated REST instead', async () => {
      const alice = await person('alice');
      const bob = await person('bob');
      const dave = await person('dave');
      await link(db.client, alice.id, bob.id, admin.id);
      const cAlice = await connected(A, alice);
      const cBob = await connected(A, bob);
      const cDave = await connected(A, dave);

      cAlice.ws.send(
        JSON.stringify({
          type: 'message.new',
          senderUserId: alice.id,
          recipientUserIds: [dave.id],
          payload: {},
        }),
      );
      cAlice.ws.send('garbage');

      expect(await cDave.receivesNothing()).toBe(true);
      expect(await cBob.receivesNothing()).toBe(true);
      expect(cAlice.closeCode).toBeUndefined();
    });
  });
});
