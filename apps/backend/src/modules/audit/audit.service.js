import { isIP } from 'net';
import { Injectable, Dependencies } from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import { isSensitiveKey } from '../../common/logging/redact';
import { isUuid } from '../../common/uuid';

const ACTION = /^[a-z_]+\.[a-z_]+$/; // e.g. users.rename, contacts.revoke

// Writes to the append-only audit_log (migration 008). Everything an admin
// does to another person's account goes through here: renames, suspensions,
// link grants and revocations, code issuing, device revocation.
//
// The log records WHO did WHAT to WHOM and WHEN. It must never contain message
// content, keys, codes or PINs; `detail` is checked and rejected if it tries.
@Injectable()
@Dependencies(DatabaseService)
export class AuditService {
  constructor(db) {
    this.db = db;
  }

  // Pass `client` to write inside the caller's transaction, so the audit entry
  // commits or rolls back together with the change it describes. That pairing
  // matters: an admin action with no record, or a record of an action that
  // never happened, are both worse than neither.
  async record(entry, client = this.db) {
    const { action, actor = {}, target = {}, ip, detail = {} } = entry;

    if (typeof action !== 'string' || !ACTION.test(action)) {
      throw new Error(
        `audit action must look like "area.verb", got: ${JSON.stringify(action)}`,
      );
    }
    assertNoSecrets(detail);
    for (const id of [
      actor.userId,
      target.userId,
      target.groupId,
      target.deviceId,
    ]) {
      if (id != null && !isUuid(id)) throw new Error('audit ids must be uuids');
    }

    // Usernames are snapshotted at write time, so the record stays readable
    // after a rename, and the subject is looked up rather than trusted from
    // the caller.
    await client.query(
      `INSERT INTO audit_log
         (action, actor_user_id, actor_username, actor_ip,
          target_user_id, target_username, target_group_id, target_device_id, detail)
       VALUES
         ($1, $2::uuid, (SELECT username::text FROM users WHERE id = $2::uuid), $3::inet,
          $4::uuid, (SELECT username::text FROM users WHERE id = $4::uuid), $5::uuid, $6::uuid, $7::jsonb)`,
      [
        action,
        actor.userId ?? null,
        ip && isIP(ip) ? ip : null,
        target.userId ?? null,
        target.groupId ?? null,
        target.deviceId ?? null,
        JSON.stringify(detail),
      ],
    );
  }
}

// Fail loudly in development rather than quietly writing a secret to a table
// that, by design, can never be edited or deleted.
function assertNoSecrets(value, path = 'detail') {
  if (value === null || typeof value !== 'object') return;
  for (const [k, v] of Object.entries(value)) {
    if (isSensitiveKey(k)) {
      throw new Error(
        `audit ${path}.${k} looks like a secret and must not be logged`,
      );
    }
    assertNoSecrets(v, `${path}.${k}`);
  }
}
