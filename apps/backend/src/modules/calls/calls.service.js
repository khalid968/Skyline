import crypto from 'crypto';
import { Injectable, Dependencies, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { UsageService } from '../monitoring/usage.service';
import {
  RateLimitService,
  enforceLimit,
} from '../../common/rate-limit/rate-limit';

const TURN_LIMIT = { limit: 30, windowSec: 60 };

// Calls (Phase 10, decisions.md 2026-09-25). The server never sees a call: the
// offer and answer travel as ordinary Signal-encrypted messages, and the
// audio and video go device to device through the relay, encrypted end to end.
// All the server does is hand out relay credentials.
@Injectable()
@Dependencies(ConfigService, RateLimitService, UsageService)
export class CallsService {
  constructor(config, limiter, usage) {
    this.usage = usage;
    this.turn = config.get('turn');
    this.limiter = limiter;
    this.logger = new Logger('Calls');
  }

  // Short-lived credentials for the relay, in coturn's REST format: the
  // username is "<expiry>:<anything>" and the password is its HMAC-SHA1 under
  // the shared secret, so coturn can check it without asking us. The
  // "anything" is random: the relay's logs never name a person.
  async credentials(caller, res) {
    await enforceLimit(
      this.limiter,
      `turn:device:${caller.deviceId}`,
      TURN_LIMIT,
      res,
      this.logger,
    );
    // Both sides of a call fetch credentials: the overview halves this count.
    await this.usage.bump('relay_credentials');
    const expires = Math.floor(Date.now() / 1000) + this.turn.ttlSeconds;
    const username = `${expires}:${crypto.randomBytes(8).toString('hex')}`;
    const credential = crypto
      .createHmac('sha1', this.turn.secret)
      .update(username)
      .digest('base64');
    return {
      urls: this.turn.urls,
      username,
      credential,
      ttlSeconds: this.turn.ttlSeconds,
    };
  }
}
