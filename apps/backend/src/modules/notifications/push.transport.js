import crypto from 'crypto';
import fs from 'fs';
import { Logger } from '@nestjs/common';

// How a wake-up actually leaves the server. The payload is ALWAYS the same
// content-free marker (decisions.md, Phase 8): no sender, no text, no chat id.
// The app wakes, pulls its inbox from Skyline and decrypts on the device.
export const WAKE_UP = { t: 'inbox' };

// Phase 14c: "a call is ringing", so a closed app can show its ringing screen.
// Still no sender, no name, no chat: only the call offer's message id, a
// random UUID the caller's app made, so the phone can find that one message in
// its inbox and decrypt who is calling itself.
export const ringPayload = (messageId) => ({ t: 'call', m: messageId });

export const PUSH_TRANSPORT = Symbol('PUSH_TRANSPORT');

// send() resolves to 'ok', 'invalid' (the token is dead: forget it) or
// 'error' (try again next time).

// No provider configured (development, or before the owner sets up Firebase):
// nothing is sent. The socket still delivers while the app is open.
export class NullTransport {
  constructor() {
    this.logger = new Logger('Push');
    this.warned = false;
  }

  async send() {
    if (!this.warned) {
      this.logger.warn(
        'push is not configured (FCM_SERVICE_ACCOUNT_FILE unset); wake-ups are skipped',
      );
      this.warned = true;
    }
    return 'error';
  }
}

// Firebase Cloud Messaging, HTTP v1, for Android. Authenticates with a Google
// service account: an RS256-signed assertion is exchanged for a short-lived
// OAuth token (Google's documented flow, no SDK). Data-only, high priority,
// so Android wakes the app even in Doze; nothing is displayed by Google.
export class FcmTransport {
  constructor(serviceAccountFile) {
    const sa = JSON.parse(fs.readFileSync(serviceAccountFile, 'utf8'));
    this.projectId = sa.project_id;
    this.clientEmail = sa.client_email;
    this.privateKey = sa.private_key;
    this.tokenUri = sa.token_uri || 'https://oauth2.googleapis.com/token';
    this.accessToken = null;
    this.expiresAt = 0;
    this.logger = new Logger('Push');
  }

  async send(provider, token, payload = WAKE_UP) {
    if (provider !== 'fcm') return 'error';
    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`,
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${await this.oauth()}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token,
            data: payload,
            // A call is over in a minute; a wake-up can wait an hour.
            android: { priority: 'high', ttl: payload.t === 'call' ? '60s' : '3600s' },
          },
        }),
      },
    );
    if (res.ok) return 'ok';
    // 404 UNREGISTERED / 400 INVALID_ARGUMENT for a bad token: forget it.
    if (res.status === 404 || res.status === 400) return 'invalid';
    this.logger.warn(`FCM refused a wake-up (${res.status})`);
    return 'error';
  }

  async oauth() {
    if (this.accessToken && Date.now() < this.expiresAt - 60_000) {
      return this.accessToken;
    }
    const now = Math.floor(Date.now() / 1000);
    const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
    const unsigned = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64({
      iss: this.clientEmail,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: this.tokenUri,
      iat: now,
      exp: now + 3600,
    })}`;
    const signature = crypto
      .sign('RSA-SHA256', Buffer.from(unsigned), this.privateKey)
      .toString('base64url');
    const res = await fetch(this.tokenUri, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: `${unsigned}.${signature}`,
      }),
    });
    if (!res.ok) throw new Error(`Google OAuth refused (${res.status})`);
    const j = await res.json();
    this.accessToken = j.access_token;
    this.expiresAt = Date.now() + j.expires_in * 1000;
    return this.accessToken;
  }
}
