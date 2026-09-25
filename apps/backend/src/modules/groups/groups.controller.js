import {
  Controller,
  Get,
  Post,
  Bind,
  Body,
  Param,
  Query,
  Req,
  Res,
  Ip,
  HttpCode,
  Dependencies,
} from '@nestjs/common';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  Max,
  Min,
  ValidateNested,
} from 'class-validator';
import { GroupTarget } from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { EnvelopeDto } from '../messages/messages.dto';
import { GroupsService } from './groups.service';

export class DeviceRefDto {
  @IsUUID() userId;
  @IsInt() @Min(1) @Max(127) deviceNumber;
}

export class GroupSendDto {
  @IsUUID() messageId;
  // base64 of one Sender Key ciphertext (same limit as an envelope)
  @IsString() @Length(4, 65536) body;
  @IsArray()
  @ArrayMaxSize(1000)
  @ValidateNested({ each: true })
  @Type(() => DeviceRefDto)
  devices;
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(10)
  @IsUUID('all', { each: true })
  attachmentIds;
}

export class KeyShareDto {
  @IsUUID() messageId;
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(1000)
  @ValidateNested({ each: true })
  @Type(() => EnvelopeDto)
  envelopes;
}

export class MemberKeysQueryDto {
  @IsUUID() userId;
}

// Member routes (device sessions only). Every :groupId route requires a live
// membership in a group that is not archived; anything else is the usual 404.
@Controller()
@Dependencies(GroupsService)
export class GroupsController {
  constructor(groups) {
    this.groups = groups;
  }

  @Get('me/groups')
  @Bind(Req())
  mine(req) {
    return this.groups.mine(req.account.userId);
  }

  // Prekey bundles of a fellow member's devices (?userId=...).
  @Get('groups/:groupId/keys')
  @GroupTarget('groupId')
  @Bind(Req(), Param('groupId'), Query(), Res({ passthrough: true }))
  @Validated(undefined, undefined, MemberKeysQueryDto)
  memberKeys(req, groupId, query, res) {
    return this.groups.memberBundles(req.account, groupId, query.userId, res);
  }

  @Post('groups/:groupId/messages')
  @HttpCode(201)
  @GroupTarget('groupId')
  @Bind(Req(), Param('groupId'), Body(), Res({ passthrough: true }))
  @Validated(undefined, undefined, GroupSendDto)
  send(req, groupId, dto, res) {
    return this.groups.send(req.account, groupId, dto, res);
  }

  @Post('groups/:groupId/key-shares')
  @HttpCode(201)
  @GroupTarget('groupId')
  @Bind(Req(), Param('groupId'), Body(), Res({ passthrough: true }))
  @Validated(undefined, undefined, KeyShareDto)
  shareKeys(req, groupId, dto, res) {
    return this.groups.shareKeys(req.account, groupId, dto, res);
  }

  @Post('groups/:groupId/leave')
  @HttpCode(204)
  @GroupTarget('groupId')
  @Bind(Req(), Param('groupId'), Ip())
  async leave(req, groupId, ip) {
    await this.groups.leave(req.account, groupId, ip);
  }
}
