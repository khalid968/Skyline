import {
  Controller,
  Get,
  Post,
  Bind,
  Body,
  Ip,
  Req,
  HttpCode,
  Dependencies,
} from '@nestjs/common';
import {
  Public,
  DashboardSession,
} from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit';
import { AdminAuthService } from './admin-auth.service';
import {
  AdminLoginDto,
  MfaDto,
  TwoFactorCodeDto,
  DisableTwoFactorDto,
  ChangePasswordDto,
} from './auth.dto';

const FIFTEEN_MIN = 15 * 60;

// Operator sign-in for the web dashboard (Phase 6 builds the screens). These
// routes accept only a dashboard session, never a device session.
@Controller('admin/auth')
@Dependencies(AdminAuthService)
export class AdminAuthController {
  constructor(auth) {
    this.auth = auth;
  }

  // Limited per address AND per username, so spreading guesses over many
  // addresses still cannot hammer one account.
  @Public()
  @Post('login')
  @HttpCode(200)
  @RateLimit('admin-login', [
    { by: 'ip', limit: 20, windowSec: FIFTEEN_MIN },
    { by: 'body.username', limit: 10, windowSec: FIFTEEN_MIN },
  ])
  @Bind(Body(), Ip())
  @Validated(AdminLoginDto)
  login(dto, ip) {
    return this.auth.login(dto, ip);
  }

  // Second step, for admins who turned two-factor on.
  @Public()
  @Post('mfa')
  @HttpCode(200)
  @RateLimit('admin-mfa', [{ by: 'ip', limit: 20, windowSec: FIFTEEN_MIN }])
  @Bind(Body(), Ip())
  @Validated(MfaDto)
  mfa(dto, ip) {
    return this.auth.completeMfa(dto, ip);
  }

  @DashboardSession()
  @Post('logout')
  @HttpCode(204)
  @Bind(Req())
  async logout(req) {
    await this.auth.logout(req.account.sessionId);
  }

  @DashboardSession()
  @Get('me')
  @Bind(Req())
  me(req) {
    return this.auth.me(req.account.userId);
  }

  @DashboardSession()
  @Post('two-factor/setup')
  @HttpCode(200)
  @Bind(Req())
  setupTwoFactor(req) {
    return this.auth.beginTwoFactorSetup(req.account.userId);
  }

  @DashboardSession()
  @Post('two-factor/enable')
  @HttpCode(204)
  @RateLimit('admin-2fa', [{ by: 'ip', limit: 20, windowSec: FIFTEEN_MIN }])
  @Bind(Req(), Body(), Ip())
  @Validated(undefined, TwoFactorCodeDto)
  async enableTwoFactor(req, dto, ip) {
    await this.auth.enableTwoFactor(req.account.userId, dto, ip);
  }

  @DashboardSession()
  @Post('two-factor/disable')
  @HttpCode(204)
  @RateLimit('admin-2fa', [{ by: 'ip', limit: 20, windowSec: FIFTEEN_MIN }])
  @Bind(Req(), Body(), Ip())
  @Validated(undefined, DisableTwoFactorDto)
  async disableTwoFactor(req, dto, ip) {
    await this.auth.disableTwoFactor(req.account.userId, dto, ip);
  }

  @DashboardSession()
  @Post('password')
  @HttpCode(204)
  @RateLimit('admin-password', [
    { by: 'ip', limit: 10, windowSec: FIFTEEN_MIN },
  ])
  @Bind(Req(), Body(), Ip())
  @Validated(undefined, ChangePasswordDto)
  async changePassword(req, dto, ip) {
    await this.auth.changePassword(
      req.account.userId,
      req.account.sessionId,
      dto,
      ip,
    );
  }
}
