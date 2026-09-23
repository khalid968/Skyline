import {
  Injectable,
  Dependencies,
  BadRequestException,
  Logger,
} from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import { RateLimitService, enforceLimit } from '../../common/rate-limit/rate-limit';

// The key directory: devices publish PUBLIC prekeys here, and a device that
// wants to start an encrypted conversation fetches a bundle for each of the
// other person's devices. The server stores bytes it cannot use: every private
// key stays on its device, and libsignal on the fetching device checks every
// signature against the identity key (see migration 011 for why the server
// does not).

// Serialized libsignal public keys: a type byte, then the key.
const EC_KEY_BYTES = 33; // 0x05 + Curve25519
const EC_KEY_TYPE = 0x05;
const SIGNATURE_BYTES = 64; // XEdDSA
const KYBER_KEY_TYPES = { 0x08: 1569 }; // Kyber1024 / ML-KEM-1024

// A device may hold at most this many unclaimed one-time keys of each kind.
// Plenty for a closed community; stops one device filling the database.
export const MAX_UNCLAIMED = 500;

// How often one device may fetch bundles. Fetching claims one-time keys, so
// an unthrottled caller could drain a contact's keys and force every new
// session onto the reusable last-resort key.
const PER_TARGET = { limit: 20, windowSec: 3600 };
const PER_CALLER = { limit: 300, windowSec: 3600 };

@Injectable()
@Dependencies(DatabaseService, RateLimitService)
export class KeysService {
  constructor(db, limiter) {
    this.db = db;
    this.limiter = limiter;
    this.logger = new Logger('Keys');
  }

  // ------------------------------------------------------------- publishing

  async upload(deviceId, dto) {
    const problems = [];
    const signed = dto.signedPreKey
      ? decodeSigned(dto.signedPreKey, 'signedPreKey', problems, ecKey)
      : null;
    const lastResort = dto.lastResortKyberPreKey
      ? decodeSigned(
          dto.lastResortKyberPreKey,
          'lastResortKyberPreKey',
          problems,
          kyberKey,
        )
      : null;
    const oneTime = (dto.oneTimePreKeys || []).map((k, i) => ({
      keyId: k.keyId,
      publicKey: ecKey(k.publicKey, `oneTimePreKeys.${i}.publicKey`, problems),
    }));
    const kyber = (dto.kyberPreKeys || []).map((k, i) =>
      decodeSigned(k, `kyberPreKeys.${i}`, problems, kyberKey),
    );
    for (const [name, list] of [
      ['oneTimePreKeys', oneTime],
      ['kyberPreKeys', kyber],
    ]) {
      if (new Set(list.map((k) => k.keyId)).size !== list.length) {
        problems.push(`${name} has the same keyId twice`);
      }
    }
    if (!signed && !lastResort && !oneTime.length && !kyber.length) {
      problems.push('nothing to upload');
    }
    if (problems.length) throw new BadRequestException(problems);

    try {
      await this.db.transaction(async (client) => {
        // One upload at a time per device, so the unclaimed-key cap holds.
        await client.query('SELECT 1 FROM devices WHERE id = $1 FOR UPDATE', [
          deviceId,
        ]);

        if (signed) {
          await client.query(
            `UPDATE signed_prekeys SET superseded_at = now()
              WHERE device_id = $1 AND superseded_at IS NULL`,
            [deviceId],
          );
          await client.query(
            `INSERT INTO signed_prekeys (device_id, key_id, public_key, signature)
             VALUES ($1, $2, $3, $4)`,
            [deviceId, signed.keyId, signed.publicKey, signed.signature],
          );
        }
        if (lastResort) {
          await client.query(
            `UPDATE kyber_prekeys SET superseded_at = now()
              WHERE device_id = $1 AND last_resort AND superseded_at IS NULL`,
            [deviceId],
          );
          await client.query(
            `INSERT INTO kyber_prekeys (device_id, key_id, public_key, signature, last_resort)
             VALUES ($1, $2, $3, $4, true)`,
            [
              deviceId,
              lastResort.keyId,
              lastResort.publicKey,
              lastResort.signature,
            ],
          );
        }
        if (oneTime.length || kyber.length) {
          const counts = await this.countsWith(client, deviceId);
          if (
            counts.oneTimePreKeys + oneTime.length > MAX_UNCLAIMED ||
            counts.kyberPreKeys + kyber.length > MAX_UNCLAIMED
          ) {
            throw new BadRequestException([
              `a device may hold at most ${MAX_UNCLAIMED} unused keys of each kind`,
            ]);
          }
        }
        for (const k of oneTime) {
          await client.query(
            `INSERT INTO one_time_prekeys (device_id, key_id, public_key) VALUES ($1, $2, $3)`,
            [deviceId, k.keyId, k.publicKey],
          );
        }
        for (const k of kyber) {
          await client.query(
            `INSERT INTO kyber_prekeys (device_id, key_id, public_key, signature, last_resort)
             VALUES ($1, $2, $3, $4, false)`,
            [deviceId, k.keyId, k.publicKey, k.signature],
          );
        }
      });
    } catch (err) {
      // A key id this device already used, for a key of the same kind. Key ids
      // are the device's to choose, but never twice: a message may still
      // arrive naming the old key.
      if (err && err.code === '23505') {
        throw new BadRequestException([
          'a keyId in this upload was already used by this device',
        ]);
      }
      throw err;
    }
    return this.counts(deviceId);
  }

  counts(deviceId) {
    return this.countsWith(this.db, deviceId);
  }

  async countsWith(q, deviceId) {
    const { rows } = await q.query(
      `SELECT
         (SELECT count(*)::int FROM one_time_prekeys
           WHERE device_id = $1 AND claimed_at IS NULL) AS one_time,
         (SELECT count(*)::int FROM kyber_prekeys
           WHERE device_id = $1 AND NOT last_resort AND claimed_at IS NULL) AS kyber,
         (SELECT key_id FROM signed_prekeys
           WHERE device_id = $1 AND superseded_at IS NULL) AS signed_id,
         (SELECT created_at FROM signed_prekeys
           WHERE device_id = $1 AND superseded_at IS NULL) AS signed_at,
         (SELECT key_id FROM kyber_prekeys
           WHERE device_id = $1 AND last_resort AND superseded_at IS NULL) AS last_resort_id`,
      [deviceId],
    );
    const r = rows[0];
    return {
      oneTimePreKeys: r.one_time,
      kyberPreKeys: r.kyber,
      signedPreKey: r.signed_id
        ? { keyId: r.signed_id, createdAt: r.signed_at }
        : null,
      lastResortKyberPreKeyId: r.last_resort_id,
    };
  }

  // ---------------------------------------------------------------- fetching

  // One bundle per live, reachable device of `targetUserId`. The caller is
  // already known to be directly linked to them (the route's @ContactTarget).
  // Each one-time key handed out here is claimed for good, atomically, so two
  // callers can never receive the same one.
  async bundles(caller, targetUserId, res) {
    await enforceLimit(
      this.limiter,
      `prekey-fetch:device:${caller.deviceId}`,
      PER_CALLER,
      res,
      this.logger,
    );
    await enforceLimit(
      this.limiter,
      `prekey-fetch:pair:${caller.deviceId}:${targetUserId}`,
      PER_TARGET,
      res,
      this.logger,
    );

    return this.db.transaction(async (client) => {
      const { rows: devices } = await client.query(
        `SELECT d.id, d.device_number, d.registration_id, d.identity_key,
                s.key_id AS s_id, s.public_key AS s_key, s.signature AS s_sig
           FROM devices d
           JOIN signed_prekeys s ON s.device_id = d.id AND s.superseded_at IS NULL
          WHERE d.user_id = $1 AND d.revoked_at IS NULL
            AND d.identity_key IS NOT NULL AND d.device_number IS NOT NULL
          ORDER BY d.device_number`,
        [targetUserId],
      );

      const bundles = [];
      for (const d of devices) {
        const kyber = await claimKyber(client, d.id, caller.deviceId);
        // Without a Kyber key a session cannot be started (PQXDH needs one),
        // so a device that has not finished publishing is simply not offered.
        if (!kyber) continue;
        const oneTime = await claimOneTime(client, d.id, caller.deviceId);
        bundles.push({
          deviceNumber: d.device_number,
          registrationId: d.registration_id,
          identityKey: b64(d.identity_key),
          signedPreKey: {
            keyId: d.s_id,
            publicKey: b64(d.s_key),
            signature: b64(d.s_sig),
          },
          kyberPreKey: {
            keyId: kyber.key_id,
            publicKey: b64(kyber.public_key),
            signature: b64(kyber.signature),
          },
          preKey: oneTime
            ? { keyId: oneTime.key_id, publicKey: b64(oneTime.public_key) }
            : null,
        });
      }
      return { userId: targetUserId, devices: bundles };
    });
  }
}

// One-time Kyber key if any is left, else the reusable last-resort one.
async function claimKyber(client, deviceId, by) {
  const { rows } = await client.query(
    `UPDATE kyber_prekeys SET claimed_at = now(), claimed_by = $2
      WHERE id = (SELECT id FROM kyber_prekeys
                   WHERE device_id = $1 AND NOT last_resort AND claimed_at IS NULL
                   ORDER BY id LIMIT 1
                   FOR UPDATE SKIP LOCKED)
      RETURNING key_id, public_key, signature`,
    [deviceId, by],
  );
  if (rows[0]) return rows[0];
  const last = await client.query(
    `SELECT key_id, public_key, signature FROM kyber_prekeys
      WHERE device_id = $1 AND last_resort AND superseded_at IS NULL`,
    [deviceId],
  );
  return last.rows[0] || null;
}

async function claimOneTime(client, deviceId, by) {
  const { rows } = await client.query(
    `UPDATE one_time_prekeys SET claimed_at = now(), claimed_by = $2
      WHERE id = (SELECT id FROM one_time_prekeys
                   WHERE device_id = $1 AND claimed_at IS NULL
                   ORDER BY id LIMIT 1
                   FOR UPDATE SKIP LOCKED)
      RETURNING key_id, public_key`,
    [deviceId, by],
  );
  return rows[0] || null;
}

// ------------------------------------------------------------------ decoding

const b64 = (buf) => buf.toString('base64');

function decode(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(value))
    return null;
  return Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function ecKey(value, field, problems) {
  const buf = decode(value);
  if (!buf || buf.length !== EC_KEY_BYTES || buf[0] !== EC_KEY_TYPE) {
    problems.push(`${field} is not a serialized Curve25519 public key`);
    return null;
  }
  return buf;
}

function kyberKey(value, field, problems) {
  const buf = decode(value);
  if (!buf || KYBER_KEY_TYPES[buf[0]] !== buf.length) {
    problems.push(`${field} is not a serialized Kyber public key`);
    return null;
  }
  return buf;
}

function decodeSigned(k, field, problems, keyDecoder) {
  const publicKey = keyDecoder(k.publicKey, `${field}.publicKey`, problems);
  const signature = decode(k.signature);
  if (!signature || signature.length !== SIGNATURE_BYTES) {
    problems.push(`${field}.signature is not a 64-byte signature`);
  }
  return { keyId: k.keyId, publicKey, signature };
}
