import {
  Controller,
  Get,
  Post,
  Patch,
  Bind,
  Body,
  Param,
  Query,
  Req,
  Ip,
  HttpCode,
  Dependencies,
} from '@nestjs/common';
import {
  RequirePermission,
  GraphExempt,
} from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { AdminUsersService } from './admin-users.service';
import { AdminGroupsService } from './admin-groups.service';
import {
  CreateUserDto,
  UpdateUserDto,
  SetRoleDto,
  ResetSignInDto,
  SetLinkDto,
  CreateGroupDto,
  UpdateGroupDto,
  SetGroupMemberDto,
  ArchiveGroupDto,
} from './admin.dto';

// The dashboard's API. Every route here is an OPERATOR route: it requires a
// permission, so AuthenticatedGuard accepts only a dashboard session, never a
// phone. Routes that name a user or device are exempt from the contact graph
// (an operator manages everyone) and are gated by permission instead, plus the
// who-may-act-on-whom rules in admin-policy.js.
const OPERATOR =
  'operators manage every account; gated by permission and admin-policy';

@Controller('admin/users')
@Dependencies(AdminUsersService)
export class AdminUsersController {
  constructor(users) {
    this.users = users;
  }

  @Get()
  @RequirePermission('users.read')
  @Bind(Query('q'), Query('includeDeleted'))
  list(q, includeDeleted) {
    return this.users.list({ q, includeDeleted: includeDeleted === 'true' });
  }

  @Post()
  @RequirePermission('users.create')
  @Bind(Req(), Body(), Ip())
  @Validated(undefined, CreateUserDto)
  create(req, dto, ip) {
    return this.users.create(req.account, dto, ip);
  }

  @Get(':userId')
  @GraphExempt(OPERATOR)
  @RequirePermission('users.read')
  @Bind(Param('userId'))
  detail(userId) {
    return this.users.detail(userId);
  }

  @Get(':userId/contacts')
  @GraphExempt(OPERATOR)
  @RequirePermission('users.read')
  @Bind(Param('userId'))
  contacts(userId) {
    return this.users.contactsOf(userId);
  }

  @Patch(':userId')
  @GraphExempt(OPERATOR)
  @RequirePermission('users.rename')
  @Bind(Req(), Param('userId'), Body(), Ip())
  @Validated(undefined, undefined, UpdateUserDto)
  rename(req, userId, dto, ip) {
    return this.users.rename(req.account, userId, dto, ip);
  }

  @Post(':userId/suspend')
  @HttpCode(200)
  @GraphExempt(OPERATOR)
  @RequirePermission('users.suspend')
  @Bind(Req(), Param('userId'), Ip())
  suspend(req, userId, ip) {
    return this.users.suspend(req.account, userId, ip);
  }

  @Post(':userId/reinstate')
  @HttpCode(200)
  @GraphExempt(OPERATOR)
  @RequirePermission('users.suspend')
  @Bind(Req(), Param('userId'), Ip())
  reinstate(req, userId, ip) {
    return this.users.reinstate(req.account, userId, ip);
  }

  @Post(':userId/role')
  @HttpCode(200)
  @GraphExempt(OPERATOR)
  @RequirePermission('users.role')
  @Bind(Req(), Param('userId'), Body(), Ip())
  @Validated(undefined, undefined, SetRoleDto)
  setRole(req, userId, dto, ip) {
    return this.users.setRole(req.account, userId, dto.role, ip);
  }

  @Post(':userId/delete')
  @HttpCode(204)
  @GraphExempt(OPERATOR)
  @RequirePermission('users.delete')
  @Bind(Req(), Param('userId'), Ip())
  async remove(req, userId, ip) {
    await this.users.remove(req.account, userId, ip);
  }

  @Post(':userId/codes')
  @HttpCode(200)
  @GraphExempt(OPERATOR)
  @RequirePermission('codes.issue')
  @Bind(Req(), Param('userId'), Ip())
  issueCode(req, userId, ip) {
    return this.users.issueCode(req.account, userId, ip);
  }

  @Post(':userId/codes/revoke')
  @HttpCode(204)
  @GraphExempt(OPERATOR)
  @RequirePermission('codes.revoke')
  @Bind(Req(), Param('userId'), Ip())
  async revokeCode(req, userId, ip) {
    await this.users.revokeCode(req.account, userId, ip);
  }

  // Getting a locked-out operator back in. Administrators only; resetting an
  // administrator is further limited to the owner (admin-policy.js).
  @Post(':userId/reset-sign-in')
  @HttpCode(200)
  @GraphExempt(OPERATOR)
  @RequirePermission('users.create')
  @Bind(Req(), Param('userId'), Body(), Ip())
  @Validated(undefined, undefined, ResetSignInDto)
  resetSignIn(req, userId, dto, ip) {
    return this.users.resetSignIn(req.account, userId, dto, ip);
  }
}

@Controller('admin/contact-links')
@Dependencies(AdminUsersService)
export class AdminContactLinksController {
  constructor(users) {
    this.users = users;
  }

  // One endpoint for both directions keeps the editor's toggle simple. Both
  // permissions are required; every role that has one has the other.
  @Post()
  @HttpCode(200)
  @RequirePermission('contacts.grant', 'contacts.revoke')
  @Bind(Req(), Body(), Ip())
  @Validated(undefined, SetLinkDto)
  setLink(req, dto, ip) {
    return this.users.setLink(req.account, dto, ip);
  }
}

@Controller('admin/devices')
@Dependencies(AdminUsersService)
export class AdminDevicesController {
  constructor(users) {
    this.users = users;
  }

  @Get()
  @RequirePermission('devices.read')
  @Bind(Query('userId'))
  list(userId) {
    return this.users.listDevices({ userId });
  }

  @Post(':deviceId/revoke')
  @HttpCode(204)
  @GraphExempt(OPERATOR)
  @RequirePermission('devices.revoke')
  @Bind(Req(), Param('deviceId'), Ip())
  async revoke(req, deviceId, ip) {
    await this.users.revokeDevice(req.account, deviceId, ip);
  }
}

// Board 31. Admins and moderators (owner decision); the who-may-act-on-whom
// rules apply to every person added or removed.
@Controller('admin/groups')
@Dependencies(AdminGroupsService)
export class AdminGroupsController {
  constructor(groups) {
    this.groups = groups;
  }

  @Get()
  @RequirePermission('groups.manage')
  list() {
    return this.groups.list();
  }

  @Post()
  @RequirePermission('groups.create')
  @Bind(Req(), Body(), Ip())
  @Validated(undefined, CreateGroupDto)
  create(req, dto, ip) {
    return this.groups.create(req.account, dto, ip);
  }

  @Get(':groupId')
  @GraphExempt(OPERATOR)
  @RequirePermission('groups.manage')
  @Bind(Param('groupId'))
  detail(groupId) {
    return this.groups.detail(groupId);
  }

  @Patch(':groupId')
  @GraphExempt(OPERATOR)
  @RequirePermission('groups.manage')
  @Bind(Req(), Param('groupId'), Body(), Ip())
  @Validated(undefined, undefined, UpdateGroupDto)
  update(req, groupId, dto, ip) {
    return this.groups.update(req.account, groupId, dto, ip);
  }

  @Post(':groupId/members')
  @HttpCode(200)
  @GraphExempt(OPERATOR)
  @RequirePermission('groups.manage')
  @Bind(Req(), Param('groupId'), Body(), Ip())
  @Validated(undefined, undefined, SetGroupMemberDto)
  setMember(req, groupId, dto, ip) {
    return this.groups.setMember(req.account, groupId, dto, ip);
  }

  @Post(':groupId/archive')
  @HttpCode(200)
  @GraphExempt(OPERATOR)
  @RequirePermission('groups.manage')
  @Bind(Req(), Param('groupId'), Body(), Ip())
  @Validated(undefined, undefined, ArchiveGroupDto)
  archive(req, groupId, dto, ip) {
    return this.groups.setArchived(req.account, groupId, dto.archived, ip);
  }
}
