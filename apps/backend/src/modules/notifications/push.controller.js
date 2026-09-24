import {
  Controller,
  Put,
  Delete,
  Bind,
  Body,
  Req,
  HttpCode,
  Dependencies,
} from '@nestjs/common';
import { IsIn, IsString, Length } from 'class-validator';
import { Validated } from '../../common/decorators/validated.decorator';
import { PushService } from './push.service';

export class PushTokenDto {
  @IsIn(['fcm', 'apns']) provider;
  @IsString() @Length(16, 4096) token;
}

// Member routes: this device's push token. Only a token is stored; it lets
// Apple or Google deliver a content-free wake-up and nothing else.
@Controller('me/push')
@Dependencies(PushService)
export class PushController {
  constructor(push) {
    this.push = push;
  }

  @Put()
  @HttpCode(204)
  @Bind(Req(), Body())
  @Validated(undefined, PushTokenDto)
  async register(req, dto) {
    await this.push.register(req.account.deviceId, dto);
  }

  @Delete()
  @HttpCode(204)
  @Bind(Req())
  async unregister(req) {
    await this.push.unregister(req.account.deviceId);
  }
}
