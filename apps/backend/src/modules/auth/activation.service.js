import { randomUUID } from 'crypto';
import {
  Injectable,
  Dependencies,
  UnauthorizedException,
  Logger,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DatabaseService } from '../../database/database.service';
import { AuditService } from '../audit/audit.service';
import { SessionService } from '../authorization/session.service';
import {
  normalizeActivationCode,
  hashActivationCode,
  decodeFixed,
  verifyEd25519,
  signedMessage,
} from './auth-crypto';

// A new device turns a one-time activation code into a registered device and
// its first session.
//
// Every failure, whatever the reason (malformed, unknown, spent, revoked or
// expired code, a suspended account, a bad signature, a cloned key), ends in
// the same UnauthorizedException, which the exception filter renders
// identically. A caller learns "that did not work" and nothing else.
@Injectable()
@Dependencies(DatabaseService, ConfigService, AuditService, SessionService)
export class ActivationService {
  constructor(db, config, audit, sessions) {
    this.db = db;
    this.audit = audit;
    this.sessions = sessions;
    this.pepper = Buffer.from(config.get('auth.tokenPepper'), 'utf8');
    this.logger = new Logger('Activation');
  }

  async activate(
    {
      code,
      deviceName,
      platform,
      signingKey,
      signature,
      identityKey,
      registrationId,
    },
    ip,
  ) {
    const normalized = normalizeActivationCode(code);
    const publicKey = decodeFixed(signingKey, 32);
    const sig = decodeFixed(signature, 64);
    const identity = decodeFixed(identityKey, 33);

    // The device proves it holds the private half of the key it is registering,
    // by signing the code together with its Signal identity. This happens
    // before the database is touched; failing it reveals nothing about the
    // code, since the caller controls the signature.
    if (!normalized || !publicKey || !sig || !identity || identity[0] !== 5) {
      throw new UnauthorizedException();
    }
    const message = signedMessage.activation(
      normalized,
      identity.toString('base64'),
      registrationId,
    );
    if (!verifyEd25519(publicKey, message, sig)) {
      throw new UnauthorizedException();
    }

    // The device id is chosen BEFORE the code is redeemed, because
    // redeem_activation_code() records which device spent it. The foreign key
    // is deferred to COMMIT (migration 009), so the code is claimed and the
    // device created atomically: both happen, or neither does and the code stays
    // unspent.
    const deviceId = randomUUID();
    let result;
    try {
      result = await this.db.transaction(async (client) => {
        const redeemed = await client.query(
          'SELECT redeem_activation_code($1, $2) AS user_id',
          [hashActivationCode(this.pepper, normalized), deviceId],
        );
        const userId = redeemed.rows[0].user_id;
        if (!userId) throw new RejectActivation();

        // A code issued before an account was suspended must not let it back in.
        const { rows } = await client.query(
          'SELECT status FROM users WHERE id = $1 FOR UPDATE',
          [userId],
        );
        if (!rows[0] || !['pending', 'active'].includes(rows[0].status))
          throw new RejectActivation();

        // libsignal's device number: the next one for this user, never reused
        // (the users row is locked above, so two activations cannot race).
        const next = await client.query(
          'SELECT COALESCE(max(device_number), 0) + 1 AS n FROM devices WHERE user_id = $1',
          [userId],
        );
        const deviceNumber = next.rows[0].n;
        if (deviceNumber > 127) {
          this.logger.warn(`user ${userId} has used every device number`);
          throw new RejectActivation();
        }

        await client.query(
          // system_seq starts at the newest message: a new device starts
          // empty (decisions.md, Phase 8), with no old system notices either.
          `INSERT INTO devices (id, user_id, name, platform, signing_key,
                                identity_key, registration_id, device_number, system_seq)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8,
                   (SELECT COALESCE(max(seq), 0) FROM messages))`,
          [
            deviceId,
            userId,
            deviceName,
            platform,
            publicKey,
            identity,
            registrationId,
            deviceNumber,
          ],
        );
        await client.query(
          `UPDATE users SET status = 'active' WHERE id = $1 AND status = 'pending'`,
          [userId],
        );

        const tokens = await this.sessions.createDeviceSession(
          client,
          deviceId,
        );
        await this.audit.record(
          {
            action: 'devices.activate',
            actor: { userId },
            target: { userId, deviceId },
            ip,
            detail: { platform },
          },
          client,
        );
        return { userId, deviceId, deviceNumber, ...tokens };
      });
    } catch (err) {
      if (err instanceof RejectActivation) throw new UnauthorizedException();
      // A signing key already on a live device: a cloned or replayed key.
      // An identity key already on a live device: the same.
      if (
        err &&
        err.code === '23505' &&
        ['devices_live_signing_key', 'devices_live_identity_key'].includes(
          err.constraint,
        )
      ) {
        throw new UnauthorizedException();
      }
      throw err;
    }

    this.logger.log(`device activated for user ${result.userId}`);
    return result;
  }
}

// Internal signal to abort the transaction. Never reaches a client as itself.
class RejectActivation extends Error {}
