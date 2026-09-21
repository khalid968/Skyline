// TEST-ONLY routes. They exist so the global guards can be exercised end to end
// without Phase 5 or any real feature. Never imported by production code.
import {
  Controller,
  Get,
  Post,
  Body,
  Bind,
  Dependencies,
} from '@nestjs/common';
import { IsString, Length } from 'class-validator';
import {
  Public,
  RequirePermission,
  ContactTarget,
  GroupTarget,
  ChatTarget,
} from '../../src/common/decorators/access.decorators';
import { Validated } from '../../src/common/decorators/validated.decorator';

export class EchoDto {
  @IsString()
  @Length(1, 20)
  name;
}

@Controller('t')
export class TestController {
  // Authenticated, nothing more.
  @Get('open')
  open() {
    return { ok: true };
  }

  @Public()
  @Get('public')
  publicRoute() {
    return { ok: true };
  }

  @Get('user/:userId')
  @ContactTarget('userId')
  user() {
    return { ok: true };
  }

  @Get('direct/:userId')
  @ContactTarget('userId', { mode: 'direct' })
  direct() {
    return { ok: true };
  }

  @Get('group/:groupId')
  @GroupTarget('groupId')
  group() {
    return { ok: true };
  }

  @Get('chat/:chatId')
  @ChatTarget('chatId')
  chat() {
    return { ok: true };
  }

  @Get('admin')
  @RequirePermission('users.rename')
  admin() {
    return { ok: true };
  }

  @Post('echo')
  @Bind(Body())
  @Validated(EchoDto)
  echo(body) {
    return { name: body.name };
  }

  @Get('boom')
  boom() {
    throw new Error(
      'SELECT * FROM secret_table -- internal detail that must never leak',
    );
  }
}
