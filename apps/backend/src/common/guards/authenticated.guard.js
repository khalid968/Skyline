import {
  Injectable,
  Dependencies,
  UnauthorizedException,
  ForbiddenException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import {
  IS_PUBLIC,
  REQUIRED_PERMISSIONS,
  DASHBOARD_SESSION,
} from '../decorators/access.decorators';
import { AccountService } from '../../modules/authorization/account.service';
import { SessionService } from '../../modules/authorization/session.service';
import {
  readSessionCookie,
  isDashboardClient,
} from '../../modules/auth/dashboard-cookie';

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

// Global default-deny. Every route needs an authenticated, currently-active
// account unless it is explicitly marked @Public().
//
// 1. Who is calling: the bearer token is looked up in Postgres (SessionService)
//    and becomes `request.principal`.
// 2. Is it the right KIND of session for this route:
//      operator route (@RequirePermission or @DashboardSession) -> dashboard session only
//      every other route (member route)                           -> device session only
//    So an admin's phone cannot call operator APIs, and a dashboard login
//    cannot impersonate a member in the app.
// 3. Is that account still allowed in, right now: re-checked against the
//    database on EVERY request, so suspending a user, revoking a device, or
//    removing someone's dashboard access takes effect on their next call.
//
// Every refusal is the same 401, whatever the reason.
@Injectable()
@Dependencies(Reflector, AccountService, SessionService)
export class AuthenticatedGuard {
  constructor(reflector, accounts, sessions) {
    this.reflector = reflector;
    this.accounts = accounts;
    this.sessions = sessions;
  }

  async canActivate(context) {
    if (context.getType() !== 'http') return true; // WebSockets authenticate on connect

    const targets = [context.getHandler(), context.getClass()];
    if (this.reflector.getAllAndOverride(IS_PUBLIC, targets)) return true;

    const req = context.switchToHttp().getRequest();
    const principal = req.principal || (await this.fromRequest(req));
    if (!principal) throw new UnauthorizedException();
    req.principal = principal;

    // CSRF: a request authenticated by the browser's cookie must prove it came
    // from the dashboard's own code, via a header another site cannot set.
    if (
      principal.viaCookie &&
      !SAFE_METHODS.has(req.method) &&
      !isDashboardClient(req)
    ) {
      throw new ForbiddenException();
    }

    const perms = this.reflector.getAllAndOverride(
      REQUIRED_PERMISSIONS,
      targets,
    );
    const operatorRoute =
      (perms && perms.length > 0) ||
      !!this.reflector.getAllAndOverride(DASHBOARD_SESSION, targets);

    let account = null;
    if (operatorRoute && principal.kind === 'dashboard') {
      account = await this.accounts.loadActiveOperator(principal.userId);
    } else if (!operatorRoute && principal.kind === 'device') {
      account = await this.accounts.loadActive(
        principal.userId,
        principal.deviceId,
      );
    }
    if (!account) throw new UnauthorizedException();

    // An operator using a password someone else chose (a new admin, or a reset
    // by the owner) may reach only their own account settings until they pick
    // their own. Those routes are the @DashboardSession ones.
    const ownAccountRoute = !!this.reflector.getAllAndOverride(
      DASHBOARD_SESSION,
      targets,
    );
    if (account.mustChangePassword && !ownAccountRoute)
      throw new ForbiddenException();

    req.account = { ...account, sessionId: principal.sessionId };
    return true;
  }

  // A bearer token (apps, scripts, tests), else the dashboard's session
  // cookie. The cookie can only ever carry a dashboard session.
  async fromRequest(req) {
    const header = req.headers.authorization;
    if (typeof header === 'string' && header.startsWith('Bearer ')) {
      const token = header.slice('Bearer '.length).trim();
      return (
        (await this.sessions.resolveDeviceAccess(token)) ||
        this.sessions.resolveDashboard(token)
      );
    }
    const cookie = readSessionCookie(req);
    if (!cookie) return null;
    const principal = await this.sessions.resolveDashboard(cookie);
    return principal ? { ...principal, viaCookie: true } : null;
  }
}
