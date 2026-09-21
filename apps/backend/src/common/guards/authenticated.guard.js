import {
  Injectable,
  Dependencies,
  UnauthorizedException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { IS_PUBLIC } from '../decorators/access.decorators';
import { AccountService } from '../../modules/authorization/account.service';

// Global default-deny. Every route needs an authenticated, currently-active
// account unless it is explicitly marked @Public().
//
// Authentication itself (turning a token into a principal) arrives in Phase 5.
// Its contract with this guard is simply: set `request.principal =
// { userId, deviceId }`. Until something does, every non-public route answers
// 401, which is the safe failure.
//
// After the principal is found, its account and device are re-checked against
// the database on EVERY request, so suspending a user or revoking a device
// takes effect on their next call, not when a token happens to expire.
@Injectable()
@Dependencies(Reflector, AccountService)
export class AuthenticatedGuard {
  constructor(reflector, accounts) {
    this.reflector = reflector;
    this.accounts = accounts;
  }

  async canActivate(context) {
    if (context.getType() !== 'http') return true; // WebSockets authenticate on connect

    const isPublic = this.reflector.getAllAndOverride(IS_PUBLIC, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const req = context.switchToHttp().getRequest();
    const principal = req.principal;
    if (!principal) throw new UnauthorizedException();

    const account = await this.accounts.loadActive(
      principal.userId,
      principal.deviceId,
    );
    if (!account) throw new UnauthorizedException();

    req.account = account;
    return true;
  }
}
