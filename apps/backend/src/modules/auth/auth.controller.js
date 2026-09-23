import {
  Controller,
  Post,
  Bind,
  Body,
  Ip,
  Req,
  HttpCode,
  Dependencies,
  UnauthorizedException,
} from '@nestjs/common';
import { Public } from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit';
import { SessionService } from '../authorization/session.service';
import { ActivationService } from './activation.service';
import { ActivateDto, RefreshDto } from './auth.dto';

const FIFTEEN_MIN = 15 * 60;

// How a phone or desktop gets in and stays in. Members have no password: a
// one-time activation code registers the device, and from then on the device
// itself is the credential.
@Controller('auth')
@Dependencies(ActivationService, SessionService)
export class AuthController {
  constructor(activation, sessions) {
    this.activation = activation;
    this.sessions = sessions;
  }

  // Redeem an activation code. Tight limit: this is where code guessing would
  // happen (100-bit codes make it hopeless anyway; the limit makes it loud).
  @Public()
  @Post('activate')
  @RateLimit('activate', [{ by: 'ip', limit: 10, windowSec: FIFTEEN_MIN }])
  @Bind(Body(), Ip())
  @Validated(ActivateDto)
  async activate(dto, ip) {
    const r = await this.activation.activate(dto, ip);
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
