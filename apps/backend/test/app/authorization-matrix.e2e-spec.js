// Phase 12 (threat model A1, A3, A4): EVERY route of the real application,
// called by every kind of caller, with real sessions. The routes and their
// rules are read from the application itself (as the route inventory does),
// so a route added later is covered without anyone remembering to add it.
//
//   signed out                       -> 401 on every non-public route
//   a member's device, operator route -> 401 (sessions are never interchangeable)
//   an operator, member route         -> 401
//   a moderator, missing permission   -> 403
//   a member naming anything outside
//   their graph, or anything that does
//   not exist                         -> the SAME 404, body included
import crypto from 'crypto';
import request from 'supertest';
import { ModulesContainer } from '@nestjs/core';
import { createTestDatabase, mkUser, mkDevice } from '../db/harness';
import { createTestApp } from './app-harness';
import { routesOf } from './route-inventory';
import { hashPassword } from '../../src/modules/auth/admin-auth.service';
import { SessionService } from '../../src/modules/authorization/session.service';
import {
  IS_PUBLIC,
  REQUIRED_PERMISSIONS,
  GRAPH_TARGETS,
  DASHBOARD_SESSION,
} from '../../src/common/decorators/access.decorators';

const PASSWORD = 'correct horse battery staple';
const uuid = () => crypto.randomUUID();

describe('authorization matrix: every route x every kind of caller', () => {
  let db;
  let t;
  let routes;
  let member;
  let outsider;
  let foreign;
  const tokens = {};
  const api = () => request(t.app.getHttpServer());

  const call = (route, path, token) => {
    const verb = route.method.toLowerCase();
    let r = api()[verb === 'all' ? 'get' : verb](path);
    if (token) r = r.set('Authorization', `Bearer ${token}`);
    if (['post', 'put', 'patch'].includes(verb)) r = r.send({});
    return r;
  };
  const fill = (path, values = {}) => path.replace(/:([A-Za-z0-9_]+)/g, (_, p) => values[p] ?? uuid());

  const operator = async (role, owner = false) => {
    const username = `${role}-matrix-${crypto.randomBytes(3).toString('hex')}`;
    const { rows } = await db.client.query(
      `INSERT INTO users (username, display_name, role_key, status, is_owner)
       VALUES ($1, $4, $2, 'active', $3) RETURNING id`,
      [username, role, owner, username],
    );
    await db.client.query('INSERT INTO admin_credentials (user_id, password_hash) VALUES ($1, $2)', [
      rows[0].id,
      await hashPassword(PASSWORD),
    ]);
    const login = await api().post('/admin/auth/login').send({ username, password: PASSWORD });
    expect(login.status).toBe(200);
    return login.body.token;
  };
  const deviceToken = async (deviceId) =>
    db.client.query('BEGIN').then(async () => {
      const s = await t.app.get(SessionService).createDeviceSession(db.client, deviceId);
      await db.client.query('COMMIT');
      return s.accessToken;
    });

  beforeAll(async () => {
    db = await createTestDatabase('matrix');
    t = await createTestApp({ db, realAuth: true });
    routes = [...t.app.get(ModulesContainer).values()]
      .flatMap((m) => [...m.controllers.values()].map((w) => w.metatype))
      .flatMap(routesOf)
      .map((r) => {
        const on = [r.handler, r.controller];
        const get = (key) => Reflect.getMetadata(key, r.handler) ?? Reflect.getMetadata(key, r.controller);
        return {
          ...r,
          public: !!get(IS_PUBLIC),
          perms: get(REQUIRED_PERMISSIONS) ?? [],
          targets: Reflect.getMetadata(GRAPH_TARGETS, r.handler) ?? [],
          operator: (get(REQUIRED_PERMISSIONS) ?? []).length > 0 || !!get(DASHBOARD_SESSION),
          on,
        };
      });

    // The caller, and someone they are NOT linked to, with everything that
    // person owns: a device, a group, an upload in progress and a stored file.
    member = (await mkUser(db.client, 'caller')).id;
    const memberDevice = await mkDevice(db.client, member);
    outsider = (await mkUser(db.client, 'outsider')).id;
    const outsiderDevice = await mkDevice(db.client, outsider);
    const group = (
      await db.client.query(`INSERT INTO groups (name, created_by) VALUES ('Private', $1) RETURNING id`, [outsider])
    ).rows[0].id;
    await db.client.query('INSERT INTO group_members (group_id, user_id, added_by) VALUES ($1, $2, $2)', [group, outsider]);
    const upload = (
      await db.client.query(
        `INSERT INTO attachments (storage_key, ciphertext_bytes, ciphertext_sha256, uploaded_by_device_id)
         VALUES ($1, 100, decode(repeat('00', 32), 'hex'), $2) RETURNING id`,
        [uuid(), outsiderDevice],
      )
    ).rows[0].id;
    const stored = (
      await db.client.query(
        `INSERT INTO attachments (storage_key, ciphertext_bytes, ciphertext_sha256, uploaded_by_device_id, status)
         VALUES ($1, 100, decode(repeat('00', 32), 'hex'), $2, 'ready') RETURNING id`,
        [uuid(), outsiderDevice],
      )
    ).rows[0].id;
    foreign = { userId: outsider, groupId: group, deviceId: outsiderDevice, upload, stored };

    tokens.member = await deviceToken(memberDevice);
    tokens.moderator = await operator('moderator');
    tokens.admin = await operator('admin');
  }, 120000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  it('covers a real number of routes, so a pass is not vacuous', () => {
    expect(routes.filter((r) => !r.public).length).toBeGreaterThan(50);
    expect(routes.filter((r) => r.operator).length).toBeGreaterThan(25);
    expect(routes.filter((r) => r.targets.length).length).toBeGreaterThan(10);
  });

  it('answers 401 to a signed-out caller on every route that is not public', async () => {
    const wrong = [];
    for (const r of routes.filter((x) => !x.public)) {
      const res = await call(r, fill(r.path));
      if (res.status !== 401) wrong.push(`${r.method} ${r.path} -> ${res.status}`);
    }
    expect(wrong).toEqual([]);
  });

  it("answers 401 to a member's device on every operator route, and to an operator on every member route", async () => {
    const wrong = [];
    for (const r of routes.filter((x) => !x.public)) {
      const token = r.operator ? tokens.member : tokens.admin;
      const res = await call(r, fill(r.path), token);
      if (res.status !== 401) wrong.push(`${r.method} ${r.path} -> ${res.status}`);
    }
    expect(wrong).toEqual([]);
  });

  it('answers 403 to a moderator on every route needing a permission moderators do not hold', async () => {
    const { rows } = await db.client.query(`SELECT permission_key FROM role_permissions WHERE role_key = 'moderator'`);
    const held = new Set(rows.map((x) => x.permission_key));
    const gated = routes.filter((r) => r.perms.length && !r.perms.every((p) => held.has(p)));
    expect(gated.length).toBeGreaterThan(5);
    const wrong = [];
    for (const r of gated) {
      const res = await call(r, fill(r.path), tokens.moderator);
      if (res.status !== 403) wrong.push(`${r.method} ${r.path} -> ${res.status}`);
    }
    expect(wrong).toEqual([]);
  });

  it("answers the SAME 404 when a member names someone else's things or things that do not exist", async () => {
    const wrong = [];
    const valueFor = {
      user: foreign.userId,
      group: foreign.groupId,
      chat: uuid(),
      'own-device': foreign.deviceId,
      'own-upload': foreign.upload,
      attachment: foreign.stored,
    };
    for (const r of routes.filter((x) => !x.public && !x.operator && x.targets.length)) {
      const theirs = Object.fromEntries(r.targets.map((g) => [g.param, valueFor[g.kind]]));
      const a = await call(r, fill(r.path, theirs), tokens.member);
      const b = await call(r, fill(r.path), tokens.member);
      if (a.status !== 404 || b.status !== 404 || JSON.stringify(a.body) !== JSON.stringify(b.body)) {
        wrong.push(`${r.method} ${r.path} -> theirs ${a.status}, nonexistent ${b.status}`);
      }
    }
    expect(wrong).toEqual([]);
  });
});
