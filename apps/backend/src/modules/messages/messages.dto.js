import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  Max,
  Min,
  ValidateNested,
} from 'class-validator';

// Shapes only. Whether the envelopes cover exactly the right devices is
// decided by MessagesService.

// One device's copy: libsignal ciphertext for (userId, deviceNumber).
export class EnvelopeDto {
  @IsUUID() userId;
  @IsInt() @Min(1) @Max(127) deviceNumber;
  @IsIn(['prekey', 'whisper']) kind;
  // base64 of up to 48 KB, well above a text message with post-quantum
  // ratchet overhead (a few KB). Media travels separately (Phase 9).
  @IsString() @Length(4, 65536) body;
}

export class SendMessageDto {
  // Chosen by the sending device, so a retry never delivers twice.
  @IsUUID() messageId;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(64)
  @ValidateNested({ each: true })
  @Type(() => EnvelopeDto)
  envelopes;

  // Uploaded files this message carries (their keys are inside the envelopes).
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(10)
  @IsUUID('all', { each: true })
  attachmentIds;
}

// Typing indicators: relayed live to online devices only, never stored.
export class SignalDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(16)
  @ValidateNested({ each: true })
  @Type(() => EnvelopeDto)
  envelopes;
}

export class AckDto {
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(200)
  @IsUUID('all', { each: true })
  envelopeIds;

  // The newest system message this device has stored.
  @IsOptional() @IsInt() @Min(0) systemSeq;
}
