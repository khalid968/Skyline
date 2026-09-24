import {
  Controller,
  Get,
  Post,
  Bind,
  Body,
  Param,
  Req,
  Res,
  HttpCode,
  Dependencies,
} from '@nestjs/common';
import { ArrayMaxSize, IsArray, IsUUID } from 'class-validator';
import { ContactTarget } from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { MessagesService } from './messages.service';
import { AckDto, SendMessageDto, SignalDto } from './messages.dto';

export class StatusQueryDto {
  @IsArray() @ArrayMaxSize(200) @IsUUID('all', { each: true }) messageIds;
}

// Member routes (device sessions only). Every route that names another person
// requires a live DIRECT link; anyone else is the usual 404.
@Controller()
@Dependencies(MessagesService)
export class MessagesController {
  constructor(messages) {
    this.messages = messages;
  }

  // Everyone you can message, with their reachable devices.
  @Get('me/contacts')
  @Bind(Req())
  contacts(req) {
    return this.messages.contacts(req.account.userId);
  }

  // One contact's reachable devices (identity keys included), e.g. to check
  // the sender of a first message against the directory.
  @Get('users/:userId/devices')
  @ContactTarget('userId', { mode: 'direct' })
  @Bind(Param('userId'))
  devices(userId) {
    return this.messages.contactDevices(userId);
  }

  @Post('users/:userId/messages')
  @HttpCode(201)
  @ContactTarget('userId', { mode: 'direct' })
  @Bind(Req(), Param('userId'), Body(), Res({ passthrough: true }))
  @Validated(undefined, undefined, SendMessageDto)
  send(req, userId, dto, res) {
    return this.messages.send(req.account, userId, dto, res);
  }

  @Post('users/:userId/signals')
  @HttpCode(204)
  @ContactTarget('userId', { mode: 'direct' })
  @Bind(Req(), Param('userId'), Body(), Res({ passthrough: true }))
  @Validated(undefined, undefined, SignalDto)
  signal(req, userId, dto, res) {
    return this.messages.signal(req.account, userId, dto, res);
  }

  @Get('me/inbox')
  @Bind(Req())
  inbox(req) {
    return this.messages.inbox(req.account);
  }

  @Post('me/inbox/ack')
  @HttpCode(200)
  @Bind(Req(), Body())
  @Validated(undefined, AckDto)
  ack(req, dto) {
    return this.messages.ack(req.account, dto);
  }

  // Delivery state of your own sent messages (ticks after a restart).
  @Post('me/messages/status')
  @HttpCode(200)
  @Bind(Req(), Body())
  @Validated(undefined, StatusQueryDto)
  status(req, dto) {
    return this.messages.status(req.account, dto.messageIds);
  }
}
