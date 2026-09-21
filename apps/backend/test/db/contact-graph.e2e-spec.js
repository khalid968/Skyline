// The contact graph is the product's defining invariant: a user can reach
// exactly the people and groups an administrator has linked to them, and nothing
// else. These tests exercise the database layer that the Phase 4 guard is built
// on. They must never be deleted -- see docs/architecture/contact-graph.md.
import {
  createTestDatabase,
  mkUser,
  link,
  mkGroup,
  failure,
  SQLSTATE,
} from './harness';

describe('contact graph (database layer)', () => {
  let db;
  let admin;

  beforeAll(async () => {
    db = await createTestDatabase('graph');
    admin = await mkUser(db.client, 'admin', { role: 'admin' });
  }, 60000);

  afterAll(async () => {
    await db.drop();
  });

  const visible = async (userId) => {
    const { rows } = await db.client.query(
      'SELECT user_id FROM visible_user_ids($1)',
      [userId],
    );
    return rows.map((r) => r.user_id).sort();
  };
  const linked = async (a, b) =>
    (await db.client.query('SELECT are_linked($1, $2) AS v', [a, b])).rows[0].v;

  describe('links are structurally symmetric', () => {
    it('rejects a link stored in non-canonical order, so a direction cannot be expressed', async () => {
      const a = await mkUser(db.client, 'a');
      const b = await mkUser(db.client, 'b');
      const [lo, hi] = a.id < b.id ? [a.id, b.id] : [b.id, a.id];

      const err = await failure(
        db.client.query(
          `INSERT INTO contact_links (user_a_id, user_b_id, created_by) VALUES ($1, $2, $3)`,
          [hi, lo, admin.id],
        ),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('contact_links_canonical_order');
    });

    it('rejects a user linked to themselves', async () => {
      const a = await mkUser(db.client, 'self');
      const err = await failure(
        db.client.query(
          `INSERT INTO contact_links (user_a_id, user_b_id, created_by) VALUES ($1, $1, $2)`,
          [a.id, admin.id],
        ),
      );
      expect(err.code).toBe(SQLSTATE.check);
    });

    it('allows only one live link per pair', async () => {
      const a = await mkUser(db.client, 'p');
      const b = await mkUser(db.client, 'q');
      await link(db.client, a.id, b.id, admin.id);

      const err = await failure(link(db.client, a.id, b.id, admin.id));
      expect(err.code).toBe(SQLSTATE.unique);
      expect(err.constraint).toBe('contact_links_one_live_per_pair');
    });

    it('lets a pair be revoked and granted again, keeping both rows as history', async () => {
      const a = await mkUser(db.client, 'r');
      const b = await mkUser(db.client, 's');
      const first = await link(db.client, a.id, b.id, admin.id);
      await db.client.query(
        `UPDATE contact_links SET revoked_at = now(), revoked_by = $2 WHERE id = $1`,
        [first, admin.id],
      );

      await link(db.client, a.id, b.id, admin.id);

      const { rows } = await db.client.query(
        `SELECT count(*)::int AS n FROM contact_links WHERE user_a_id = LEAST($1::uuid,$2::uuid) AND user_b_id = GREATEST($1::uuid,$2::uuid)`,
        [a.id, b.id],
      );
      expect(rows[0].n).toBe(2);
      expect(await linked(a.id, b.id)).toBe(true);
    });
  });

  describe('are_linked()', () => {
    it('is symmetric: true in both argument orders', async () => {
      const a = await mkUser(db.client, 'x');
      const b = await mkUser(db.client, 'y');
      await link(db.client, a.id, b.id, admin.id);

      expect(await linked(a.id, b.id)).toBe(true);
      expect(await linked(b.id, a.id)).toBe(true);
    });

    it('is false for two users nobody has linked', async () => {
      const a = await mkUser(db.client, 'lonely');
      const b = await mkUser(db.client, 'stranger');
      expect(await linked(a.id, b.id)).toBe(false);
      expect(await linked(b.id, a.id)).toBe(false);
    });

    it('becomes false in both directions the moment the link is revoked', async () => {
      const a = await mkUser(db.client, 'k');
      const b = await mkUser(db.client, 'l');
      const id = await link(db.client, a.id, b.id, admin.id);
      expect(await linked(a.id, b.id)).toBe(true);

      await db.client.query(
        `UPDATE contact_links SET revoked_at = now(), revoked_by = $2 WHERE id = $1`,
        [id, admin.id],
      );

      expect(await linked(a.id, b.id)).toBe(false);
      expect(await linked(b.id, a.id)).toBe(false);
    });

    it('is not fooled by a self pair', async () => {
      const a = await mkUser(db.client, 'me');
      expect(await linked(a.id, a.id)).toBe(false);
    });
  });

  describe('visible_user_ids()', () => {
    it('is EMPTY for a user with no links -- the empty app is a valid state', async () => {
      const a = await mkUser(db.client, 'newcomer');
      expect(await visible(a.id)).toEqual([]);
    });

    it('contains a linked contact from either side of the pair', async () => {
      const a = await mkUser(db.client, 'left');
      const b = await mkUser(db.client, 'right');
      await link(db.client, a.id, b.id, admin.id);

      expect(await visible(a.id)).toEqual([b.id]);
      expect(await visible(b.id)).toEqual([a.id]);
    });

    it('never reveals anyone the user is not linked to, even if others are linked to each other', async () => {
      const a = await mkUser(db.client, 'insider');
      const b = await mkUser(db.client, 'friend');
      const c = await mkUser(db.client, 'outsider');
      await link(db.client, a.id, b.id, admin.id);
      await link(db.client, b.id, c.id, admin.id); // c is a friend of a's friend

      expect(await visible(a.id)).toEqual([b.id]); // contacts are not transitive
      expect(await visible(c.id)).toEqual([b.id]);
    });

    it('never contains the user themselves', async () => {
      const a = await mkUser(db.client, 'solo');
      const b = await mkUser(db.client, 'duo');
      await link(db.client, a.id, b.id, admin.id);
      expect(await visible(a.id)).not.toContain(a.id);
    });

    it('stops listing a contact as soon as the link is revoked', async () => {
      const a = await mkUser(db.client, 'was');
      const b = await mkUser(db.client, 'gone');
      const id = await link(db.client, a.id, b.id, admin.id);
      expect(await visible(a.id)).toEqual([b.id]);

      await db.client.query(
        `UPDATE contact_links SET revoked_at = now(), revoked_by = $2 WHERE id = $1`,
        [id, admin.id],
      );

      expect(await visible(a.id)).toEqual([]);
      expect(await visible(b.id)).toEqual([]);
    });

    it('includes everyone who shares a live group, and nobody outside it', async () => {
      const a = await mkUser(db.client, 'member');
      const b = await mkUser(db.client, 'peer');
      const c = await mkUser(db.client, 'peer');
      const outside = await mkUser(db.client, 'outside');
      await mkGroup(db.client, admin.id, [a.id, b.id, c.id]);

      expect(await visible(a.id)).toEqual([b.id, c.id].sort());
      expect(await visible(outside.id)).toEqual([]);
    });

    it('drops a member from visibility once they are removed from the group', async () => {
      const a = await mkUser(db.client, 'stays');
      const b = await mkUser(db.client, 'leaves');
      const groupId = await mkGroup(db.client, admin.id, [a.id, b.id]);
      expect(await visible(a.id)).toEqual([b.id]);

      await db.client.query(
        `UPDATE group_members SET removed_at = now(), removed_by = $3 WHERE group_id = $1 AND user_id = $2`,
        [groupId, b.id, admin.id],
      );

      expect(await visible(a.id)).toEqual([]);
      expect(await visible(b.id)).toEqual([]);
    });

    it('returns each person once even when linked directly AND through a group', async () => {
      const a = await mkUser(db.client, 'dup');
      const b = await mkUser(db.client, 'dup');
      await link(db.client, a.id, b.id, admin.id);
      await mkGroup(db.client, admin.id, [a.id, b.id]);

      expect(await visible(a.id)).toEqual([b.id]);
    });
  });

  describe('group membership', () => {
    it('allows a user to be a live member of a group only once', async () => {
      const a = await mkUser(db.client, 'twice');
      const groupId = await mkGroup(db.client, admin.id, [a.id]);

      const err = await failure(
        db.client.query(
          `INSERT INTO group_members (group_id, user_id, added_by) VALUES ($1, $2, $3)`,
          [groupId, a.id, admin.id],
        ),
      );
      expect(err.code).toBe(SQLSTATE.unique);
    });
  });
});
