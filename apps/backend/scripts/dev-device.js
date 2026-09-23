#!/usr/bin/env node
// A pretend phone, for trying the API by hand before the real app exists.
// DEVELOPMENT ONLY. It keeps its private key and tokens in .dev-device.json
// (gitignored), which a real device would keep in its secure keystore.
//
//   npm run dev:device -- activate SKY-XXXXX-XXXXX-XXXXX-XXXXX   register this "phone"
//   npm run dev:device -- me                                   who am I?
//   npm run dev:device -- devices                              my devices
//   npm run dev:device -- refresh                              rotate my tokens (signed)
//   npm run dev:device -- logout                               end this session
//   npm run dev:device -- forget                               delete the local state
//
// Talks to http://localhost:3000 unless SKYLINE_API is set.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const API = process.env.SKYLINE_API || 'http://localhost:3000';
const STATE = path.join(__dirname, '..', '.dev-device.json');

const load = () =>
  fs.existsSync(STATE) ? JSON.parse(fs.readFileSync(STATE, 'utf8')) : null;
const save = (s) => fs.writeFileSync(STATE, JSON.stringify(s, null, 2));

// Must match normalizeActivationCode() in src/modules/auth/auth-crypto.js.
function normalize(code) {
  let s = code.toUpperCase().replace(/[\s-]/g, '');
  if (s.length === 23 && s.startsWith('SKY')) s = s.slice(3);
  return s.replace(/O/g, '0').replace(/[IL]/g, '1');
}

async function call(method, route, { body, token } = {}) {
  const res = await fetch(API + route, {
    method,
    headers: {
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = text;
  try {
    data = JSON.parse(text);
  } catch {
    /* not JSON */
  }
  return { status: res.status, data };
}

function show({ status, data }) {
  console.log(`HTTP ${status}`);
  if (data !== '')
    console.log(
      typeof data === 'string' ? data : JSON.stringify(data, null, 2),
    );
}

function signer(state) {
  const key = crypto.createPrivateKey({ key: state.privateKey, format: 'pem' });
  return (message) =>
    crypto.sign(null, Buffer.from(message, 'utf8'), key).toString('base64');
}

const commands = {
  async activate(code) {
    if (!code) throw new Error('usage: activate SKY-XXXXX-XXXXX-XXXXX-XXXXX');
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    const state = {
      privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
    };
    const signingKey = Buffer.from(
      publicKey.export({ format: 'jwk' }).x,
      'base64url',
    ).toString('base64');

    const r = await call('POST', '/auth/activate', {
      body: {
        code,
        deviceName: 'Dev device (script)',
        platform: 'windows',
        signingKey,
        signature: signer(state)(`skyline-activate:v1:${normalize(code)}`),
      },
    });
    show({
      status: r.status,
      data:
        r.status === 201
          ? {
              userId: r.data.userId,
              deviceId: r.data.deviceId,
              tokens: '(saved to .dev-device.json)',
            }
          : r.data,
    });
    if (r.status === 201) save({ ...state, ...r.data });
  },

  async me() {
    show(await call('GET', '/me', { token: need().accessToken }));
  },

  async devices() {
    show(await call('GET', '/me/devices', { token: need().accessToken }));
  },

  async refresh() {
    const s = need();
    const timestamp = Math.floor(Date.now() / 1000);
    const r = await call('POST', '/auth/refresh', {
      body: {
        refreshToken: s.refreshToken,
        timestamp,
        signature: signer(s)(
          `skyline-refresh:v1:${timestamp}:${s.refreshToken}`,
        ),
      },
    });
    show({
      status: r.status,
      data:
        r.status === 200
          ? {
              accessExpiresAt: r.data.accessExpiresAt,
              tokens: '(rotated and saved)',
            }
          : r.data,
    });
    if (r.status === 200) save({ ...s, ...r.data });
  },

  async logout() {
    show(await call('POST', '/auth/logout', { token: need().accessToken }));
  },

  async forget() {
    if (fs.existsSync(STATE)) fs.unlinkSync(STATE);
    console.log('Local device state deleted.');
  },
};

function need() {
  const s = load();
  if (!s) throw new Error('no device yet: run "activate <code>" first');
  return s;
}

const [cmd, ...args] = process.argv.slice(2);
if (!commands[cmd]) {
  console.log(`commands: ${Object.keys(commands).join(', ')}`);
  process.exit(cmd ? 1 : 0);
}
commands[cmd](...args).catch((e) => {
  console.error(`Failed: ${e.message}`);
  process.exitCode = 1;
});
