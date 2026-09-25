import {
  Controller,
  Post,
  Bind,
  Body,
  Ip,
  Req,
  Res,
  HttpCode,
  Logger,
  Dependencies,
  UnauthorizedException,
} from '@nestjs/common';
import { Public } from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit';
import { SessionService } from '../authorization/session.service';
import { ActivationService } from './activation.service';
import { AbuseService } from '../abuse/abuse.service';
import { ActivateDto, RefreshDto } from './auth.dto';

const FIFTEEN_MIN = 15 * 60;

// How a phone or desktop gets in and stays in. Members have no password: a
// one-time activation code registers the device, and from then on the device
// itself is the credential.
@Controller('auth')
@Dependencies(ActivationService, SessionService, AbuseService)
export class AuthController {
  constructor(activation, sessions, abuse) {
    this.activation = activation;
    this.sessions = sessions;
    this.abuse = abuse;
    this.logger = new Logger('Auth');
  }

  // Redeem an activation code. Tight limit: this is where code guessing would
  // happen (100-bit codes make it hopeless anyway; the limit makes it loud).
  @Public()
  @Post('activate')
  @RateLimit('activate', [{ by: 'ip', limit: 10, windowSec: FIFTEEN_MIN }])
  //
  // Abuse detection (board 37): an address that keeps getting codes wrong is
  // blocked for an hour, and several new devices for one person raise an
  // alert. Every wrong code counts the same, so nothing here tells a spent
  // code from one that never existed.
  @Bind(Body(), Ip(), Res({ passthrough: true }))
  @Validated(ActivateDto)
  async activate(dto, ip, res) {
    await this.abuse.assertMayActivate(ip, res);
    let r;
    try {
      r = await this.activation.activate(dto, ip);
    } catch (err) {
      if (err instanceof UnauthorizedException) await this.abuse.noteActivationFailure(ip);
      throw err;
    }
    await this.abuse.noteDeviceActivated(r.userId).catch((err) =>
      this.logger.warn(`device burst check failed: ${err.message}`),
    );
    return {
      userId: r.userId,
      deviceId: r.deviceId,
      deviceNumber: r.deviceNumber,
      accessToken: r.accessToken,
      accessExpiresAt: r.accessExpiresAt,
      refreshToken: r.refreshToken,
      refreshExpiresAt: r.refreshExpiresAt,
    };
  }

  // Swap a refresh token (plus the device's signature) for a fresh pair.
  @Public()
  @Post('refresh')
  @HttpCode(200)
  @RateLimit('refresh', [{ by: 'ip', limit: 60, windowSec: FIFTEEN_MIN }])
  @Bind(Body())
  @Validated(RefreshDto)
  async refresh(dto) {
    const r = await this.sessions.refresh(dto);
    if (!r) throw new UnauthorizedException();
    return {
      accessToken: r.accessToken,
      accessExpiresAt: r.accessExpiresAt,
      refreshToken: r.refreshToken,
      refreshExpiresAt: r.refreshExpiresAt,
    };
  }

  // End THIS device's current session. The device stays registered; to remove
  // a device entirely, revoke it (POST /me/devices/:id/revoke).
  @Post('logout')
  @HttpCode(204)
  @Bind(Req())
  async logout(req) {
    if (req.account.sessionId)
      await this.sessions.revokeDeviceSession(req.account.sessionId);
  }
}
