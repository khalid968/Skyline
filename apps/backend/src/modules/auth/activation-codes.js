import {
  generateActivationCode,
  normalizeActivationCode,
  hashActivationCode,
} from './auth-crypto';

// Issues a fresh activation code for a user. Must run inside the caller's
// transaction (`client`), so the old code's revocation, the new code and the
// audit entry land together or not at all.
//
// Returns the code in plain text. This is the ONLY moment it exists outside
// the recipient's hands: it is never stored, logged or recoverable. Show it
// once and drop it.
export async function issueActivationCode(
  client,
  { pepper, userId, issuedBy, audit },
) {
  // The schema allows one live code per user, so any outstanding code is
  // revoked first. Issuing never revives a spent code (the freeze trigger).
  await client.query(
    `UPDATE activation_codes
        SET revoked_at = now(), revoked_by = $2
      WHERE user_id = $1 AND redeemed_at IS NULL AND revoked_at IS NULL`,
    [userId, issuedBy],
  );

  const code = generateActivationCode();
  const hash = hashActivationCode(pepper, normalizeActivationCode(code));
  const { rows } = await client.query(
    `INSERT INTO activation_codes (user_id, code_hash, issued_by)
     VALUES ($1, $2, $3) RETURNING id, expires_at`,
    [userId, hash, issuedBy],
  );

  await audit.record(
    {
      action: 'codes.issue',
      actor: { userId: issuedBy },
      target: { userId },
      detail: { codeId: rows[0].id, expiresAt: rows[0].expires_at },
    },
    client,
  );

  return { code, codeId: rows[0].id, expiresAt: rows[0].expires_at };
}
