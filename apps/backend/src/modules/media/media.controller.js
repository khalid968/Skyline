import {
  Controller,
  Get,
  Post,
  Put,
  Delete,
  Bind,
  Body,
  Param,
  Query,
  Req,
  Res,
  Headers,
  HttpCode,
  Dependencies,
} from '@nestjs/common';
import { IsInt, IsString, IsUUID, Length, Max, Min } from 'class-validator';
import {
  AttachmentTarget,
  OwnUploadTarget,
} from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { MediaService, MAX_CIPHERTEXT } from './media.service';

export class ProfilePhotoDto {
  @IsUUID() attachmentId;
}

// Phase 14d (board 46): your own profile photo. Upload it like any
// attachment (encrypted on the device), then name it here. Only people who can
// see you may download it; its key reaches them by Signal message.
@Controller('me/photo')
@Dependencies(MediaService)
export class ProfilePhotoController {
  constructor(media) {
    this.media = media;
  }

  @Put()
  @HttpCode(204)
  @Bind(Req(), Body())
  @Validated(undefined, ProfilePhotoDto)
  async set(req, dto) {
    await this.media.setProfilePhoto(req.account, dto.attachmentId);
  }

  @Delete()
  @HttpCode(204)
  @Bind(Req())
  async clear(req) {
    await this.media.clearProfilePhoto(req.account);
  }
}

export class StartUploadDto {
  @IsInt() @Min(17) @Max(MAX_CIPHERTEXT) ciphertextBytes;
  @IsString() @Length(43, 44) sha256;
}

// Member routes (device sessions only). Upload routes are the uploader's own;
// the download route needs the file to ride on a message in a chat the caller
// can still reach. Anything else is the usual identical 404.
@Controller('attachments')
@Dependencies(MediaService)
export class MediaController {
  constructor(media) {
    this.media = media;
  }

  @Post()
  @HttpCode(201)
  @Bind(Req(), Body(), Res({ passthrough: true }))
  @Validated(undefined, StartUploadDto)
  start(req, dto, res) {
    return this.media.start(req.account, dto, res);
  }

  // Which parts are already stored, to resume an interrupted upload.
  @Get(':attachmentId/upload')
  @OwnUploadTarget('attachmentId')
  @Bind(Param('attachmentId'))
  progress(attachmentId) {
    return this.media.progress(attachmentId);
  }

  // One 8 MB part of ciphertext, as application/octet-stream.
  @Put(':attachmentId/parts')
  @HttpCode(204)
  @OwnUploadTarget('attachmentId')
  @Bind(Param('attachmentId'), Query('part'), Req())
  async putPart(attachmentId, part, req) {
    await this.media.putPart(attachmentId, Number(part), req.body);
  }

  @Post(':attachmentId/complete')
  @HttpCode(200)
  @OwnUploadTarget('attachmentId')
  @Bind(Param('attachmentId'))
  complete(attachmentId) {
    return this.media.complete(attachmentId);
  }

  @Get(':attachmentId')
  @AttachmentTarget('attachmentId')
  @Bind(Param('attachmentId'), Headers('range'), Res())
  download(attachmentId, range, res) {
    return this.media.download(attachmentId, range, res);
  }
}
