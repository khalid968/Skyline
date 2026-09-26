// Phase 13 (boards 41-42): the release manifest, the minimum-version gate,
// and client addresses seen through the reverse proxy.
import fs from 'fs';
import os from 'os';
import path from 'path';
import request from 'supertest';
import { createTestDatabase } from '../db/harness';
import { createTestApp } from './app-harness';
import { compareVersions, parseVersion } from '../../src/app.setup';
import { newDeviceKey, activationFields } from './device-key';

describe('releases, the minimum app version and the proxy (real app)', () => {
  let db;
  let t;
  let dir;
  const saved = {};
  const api = () => request(t.app.getHttpServer());

  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'skyline-releases-'));
    const file = path.join(dir, 'manifest.json');
    fs.writeFileSync(
      file,
      JSON.stringify({
        latest: {
          version: '1.1.0',
          notes: ['Photos open faster'],
          android: { url: '/downloads/skyline-1.1.0.apk', size: 50331648, sha256: 'ab'.repeat(32) },
        },
        minimum: '0.5.0', // ignored: the server's own setting wins
      }),
    );
    for (const [k, v] of Object.entries({ APP_MIN_VERSION: '1.0.0', APP_RELEASES_FILE: file, TRUST_PROXY: '1' })) {
      saved[k] = process.env[k];
      process.env[k] = v;
    }
    db = await createTestDatabase('releases');
    t = await createTestApp({ db, rateLimitScale: 1 });
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('publishes the latest release, and the minimum the server enforces', async () => {
    const r = await api().get('/app/releases');
    expect(r.status).toBe(200);
    expect(r.body.latest.version).toBe('1.1.0');
    expect(r.body.latest.android.url).toBe('/downloads/skyline-1.1.0.apk');
    expect(r.body.minimum).toBe('1.0.0');
  });

  it('answers 426 to an app older than the minimum, and lets current apps and the dashboard through', async () => {
    const old = await api().get('/me/inbox').set('x-skyline-app', '0.9.9+android');
    expect(old.status).toBe(426);
    expect(old.body).toMatchObject({ statusCode: 426, minimum: '1.0.0' });
    // Current and newer apps reach the normal checks (401 here: not signed in).
    expect((await api().get('/me/inbox').set('x-skyline-app', '1.0.0+windows')).status).toBe(401);
    expect((await api().get('/me/inbox').set('x-skyline-app', '2.0.0+ios')).status).toBe(401);
    // No header (the dashboard, tools): unaffected.
    expect((await api().get('/me/inbox')).status).toBe(401);
    // An old app can still learn what to install.
    expect((await api().get('/app/releases').set('x-skyline-app', '0.1.0+android')).status).toBe(200);
  });

  it("sees each client's own address through the proxy, so limits are per person, not per proxy", async () => {
    const activate = (ip) =>
      api()
        .post('/auth/activate')
        .set('X-Forwarded-For', ip)
        .send({
          code: 'SKY-00000-00000-00000-00000',
          deviceName: 'Phone',
          platform: 'android',
          ...activationFields('SKY-00000-00000-00000-00000', newDeviceKey()),
        });
    // Nine different people each get one wrong try: nobody is blocked.
    for (let i = 1; i <= 9; i++) expect((await activate(`198.51.100.${i}`)).status).not.toBe(429);
    // One address trying again and again is blocked (after 8 wrong codes).
    const statuses = [];
    for (let i = 0; i < 9; i++) statuses.push((await activate('203.0.113.7')).status);
    expect(statuses.at(-1)).toBe(429);
  });

  it('compares versions numerically', () => {
    expect(compareVersions(parseVersion('1.10.0'), parseVersion('1.9.3'))).toBeGreaterThan(0);
    expect(parseVersion('1.0')).toBeNull();
  });
});
