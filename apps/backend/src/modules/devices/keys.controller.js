import {
  Controller,
  Get,
  Put,
  Bind,
  Body,
  Param,
  Req,
  Res,
  Dependencies,
} from '@nestjs/common';
import { ContactTarget } from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { KeysService } from './keys.service';
import { UploadKeysDto } from './keys.dto';

// Member routes (device sessions only). There is deliberately no route to
// fetch the keys of someone you are not directly linked to: to the key
// directory, as everywhere else, they do not exist.
@Controller()
@Dependencies(KeysService)
export class KeysController {
  constructor(keys) {
    this.keys = keys;
  }

  // Publish or top up this device's prekeys. Returns what is now on file.
  @Put('me/keys')
  @Bind(Req(), Body())
  @Validated(undefined, UploadKeysDto)
  upload(req, dto) {
    return this.keys.upload(req.account.deviceId, dto);
  }

  // How many one-time keys are left, so the device knows when to top up.
  @Get('me/keys')
  @Bind(Req())
  counts(req) {
    return this.keys.counts(req.account.deviceId);
  }

  // Everything needed to start an encrypted session with each of a contact's
  // devices. Direct link required; anyone else is a 404.
  @Get('users/:userId/keys')
  @ContactTarget('userId', { mode: 'direct' })
  @Bind(Req(), Param('userId'), Res({ passthrough: true }))
  bundles(req, userId, res) {
    return this.keys.bundles(req.account, userId, res);
  }
}
