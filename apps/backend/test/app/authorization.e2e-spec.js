// End-to-end tests of the three global guards through real HTTP, against a real
// database. These are the obligations from docs/architecture/contact-graph.md
// and must never be deleted or weakened.
import request from 'supertest';
import {
  createTestDatabase,
  mkUser,
  mkDevice,
  link,
  mkGroup,
} from '../db/harness';
import { createTestApp } from './app-harness';
import { TestController } from './test-routes';

describe('authorization (HTTP, real database)', () => {
  let db;
  let t; // the test app
  let admin, alice, bob, carol, dave;
  let aliceDev, bobDev, carolDev, daveDev, adminDev;
  let chatAB, chatG, groupG;

  const get = (path, who) => {
    const req = request(t.app.getHttpServer()).get(path);
    return who ? req.set(t.as(who.user, who.device)) : req;
  };
  const asAlice = () => ({ user: alice.id, device: aliceDev });
  const asBob = () => ({ user: bob.id, device: bobDev });
  const asCarol = () => ({ user: carol.id, device: carolDev });
  const asDave = () => ({ user: dave.id, device: daveDev });
  const asAdmin = () => ({ user: admin.id, device: adminDev });

  const directChat = async (a, b) => {
    const [lo, hi] = a < b ? [a, b] : [b, a];
    return (
      await db.client.query(
        `INSERT INTO chats (kind, user_a_id, user_b_id) VALUES ('direct', $1, $2) RETURNING id`,
        [lo, hi],
      )
    ).rows[0].id;
  };

  beforeAll(async () => {
    db = await createTestDatabase('authz');
    const c = db.client;

    admin = await mkUser(c, 'admin', { role: 'admin' });
    alice = await mkUser(c, 'alice');
    bob = await mkUser(c, 'bob');
    carol = await mkUser(c, 'carol');
    dave = await mkUser(c, 'dave'); // deliberately has NO links at all
    for (const u of [admin, alice, bob, carol, dave])
      u.device = await mkDevice(c, u.id);
    adminDev = admin.device;
    aliceDev = alice.device;
    bobDev = bob.device;
    carolDev = carol.device;
    daveDev = dave.device;

    await link(c, alice.id, bob.id, admin.id); // alice <-> bob directly
    groupG = await mkGroup(c, admin.id, [alice.id, carol.id]); // alice & carol share a group
    chatAB = await directChat(alice.id, bob.id);
    chatG = (
      await c.query(
        `INSERT INTO chats (kind, group_id) VALUES ('group', $1) RETURNING id`,
        [groupG],
      )
    ).rows[0].id;

    t = await createTestApp({ db, controllers: [TestController] });
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  describe('authentication is default-deny', () => {
    it('rejects a request with no credentials', async () => {
      const res = await get('/t/open');
      expect(res.status).toBe(401);
      expect(res.body).toEqual({
        statusCode: 401,
        error: 'Unauthorized',
        message: 'Unauthorized',
      });
    });

    it('admits a valid, active account', async () => {
      const res = await get('/t/open', asAlice());
      expect(res.status).toBe(200);
    });

    it('lets a route through only if it is explicitly @Public', async () => {
      expect((await get('/t/public')).status).toBe(200);
    });

    it('answers every reason for refusal identically, so none can be told apart', async () => {
      const c = db.client;
      const pending = await mkUser(c, 'pending', { status: 'pending' });
      pending.device = await mkDevice(c, pending.id);
      const suspended = await mkUser(c, 'suspended');
      suspended.device = await mkDevice(c, suspended.id);
      await c.query(
        `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
        [suspended.id],
      );
      const revoked = await mkUser(c, 'revoked');
      revoked.device = await mkDevice(c, revoked.id);
      await c.query(`UPDATE devices SET revoked_at = now() WHERE id = $1`, [
        revoked.device,
      ]);

      const attempts = [
        ['no credentials', null],
        [
          'unknown user',
          { user: '00000000-0000-4000-8000-000000000001', device: aliceDev },
        ],
        ['malformed ids', { user: 'not-a-uuid', device: 'also-not' }],
        ["someone else's device", { user: alice.id, device: bobDev }],
        ['pending account', { user: pending.id, device: pending.device }],
        ['suspended account', { user: suspended.id, device: suspended.device }],
        ['revoked device', { user: revoked.id, device: revoked.device }],
      ];

      const bodies = [];
      for (const [label, who] of attempts) {
        const res = await get('/t/open', who);
        expect([label, res.status]).toEqual([label, 401]);
        bodies.push(JSON.stringify(res.body));
      }
      expect(new Set(bodies).size).toBe(1);
    });

    it('takes effect on the very next request when an account is suspended', async () => {
      const c = db.client;
      const u = await mkUser(c, 'temp');
      const d = await mkDevice(c, u.id);
      expect((await get('/t/open', { user: u.id, device: d })).status).toBe(
        200,
      );

      await c.query(
        `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
        [u.id],
      );
      expect((await get('/t/open', { user: u.id, device: d })).status).toBe(
        401,
      );

      await c.query(
        `UPDATE users SET status = 'active', suspended_at = NULL WHERE id = $1`,
        [u.id],
      );
      expect((await get('/t/open', { user: u.id, device: d })).status).toBe(
        200,
      );
    });

    it('takes effect on the very next request when a device is revoked', async () => {
      const c = db.client;
      const u = await mkUser(c, 'lost');
      const d = await mkDevice(c, u.id);
      expect((await get('/t/open', { user: u.id, device: d })).status).toBe(
        200,
      );

      await c.query(`UPDATE devices SET revoked_at = now() WHERE id = $1`, [d]);
      expect((await get('/t/open', { user: u.id, device: d })).status).toBe(
        401,
      );
    });
  });

  describe('permissions', () => {
    it('refuses a member on an operator route with 403', async () => {
      expect((await get('/t/admin', asAlice())).status).toBe(403);
    });

    it('admits an administrator', async () => {
      expect((await get('/t/admin', asAdmin())).status).toBe(200);
    });

    it('asks who you are before what you may do: no credentials is 401, not 403', async () => {
      expect((await get('/t/admin')).status).toBe(401);
    });

    it('applies a promotion or demotion on the very next request', async () => {
      const c = db.client;
      const u = await mkUser(c, 'promoted');
      const d = await mkDevice(c, u.id);
      const who = { user: u.id, device: d };
      expect((await get('/t/admin', who)).status).toBe(403);

      await c.query(`UPDATE users SET role_key = 'admin' WHERE id = $1`, [
        u.id,
      ]);
      expect((await get('/t/admin', who)).status).toBe(200);

      await c.query(`UPDATE users SET role_key = 'member' WHERE id = $1`, [
        u.id,
      ]);
      expect((await get('/t/admin', who)).status).toBe(403);
    });
  });

  describe('the contact graph', () => {
    it('lets a user see a direct contact', async () => {
      expect((await get(`/t/user/${bob.id}`, asAlice())).status).toBe(200);
      expect((await get(`/t/user/${alice.id}`, asBob())).status).toBe(200); // symmetric
    });

    it('lets a user see someone who shares a group', async () => {
      expect((await get(`/t/user/${carol.id}`, asAlice())).status).toBe(200);
    });

    it('requires a DIRECT link to message someone: sharing a group is not enough', async () => {
      expect((await get(`/t/direct/${bob.id}`, asAlice())).status).toBe(200);
      expect((await get(`/t/direct/${carol.id}`, asAlice())).status).toBe(404);
    });

    it('never reaches beyond one hop: a friend of a friend is invisible', async () => {
      // bob is alice's contact; carol is alice's group-mate; bob and carol share nothing.
      expect((await get(`/t/user/${carol.id}`, asBob())).status).toBe(404);
    });

    it('makes a user with zero links see NOTHING, on every kind of target', async () => {
      const targets = [
        `/t/user/${alice.id}`,
        `/t/user/${bob.id}`,
        `/t/user/${carol.id}`,
        `/t/direct/${alice.id}`,
        `/t/group/${groupG}`,
        `/t/chat/${chatAB}`,
        `/t/chat/${chatG}`,
      ];
      for (const path of targets) {
        expect([path, (await get(path, asDave())).status]).toEqual([path, 404]);
      }
    });

    it('treats the empty app as a normal state, not an error', async () => {
      expect((await get('/t/open', asDave())).status).toBe(200);
    });

    it('refuses to let a user target themselves', async () => {
      expect((await get(`/t/user/${alice.id}`, asAlice())).status).toBe(404);
    });

    it('answers "does not exist", "malformed", "not linked to you" and "deleted" with the SAME 404', async () => {
      const c = db.client;
      const gone = await mkUser(c, 'gone');
      await mkDevice(c, gone.id);
      await link(c, alice.id, gone.id, admin.id);
      await c.query(
        `UPDATE users SET status = 'deleted', deleted_at = now() WHERE id = $1`,
        [gone.id],
      );

      const probes = [
        ['does not exist', `/t/user/00000000-0000-4000-8000-00000000dead`],
        ['malformed id', `/t/user/not-a-real-id`],
        ['exists but not linked to you', `/t/user/${dave.id}`],
        ['linked but deleted', `/t/user/${gone.id}`],
        ['an unknown route entirely', `/t/no-such-route`],
      ];

      const seen = [];
      for (const [label, path] of probes) {
        const res = await get(path, asAlice());
        expect([label, res.status]).toEqual([label, 404]);
        seen.push(JSON.stringify(res.body));
      }
      expect(new Set(seen).size).toBe(1);
    });

    it('takes a revoked link away IMMEDIATELY, on the next request, for the person and their chat', async () => {
      const c = db.client;
      const p = await mkUser(c, 'p');
      const q = await mkUser(c, 'q');
      p.device = await mkDevice(c, p.id);
      q.device = await mkDevice(c, q.id);
      const linkId = await link(c, p.id, q.id, admin.id);
      const chat = await directChat(p.id, q.id);
      const asP = { user: p.id, device: p.device };
      const asQ = { user: q.id, device: q.device };

      expect((await get(`/t/user/${q.id}`, asP)).status).toBe(200);
      expect((await get(`/t/direct/${q.id}`, asP)).status).toBe(200);
      expect((await get(`/t/chat/${chat}`, asQ)).status).toBe(200);

      await c.query(
        `UPDATE contact_links SET revoked_at = now(), revoked_by = $2 WHERE id = $1`,
        [linkId, admin.id],
      );

      // Both directions, and the conversation itself, vanish at once.
      expect((await get(`/t/user/${q.id}`, asP)).status).toBe(404);
      expect((await get(`/t/user/${p.id}`, asQ)).status).toBe(404);
      expect((await get(`/t/direct/${q.id}`, asP)).status).toBe(404);
      expect((await get(`/t/chat/${chat}`, asP)).status).toBe(404);
      expect((await get(`/t/chat/${chat}`, asQ)).status).toBe(404);
    });

    it('brings a chat back if the link is granted again, keeping the same conversation', async () => {
      const c = db.client;
      const p = await mkUser(c, 'again');
      const q = await mkUser(c, 'again');
      p.device = await mkDevice(c, p.id);
      const first = await link(c, p.id, q.id, admin.id);
      const chat = await directChat(p.id, q.id);
      await c.query(
        `UPDATE contact_links SET revoked_at = now() WHERE id = $1`,
        [first],
      );
      expect(
        (await get(`/t/chat/${chat}`, { user: p.id, device: p.device })).status,
      ).toBe(404);

      await link(c, p.id, q.id, admin.id);
      expect(
        (await get(`/t/chat/${chat}`, { user: p.id, device: p.device })).status,
      ).toBe(200);
    });

    describe('groups and chats', () => {
      it('admits a live member and refuses everyone else', async () => {
        expect((await get(`/t/group/${groupG}`, asAlice())).status).toBe(200);
        expect((await get(`/t/group/${groupG}`, asCarol())).status).toBe(200);
        expect((await get(`/t/group/${groupG}`, asBob())).status).toBe(404); // linked to alice, but not in the group
        expect((await get(`/t/group/${groupG}`, asDave())).status).toBe(404);
      });

      it('refuses a member the moment they are removed from the group', async () => {
        const c = db.client;
        const u = await mkUser(c, 'member');
        u.device = await mkDevice(c, u.id);
        const g = await mkGroup(c, admin.id, [u.id]);
        const who = { user: u.id, device: u.device };
        expect((await get(`/t/group/${g}`, who)).status).toBe(200);

        await c.query(
          `UPDATE group_members SET removed_at = now() WHERE group_id = $1 AND user_id = $2`,
          [g, u.id],
        );
        expect((await get(`/t/group/${g}`, who)).status).toBe(404);
      });

      it('lets only the two participants into a direct chat', async () => {
        expect((await get(`/t/chat/${chatAB}`, asAlice())).status).toBe(200);
        expect((await get(`/t/chat/${chatAB}`, asBob())).status).toBe(200);
        expect((await get(`/t/chat/${chatAB}`, asCarol())).status).toBe(404);
        expect((await get(`/t/chat/${chatAB}`, asDave())).status).toBe(404);
      });

      it('lets only live members into a group chat', async () => {
        expect((await get(`/t/chat/${chatG}`, asAlice())).status).toBe(200);
        expect((await get(`/t/chat/${chatG}`, asBob())).status).toBe(404);
      });
    });

    it('hides a deleted account from everyone who was linked to it', async () => {
      const c = db.client;
      const x = await mkUser(c, 'leaver');
      x.device = await mkDevice(c, x.id);
      await link(c, alice.id, x.id, admin.id);
      expect((await get(`/t/user/${x.id}`, asAlice())).status).toBe(200);

      await c.query(
        `UPDATE users SET status = 'deleted', deleted_at = now() WHERE id = $1`,
        [x.id],
      );
      expect((await get(`/t/user/${x.id}`, asAlice())).status).toBe(404);
    });
  });
});
