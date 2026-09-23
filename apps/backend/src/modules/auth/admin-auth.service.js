import argon2 from 'argon2';
import { generateSecret, generateURI, verify as verifyTotp } from 'otplib';
import {
  Injectable,
  Dependencies,
  UnauthorizedException,
  BadRequestException,
  ConflictException,
  Logger,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DatabaseService } from '../../database/database.service';
import { AuditService } from '../audit/audit.service';
import { SessionService } from '../authorization/session.service';
import { seal, open, deriveKey } from './auth-crypto';

// Argon2id with the library defaults (64 MiB, 3 passes, 4 lanes): slow enough
// that a stolen password table is expensive to attack.
export const hashPassword = (password) =>
  argon2.hash(password, { type: argon2.argon2id });

// Operator sign-in to the web dashboard: a password, plus an authenticator-app
// code for admins who have turned two-factor on (optional, by the owner's
// choice; see decisions.md). Members never have a password.
@Injectable()
@Dependencies(DatabaseService, ConfigService, AuditService, SessionService)
export class AdminAuthService {
  constructor(db, config, audit, sessions) {
    this.db = db;
    this.audit = audit;
    this.sessions = sessions;
    this.totpKey = deriveKey(config.get('auth.totpKey'), 'totp');
    this.logger = new Logger('AdminAuth');
    this.dummyHash = null;
  }

  // ----------------------------------------------------------------- sign in

  async login({ username, password }, ip) {
    const { rows } = await this.db.query(
      `SELECT u.id, u.status, c.password_hash, c.totp_enabled_at
         FROM users u
         JOIN admin_credentials c ON c.user_id = u.id
         JOIN role_permissions rp ON rp.role_key = u.role_key AND rp.permission_key = 'dashboard.access'
        WHERE u.username = $1`,
      [username],
    );
    const account = rows[0];

    // An unknown username still pays for a full Argon2 verification, so the
    // response time does not reveal which usernames are operators.
    const passwordOk = account
      ? await argon2.verify(account.password_hash, password)
      : await this.burnTime(password);

    if (!account || !passwordOk || account.status !== 'active') {
      if (account) {
        await this.audit.record({
          action: 'admin_auth.login_failed',
          target: { userId: account.id },
          ip,
        });
      }
      throw new UnauthorizedException();
    }

    if (account.totp_enabled_at) {
      const pending = await this.sessions.createDashboardSession(
        account.id,
        'pending_mfa',
      );
      return {
        mfaRequired: true,
        mfaToken: pending.token,
        expiresAt: pending.expiresAt,
      };
    }

    const session = await this.sessions.createDashboardSession(account.id);
    await this.audit.record({
      action: 'admin_auth.login',
      actor: { userId: account.id },
      ip,
      detail: { twoFactor: false },
    });
    return {
      mfaRequired: false,
      token: session.token,
      expiresAt: session.expiresAt,
    };
  }

  async completeMfa({ mfaToken, code }, ip) {
    return this.db.transaction(async (client) => {
      const pending = await this.sessions.findMfaPending(client, mfaToken);
      if (!pending) throw new UnauthorizedException();

      const creds = await this.lockCredentials(client, pending.user_id);
      const status = await client.query(
        'SELECT status FROM users WHERE id = $1',
        [pending.user_id],
      );
      if (
        !creds ||
        !creds.totp_enabled_at ||
        status.rows[0]?.status !== 'active'
      ) {
        throw new UnauthorizedException();
      }

      const step = await this.checkCode(creds, code);
      if (step === null) {
        // Written OUTSIDE this transaction (no client), because the throw below
        // rolls the transaction back and would take the record of the failed
        // attempt with it.
        await this.audit.record({
          action: 'admin_auth.login_failed',
          target: { userId: pending.user_id },
          ip,
          detail: { stage: 'two_factor' },
        });
        throw new UnauthorizedException();
      }

      await client.query(
        'UPDATE admin_credentials SET totp_last_step = $2 WHERE user_id = $1',
        [pending.user_id, step],
      );
      // The pending token is spent, and a fresh token is issued rather than
      // upgrading the old one, so nothing that saw the pending token can use it.
      await this.sessions.revokeDashboardSession(pending.id, client);
      const session = await this.sessions.createDashboardSession(
        pending.user_id,
        'active',
        client,
      );
      await this.audit.record(
        {
          action: 'admin_auth.login',
          actor: { userId: pending.user_id },
          ip,
          detail: { twoFactor: true },
        },
        client,
      );
      return { token: session.token, expiresAt: session.expiresAt };
    });
  }

  async logout(sessionId) {
    if (sessionId) await this.sessions.revokeDashboardSession(sessionId);
  }

  async me(userId) {
    const { rows } = await this.db.query(
      `SELECT u.id, u.username::text AS username, u.display_name, u.role_key,
              c.totp_enabled_at IS NOT NULL AS two_factor_enabled,
              u.is_owner, c.must_change_password
         FROM users u JOIN admin_credentials c ON c.user_id = u.id
        WHERE u.id = $1`,
      [userId],
    );
    const r = rows[0];
    return {
      userId: r.id,
      username: r.username,
      displayName: r.display_name,
      role: r.role_key,
      twoFactorEnabled: r.two_factor_enabled,
      isOwner: r.is_owner,
      mustChangePassword: r.must_change_password,
    };
  }

  // ------------------------------------------------------------ two-factor

  // Step 1: a new secret, stored encrypted but not yet active. The admin adds
  // it to an authenticator app, then proves it works with enableTwoFactor.
  async beginTwoFactorSetup(userId) {
    const { rows } = await this.db.query(
      `SELECT u.username::text AS username, c.totp_enabled_at
         FROM users u JOIN admin_credentials c ON c.user_id = u.id WHERE u.id = $1`,
      [userId],
    );
    if (!rows[0]) throw new UnauthorizedException();
    if (rows[0].totp_enabled_at) throw new ConflictException();

    const secret = generateSecret();
    await this.db.query(
      'UPDATE admin_credentials SET totp_secret_enc = $2 WHERE user_id = $1',
      [userId, seal(this.totpKey, Buffer.from(secret, 'utf8'))],
    );
    return {
      secret,
      otpauthUri: generateURI({
        issuer: 'Skyline',
        label: rows[0].username,
        secret,
      }),
    };
  }

  async enableTwoFactor(userId, { code }, ip) {
    await this.db.transaction(async (client) => {
      const creds = await this.lockCredentials(client, userId);
      if (!creds || creds.totp_enabled_at || !creds.totp_secret_enc)
        throw new ConflictException();
      const step = await this.checkCode(creds, code);
      if (step === null) throw new BadRequestException();

      await client.query(
        `UPDATE admin_credentials SET totp_enabled_at = now(), totp_last_step = $2 WHERE user_id = $1`,
        [userId, step],
      );
      await this.audit.record(
        { action: 'admin_auth.two_factor_enable', actor: { userId }, ip },
        client,
      );
    });
  }

  // Needs BOTH the password and a current code, so a hijacked session alone
  // cannot switch two-factor off.
  async disableTwoFactor(userId, { password, code }, ip) {
    await this.db.transaction(async (client) => {
      const creds = await this.lockCredentials(client, userId);
      if (!creds || !creds.totp_enabled_at) throw new ConflictException();
      const passwordOk = await argon2.verify(creds.password_hash, password);
      const step = await this.checkCode(creds, code);
      if (!passwordOk || step === null) throw new BadRequestException();

      await client.query(
        `UPDATE admin_credentials
            SET totp_enabled_at = NULL, totp_secret_enc = NULL, totp_last_step = NULL
          WHERE user_id = $1`,
        [userId],
      );
      await this.audit.record(
        { action: 'admin_auth.two_factor_disable', actor: { userId }, ip },
        client,
      );
    });
  }

  // Changing the password signs out every other dashboard session, which is
  // what an admin who suspects a leak needs to happen.
  async changePassword(
    userId,
    currentSessionId,
    { currentPassword, newPassword },
    ip,
  ) {
    await this.db.transaction(async (client) => {
      const creds = await this.lockCredentials(client, userId);
      if (
        !creds ||
        !(await argon2.verify(creds.password_hash, currentPassword))
      ) {
        throw new BadRequestException();
      }
      await client.query(
        `UPDATE admin_credentials
            SET password_hash = $2, password_changed_at = now(), must_change_password = false
          WHERE user_id = $1`,
        [userId, await hashPassword(newPassword)],
      );
      await this.sessions.revokeOtherDashboardSessions(
        userId,
        currentSessionId,
        client,
      );
      await this.audit.record(
        { action: 'admin_auth.password_change', actor: { userId }, ip },
        client,
      );
    });
  }

  // -------------------------------------------------------------- helpers

  async lockCredentials(client, userId) {
    const { rows } = await client.query(
      `SELECT password_hash, totp_secret_enc, totp_enabled_at, totp_last_step
         FROM admin_credentials WHERE user_id = $1 FOR UPDATE`,
      [userId],
    );
    return rows[0] || null;
  }

  // The accepted time step, or null. A code already used is rejected
  // (afterTimeStep), so an observed code cannot be replayed within its window.
  async checkCode(creds, code) {
    if (
      !creds.totp_secret_enc ||
      typeof code !== 'string' ||
      !/^\d{6}$/.test(code)
    )
      return null;
    try {
      const secret = open(this.totpKey, creds.totp_secret_enc).toString('utf8');
      const result = await verifyTotp({
        secret,
        token: code,
        epochTolerance: 30,
        ...(creds.totp_last_step != null
          ? { afterTimeStep: Number(creds.totp_last_step) }
          : {}),
      });
      return result.valid ? result.timeStep : null;
    } catch (err) {
      // A secret that no longer decrypts means AUTH_TOTP_KEY changed.
      this.logger.warn(`two-factor check failed: ${err.message}`);
      return null;
    }
  }

  async burnTime(password) {
    if (!this.dummyHash)
      this.dummyHash = await hashPassword('skyline-timing-equaliser');
    await argon2.verify(this.dummyHash, password);
    return false;
  }
}
