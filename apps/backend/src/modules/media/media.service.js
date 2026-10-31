import { randomUUID } from 'crypto';
import { statfs } from 'fs/promises';
import {
  NotFoundException,
  Injectable,
  Dependencies,
  BadRequestException,
  ConflictException,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import {
  RateLimitService,
  enforceLimit,
} from '../../common/rate-limit/rate-limit';
import { StorageService } from './storage.service';
import { AbuseService } from '../abuse/abuse.service';

// Encrypted media (decisions.md 2026-09-25). The phone encrypts first; this
// service moves opaque bytes into and out of the object store in 8 MB parts,
// records who may fetch them, and deletes them 30 days later.

export const PART_SIZE = 8 * 1024 * 1024;
export const MAX_CIPHERTEXT = 2 * 1024 * 1024 * 1024 + 16;
const START_LIMIT = { limit: 120, windowSec: 3600 };
const SWEEP_EVERY_MS = 60 * 60 * 1000;

// Storage limits (owner decision 2026-10-31, security audit lead 7). One
// person may start up to 5 GB of uploads in any 24 hours, counted by the
// size declared at the start, so it holds before a byte arrives. And no
// upload starts that would leave the disk with less than 6 GB free, so the
// database, logs and backups keep working whatever anyone sends.
export const DAILY_UPLOAD_BYTES = 5 * 1024 * 1024 * 1024;
export const MIN_FREE_DISK_BYTES = 6 * 1024 * 1024 * 1024;
// An upload with no new part for this long is abandoned: the sweep removes
// it, and its parts with it.
export const IDLE_UPLOAD_HOURS = 24;

@Injectable()
@Dependencies(DatabaseService, RateLimitService, StorageService, AbuseService)
export class MediaService {
  constructor(db, limiter, storage, abuse) {
    this.abuse = abuse;
    this.db = db;
    this.limiter = limiter;
    this.storage = storage;
    this.logger = new Logger('Media');
    this.timer = null;
  }

  onModuleInit() {
    // One sweep an hour. Safe with several instances: rows are claimed with
    // SKIP LOCKED.
    this.timer = setInterval(() => {
      this.sweep().catch((err) =>
        this.logger.warn(`sweep failed: ${err.message}`),
      );
    }, SWEEP_EVERY_MS);
    this.timer.unref?.();
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
  }

  // ----------------------------------------------------------- uploading

  async start(caller, { ciphertextBytes, sha256 }, res) {
    await enforceLimit(
      this.limiter,
      `upload:device:${caller.deviceId}`,
      START_LIMIT,
      res,
      this.logger,
    );
    await this.abuse.beforeUpload(caller, res);
    const hash = decodeSha(sha256);
    if (!hash)
      throw new BadRequestException(['sha256 must be 32 bytes, base64']);
    if (
      !Number.isInteger(ciphertextBytes) ||
      ciphertextBytes < 17 ||
      ciphertextBytes > MAX_CIPHERTEXT
    ) {
      throw new BadRequestException([
        'ciphertextBytes must be between 17 bytes and 2 GB',
      ]);
    }
    // The object name says nothing: not who, not what, not which chat.
    const key = randomUUID();
    const rows = await this.db.transaction(async (client) => {
      // One start at a time per person, so two parallel starts cannot both
      // fit under the daily allowance.
      await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [
        `upload-quota:${caller.userId}`,
      ]);
      await this.assertRoomFor(client, caller, ciphertextBytes, res);
      const uploadId = await this.storage.startUpload(key);
      const inserted = await client.query(
        `INSERT INTO attachments (storage_key, ciphertext_bytes, ciphertext_sha256, uploaded_by_device_id, upload_id)
         VALUES ($1, $2, $3, $4, $5) RETURNING id, expires_at`,
        [key, ciphertextBytes, hash, caller.deviceId, uploadId],
      );
      return inserted.rows;
    });
    return {
      attachmentId: rows[0].id,
      partSize: PART_SIZE,
      parts: Math.ceil(ciphertextBytes / PART_SIZE),
      expiresAt: rows[0].expires_at,
    };
  }

  // 429 with Retry-After when this person's last 24 hours plus this file
  // pass the daily allowance; 507 when the disk would drop below the floor.
  // Uploads still in progress count against the disk as if already written.
  async assertRoomFor(client, caller, bytes, res) {
    const { rows } = await client.query(
      `SELECT a.ciphertext_bytes, a.created_at
         FROM attachments a JOIN devices d ON d.id = a.uploaded_by_device_id
        WHERE d.user_id = $1 AND a.created_at > now() - interval '24 hours'
        ORDER BY a.created_at`,
      [caller.userId],
    );
    let used = rows.reduce((n, r) => n + Number(r.ciphertext_bytes), 0);
    if (used + bytes > DAILY_UPLOAD_BYTES) {
      // Free again once enough of the oldest uploads leave the window.
      let freedAt = Date.now() + 24 * 3600 * 1000;
      for (const r of rows) {
        used -= Number(r.ciphertext_bytes);
        if (used + bytes <= DAILY_UPLOAD_BYTES) {
          freedAt = new Date(r.created_at).getTime() + 24 * 3600 * 1000;
          break;
        }
      }
      res?.setHeader?.(
        'Retry-After',
        String(Math.max(1, Math.ceil((freedAt - Date.now()) / 1000))),
      );
      throw new HttpException('Too Many Requests', HttpStatus.TOO_MANY_REQUESTS);
    }
    const free = await this.freeDiskBytes();
    if (free === null) return;
    const pending = await client.query(
      `SELECT coalesce(sum(a.ciphertext_bytes - coalesce(p.bytes, 0)), 0)::bigint AS n
         FROM attachments a
         LEFT JOIN (SELECT attachment_id, sum(bytes) AS bytes FROM attachment_parts GROUP BY attachment_id) p
                ON p.attachment_id = a.id
        WHERE a.status = 'uploading'`,
    );
    if (free - Number(pending.rows[0].n) - bytes < MIN_FREE_DISK_BYTES) {
      this.logger.warn('upload refused: the disk is nearly full');
      throw new HttpException('Insufficient Storage', HttpStatus.INSUFFICIENT_STORAGE);
    }
  }

  // Free space on the disk the object store writes to. In production every
  // container and volume shares the server's one disk, so the backend's own
  // root tells the truth. null when it cannot be read (logged): the daily
  // allowance still applies.
  async freeDiskBytes() {
    try {
      const s = await statfs('/');
      return Number(s.bavail) * Number(s.bsize);
    } catch (err) {
      this.logger.warn(`could not read free disk space: ${err.message}`);
      return null;
    }
  }

  async progress(attachmentId) {
    const a = await this.row(attachmentId);
    const { rows } = await this.db.query(
      'SELECT part_number FROM attachment_parts WHERE attachment_id = $1 ORDER BY part_number',
      [attachmentId],
    );
    return {
      partSize: PART_SIZE,
      parts: Math.ceil(Number(a.ciphertext_bytes) / PART_SIZE),
      done: rows.map((r) => r.part_number),
    };
  }

  async putPart(attachmentId, partNumber, body) {
    const a = await this.row(attachmentId);
    const total = Number(a.ciphertext_bytes);
    const parts = Math.ceil(total / PART_SIZE);
    if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > parts) {
      throw new BadRequestException([`part must be between 1 and ${parts}`]);
    }
    const expected =
      partNumber < parts ? PART_SIZE : total - (parts - 1) * PART_SIZE;
    if (!Buffer.isBuffer(body) || body.length !== expected) {
      throw new BadRequestException([
        `part ${partNumber} must be exactly ${expected} bytes`,
      ]);
    }
    const etag = await this.storage.uploadPart(
      a.storage_key,
      a.upload_id,
      partNumber,
      body,
    );
    await this.db.query(
      `INSERT INTO attachment_parts (attachment_id, part_number, etag, bytes) VALUES ($1, $2, $3, $4)
       ON CONFLICT (attachment_id, part_number) DO UPDATE SET etag = excluded.etag, bytes = excluded.bytes,
                                                             uploaded_at = now()`,
      [attachmentId, partNumber, etag, body.length],
    );
  }

  async complete(attachmentId) {
    const a = await this.row(attachmentId);
    const { rows } = await this.db.query(
      'SELECT part_number, etag, bytes FROM attachment_parts WHERE attachment_id = $1 ORDER BY part_number',
      [attachmentId],
    );
    const parts = Math.ceil(Number(a.ciphertext_bytes) / PART_SIZE);
    const sum = rows.reduce((n, r) => n + r.bytes, 0);
    if (rows.length !== parts || sum !== Number(a.ciphertext_bytes)) {
      throw new ConflictException();
    }
    await this.storage.completeUpload(a.storage_key, a.upload_id, rows);
    await this.db.query(
      `UPDATE attachments SET status = 'ready', upload_id = NULL WHERE id = $1 AND status = 'uploading'`,
      [attachmentId],
    );
    return { attachmentId, ready: true };
  }

  async row(attachmentId) {
    const { rows } = await this.db.query(
      'SELECT * FROM attachments WHERE id = $1',
      [attachmentId],
    );
    return rows[0];
  }

  // --------------------------------------------------------- downloading

  // Streams the ciphertext. Supports a single byte Range so a 2 GB download
  // can resume. Authorisation already happened (@AttachmentTarget).
  async download(attachmentId, rangeHeader, res) {
    const a = await this.row(attachmentId);
    const total = Number(a.ciphertext_bytes);
    let range;
    let start = 0;
    let end = total - 1;
    if (typeof rangeHeader === 'string') {
      const m = /^bytes=(\d+)-(\d*)$/.exec(rangeHeader.trim());
      if (!m || Number(m[1]) >= total) {
        res.status(416).setHeader('Content-Range', `bytes */${total}`);
        return res.end();
      }
      start = Number(m[1]);
      end = m[2] ? Math.min(Number(m[2]), total - 1) : total - 1;
      range = `bytes=${start}-${end}`;
    }
    const obj = await this.storage.read(a.storage_key, range);
    res.status(range ? 206 : 200);
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Length', String(end - start + 1));
    res.setHeader('Accept-Ranges', 'bytes');
    res.setHeader('Cache-Control', 'no-store');
    if (range) res.setHeader('Content-Range', `bytes ${start}-${end}/${total}`);
    obj.body.pipe(res);
  }

  // ------------------------------------------------------ profile photos

  // Phase 14d (board 46): this finished upload of the caller's is now their
  // profile photo. It must be theirs, ready, and not sent in any message. The
  // previous photo expires at once (the sweep deletes its blob).
  async setProfilePhoto(caller, attachmentId) {
    await this.db.transaction(async (client) => {
      // One photo change at a time per person: without this lock two
      // concurrent changes both expired the same old photo, and the loser's
      // upload stayed 'infinity' with nothing pointing at it, so the sweep
      // never deleted it (security audit 2026-10-30).
      await this.lockPhotoOwner(client, caller.userId);
      const { rowCount } = await client.query(
        `UPDATE attachments a SET kind = 'profile', expires_at = 'infinity'
           FROM devices d
          WHERE a.id = $1 AND a.status = 'ready' AND a.message_id IS NULL AND a.kind = 'message'
            AND d.id = a.uploaded_by_device_id AND d.user_id = $2`,
        [attachmentId, caller.userId],
      );
      if (rowCount !== 1) throw new NotFoundException();
      await this.expireProfilePhoto(client, caller.userId);
      await client.query('UPDATE users SET photo_attachment_id = $1 WHERE id = $2', [
        attachmentId,
        caller.userId,
      ]);
    });
  }

  async clearProfilePhoto(caller) {
    await this.db.transaction(async (client) => {
      await this.lockPhotoOwner(client, caller.userId);
      await this.expireProfilePhoto(client, caller.userId);
      await client.query('UPDATE users SET photo_attachment_id = NULL WHERE id = $1', [caller.userId]);
    });
  }

  async lockPhotoOwner(client, userId) {
    await client.query('SELECT 1 FROM users WHERE id = $1 FOR UPDATE', [
      userId,
    ]);
  }

  async expireProfilePhoto(client, userId) {
    await client.query(
      `UPDATE attachments SET expires_at = now()
        WHERE id = (SELECT photo_attachment_id FROM users WHERE id = $1)`,
      [userId],
    );
  }

  // ------------------------------------------------------------ claiming

  // Called inside the message-send transaction: the message now carries these
  // files, which must be this person's, finished, and not yet claimed.
  async claim(client, caller, messageId, attachmentIds) {
    if (!attachmentIds || attachmentIds.length === 0) return;
    const { rowCount } = await client.query(
      `UPDATE attachments a SET message_id = $1
         FROM devices d
        WHERE a.id = ANY($2::uuid[]) AND a.message_id IS NULL AND a.status = 'ready'
          AND a.kind = 'message'
          AND d.id = a.uploaded_by_device_id AND d.user_id = $3`,
      [messageId, attachmentIds, caller.userId],
    );
    if (rowCount !== new Set(attachmentIds).size) {
      throw new BadRequestException([
        'an attachment is not ready, not yours, or already sent',
      ]);
    }
  }

  // ------------------------------------------------------------ retention

  // Deletes every file older than 30 days, and uploads idle for 24 hours, for good.
  // A profile photo that no person points at any more is deleted too, whatever
  // its expiry: only the CURRENT photo is kept indefinitely.
  async sweep(limit = 100) {
    let removed = 0;
    for (;;) {
      const batch = await this.db.transaction(async (client) => {
        const { rows } = await client.query(
          `SELECT id, storage_key, upload_id, status FROM attachments
            WHERE status <> 'deleted'
              AND (expires_at <= now()
                   OR (status = 'uploading'
                       AND created_at < now() - make_interval(hours => $2)
                       AND NOT EXISTS (SELECT 1 FROM attachment_parts p
                                        WHERE p.attachment_id = attachments.id
                                          AND p.uploaded_at > now() - make_interval(hours => $2)))
                   OR (kind = 'profile'
                       AND NOT EXISTS (SELECT 1 FROM users u WHERE u.photo_attachment_id = attachments.id)))
            ORDER BY expires_at LIMIT $1 FOR UPDATE SKIP LOCKED`,
          [limit, IDLE_UPLOAD_HOURS],
        );
        for (const a of rows) {
          if (a.status === 'uploading' && a.upload_id) {
            await this.storage.abortUpload(a.storage_key, a.upload_id);
          } else {
            await this.storage.remove(a.storage_key);
          }
          await client.query(
            `UPDATE attachments SET status = 'deleted', deleted_at = now(), upload_id = NULL WHERE id = $1`,
            [a.id],
          );
        }
        return rows.length;
      });
      removed += batch;
      if (batch < limit) break;
    }
    if (removed) this.logger.log(`deleted ${removed} expired file(s)`);
    return removed;
  }
}

function decodeSha(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(value))
    return null;
  const b = Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  return b.length === 32 ? b : null;
}
