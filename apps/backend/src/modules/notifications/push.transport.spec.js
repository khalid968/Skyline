import crypto from 'crypto';
import fs from 'fs';
import os from 'os';
import path from 'path';
import {
  FcmTransport,
  IOS_ALERT,
  WAKE_UP,
  ringPayload,
} from './push.transport';

// The Firebase sender against a stand-in for Google: the OAuth assertion is a
// valid RS256 JWT for the service account, and the message is data-only and
// content-free.
describe('FcmTransport', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
  });
  const file = path.join(os.tmpdir(), `sa-${process.pid}-${Date.now()}.json`);
  let calls;

  beforeAll(() => {
    fs.writeFileSync(
      file,
      JSON.stringify({
        project_id: 'skyline-test',
        client_email: 'push@skyline-test.iam.gserviceaccount.com',
        private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
        token_uri: 'https://oauth2.example/token',
      }),
    );
  });

  afterAll(() => fs.rmSync(file, { force: true }));

  beforeEach(() => {
    calls = [];
    global.fetch = jest.fn(async (url, init) => {
      calls.push({ url, init });
      if (url === 'https://oauth2.example/token') {
        return {
          ok: true,
          status: 200,
          json: async () => ({ access_token: 'ya29.test', expires_in: 3600 }),
        };
      }
      if (String(init.body).includes('dead-token'))
        return { ok: false, status: 404 };
      return { ok: true, status: 200 };
    });
  });

  it('signs a service-account assertion and sends a content-free, high-priority wake-up', async () => {
    const t = new FcmTransport(file);
    expect(await t.send('fcm', 'device-token')).toBe('ok');

    const [auth, push] = calls;
    const form = new URLSearchParams(auth.init.body.toString());
    expect(form.get('grant_type')).toBe(
      'urn:ietf:params:oauth:grant-type:jwt-bearer',
    );
    const [h, p, s] = form.get('assertion').split('.');
    expect(
      crypto.verify(
        'RSA-SHA256',
        Buffer.from(`${h}.${p}`),
        publicKey,
        Buffer.from(s, 'base64url'),
      ),
    ).toBe(true);
    const claims = JSON.parse(Buffer.from(p, 'base64url').toString());
    expect(claims).toMatchObject({
      iss: 'push@skyline-test.iam.gserviceaccount.com',
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.example/token',
    });

    expect(push.url).toBe(
      'https://fcm.googleapis.com/v1/projects/skyline-test/messages:send',
    );
    expect(push.init.headers.authorization).toBe('Bearer ya29.test');
    const body = JSON.parse(push.init.body);
    expect(body).toEqual({
      message: {
        token: 'device-token',
        data: WAKE_UP,
        android: { priority: 'high', ttl: '3600s' },
        apns: {
          headers: {
            'apns-push-type': 'alert',
            'apns-priority': '10',
            'apns-collapse-id': 'inbox',
            'apns-expiration': expect.stringMatching(/^\d+$/),
          },
          payload: { aps: { alert: IOS_ALERT.inbox, sound: 'default' } },
        },
      },
    });
    // Nothing for Android to display: it stays a data-only wake-up there.
    expect(body.message.notification).toBeUndefined();
  });

  it('gives iPhones a fixed, content-free alert, and calls a one-minute one', async () => {
    const t = new FcmTransport(file);
    const before = Math.floor(Date.now() / 1000);
    await t.send(
      'fcm',
      'phone',
      ringPayload('6f1c2a3b-0000-4000-8000-000000000001'),
    );
    const body = JSON.parse(calls.at(-1).init.body);
    expect(body.message.android.ttl).toBe('60s');
    expect(body.message.apns.payload.aps.alert).toEqual({
      title: 'Skyline',
      body: 'Incoming call',
    });
    expect(body.message.apns.headers['apns-collapse-id']).toBe('call');
    const exp = Number(body.message.apns.headers['apns-expiration']);
    expect(exp).toBeGreaterThanOrEqual(before + 60);
    expect(exp).toBeLessThanOrEqual(before + 62);
    // The alert words never change with the message: no sender, no text.
    expect(IOS_ALERT).toEqual({
      inbox: { title: 'Skyline', body: 'New message' },
      call: { title: 'Skyline', body: 'Incoming call' },
    });
  });

  it('reuses the OAuth token and reports a dead device token', async () => {
    const t = new FcmTransport(file);
    await t.send('fcm', 'a-token');
    expect(await t.send('fcm', 'dead-token')).toBe('invalid');
    expect(
      calls.filter((c) => c.url === 'https://oauth2.example/token'),
    ).toHaveLength(1);
    expect(await t.send('apns', 'x')).toBe('error');
  });
});
