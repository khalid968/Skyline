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
  Res,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  Public,
  DashboardSession,
} from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit';
import { AdminAuthService } from './admin-auth.service';
import {
  isDashboardClient,
  setSessionCookie,
  clearSessionCookie,
} from './dashboard-cookie';
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
@Dependencies(AdminAuthService, ConfigService)
export class AdminAuthController {
  constructor(auth, config) {
    this.auth = auth;
    // Browsers accept Secure cookies on http://localhost, so this is only
    // relaxed outside production for other development hosts.
    this.secureCookie = config.get('env') === 'production';
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
  @Bind(Body(), Ip(), Req(), Res({ passthrough: true }))
  @Validated(AdminLoginDto)
  async login(dto, ip, req, res) {
    return this.deliver(await this.auth.login(dto, ip), req, res);
  }

  // Second step, for admins who turned two-factor on.
  @Public()
  @Post('mfa')
  @HttpCode(200)
  @RateLimit('admin-mfa', [{ by: 'ip', limit: 20, windowSec: FIFTEEN_MIN }])
  @Bind(Body(), Ip(), Req(), Res({ passthrough: true }))
  @Validated(MfaDto)
  async mfa(dto, ip, req, res) {
    return this.deliver(
      { mfaRequired: false, ...(await this.auth.completeMfa(dto, ip)) },
      req,
      res,
    );
  }

  @DashboardSession()
  @Post('logout')
  @HttpCode(204)
  @Bind(Req(), Res({ passthrough: true }))
  async logout(req, res) {
    clearSessionCookie(res, this.secureCookie);
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

  // The dashboard gets its session as an HttpOnly cookie and never sees the
  // token itself. Other clients (scripts, tests, the CLI guide) get the token in
  // the body and send it as a Bearer header.
  deliver(result, req, res) {
    if (result.mfaRequired || !isDashboardClient(req)) return result;
    setSessionCookie(res, result.token, result.expiresAt, this.secureCookie);
    const { token, ...rest } = result;
    return rest;
  }
}
