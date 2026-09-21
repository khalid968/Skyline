import { Injectable, Dependencies, ForbiddenException } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { REQUIRED_PERMISSIONS } from '../decorators/access.decorators';
import { AccountService } from '../../modules/authorization/account.service';

// Enforces @RequirePermission. The role's permissions are read from the
// database on every request, so promoting or demoting someone takes effect
// immediately.
//
// A missing permission is a 403, not a 404. Operator routes existing is not a
// secret; only the *directory of people* is, and that is the graph guard's job.
@Injectable()
@Dependencies(Reflector, AccountService)
export class PermissionsGuard {
  constructor(reflector, accounts) {
    this.reflector = reflector;
    this.accounts = accounts;
  }

  async canActivate(context) {
    if (context.getType() !== 'http') return true;

    const required = this.reflector.getAllAndOverride(REQUIRED_PERMISSIONS, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!required || required.length === 0) return true;

    // No account here means the route was left @Public but asks for a
    // permission: a contradiction, so deny rather than guess.
    const account = context.switchToHttp().getRequest().account;
    if (!account) throw new ForbiddenException();

    const held = await this.accounts.permissionsForRole(account.role);
    if (!required.every((p) => held.has(p))) throw new ForbiddenException();
    return true;
  }
}
