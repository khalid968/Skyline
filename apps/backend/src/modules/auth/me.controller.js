import {
  Controller,
  Get,
  Post,
  Bind,
  Param,
  Req,
  Ip,
  HttpCode,
  Dependencies,
} from '@nestjs/common';
import { OwnDeviceTarget } from '../../common/decorators/access.decorators';
import { DatabaseService } from '../../database/database.service';
import { AuditService } from '../audit/audit.service';
import { SessionService } from '../authorization/session.service';
import { ConnectionRegistry } from '../websocket/connection-registry';

// The signed-in member's own account and devices.
@Controller('me')
@Dependencies(DatabaseService, AuditService, SessionService, ConnectionRegistry)
export class MeController {
  constructor(db, audit, sessions, registry) {
    this.db = db;
    this.audit = audit;
    this.sessions = sessions;
    this.registry = registry;
  }

  @Get()
  @Bind(Req())
  async profile(req) {
    const { rows } = await this.db.query(
      'SELECT id, username::text AS username, display_name FROM users WHERE id = $1',
      [req.account.userId],
    );
    return {
      userId: rows[0].id,
      username: rows[0].username,
      displayName: rows[0].display_name,
      deviceId: req.account.deviceId,
    };
  }

  @Get('devices')
  @Bind(Req())
  async devices(req) {
    const { rows } = await this.db.query(
      `SELECT id, name, platform, created_at, last_seen_at
         FROM devices
        WHERE user_id = $1 AND revoked_at IS NULL
        ORDER BY created_at`,
      [req.account.userId],
    );
    return rows.map((d) => ({
      deviceId: d.id,
      name: d.name,
      platform: d.platform,
      createdAt: d.created_at,
      lastSeenAt: d.last_seen_at,
      current: d.id === req.account.deviceId,
    }));
  }

  // Remove one of your own devices for good: a lost phone, an old laptop. Its
  // sessions end, its socket is closed, and it would need a new activation code
  // to come back. Revoking the device you are using signs you out here.
  @Post('devices/:deviceId/revoke')
  @OwnDeviceTarget('deviceId')
  @HttpCode(204)
  @Bind(Param('deviceId'), Req(), Ip())
  async revoke(deviceId, req, ip) {
    await this.db.transaction(async (client) => {
      await client.query(
        'UPDATE devices SET revoked_at = now(), revoked_by = $2 WHERE id = $1 AND revoked_at IS NULL',
        [deviceId, req.account.userId],
      );
      await this.sessions.revokeAllDeviceSessions(deviceId, client);
      await this.audit.record(
        {
          action: 'devices.revoke',
          actor: { userId: req.account.userId },
          target: { userId: req.account.userId, deviceId },
          ip,
          detail: { by: 'owner' },
        },
        client,
      );
    });
    // Sockets on THIS instance close now; other instances are already refusing
    // every delivery to it, and their sweep closes the socket within 30s.
    this.registry.disconnectDevice(deviceId, 1008, 'revoked');
  }
}
