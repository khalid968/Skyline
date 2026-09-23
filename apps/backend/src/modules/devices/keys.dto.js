import { Type } from 'class-transformer';
import {
  IsArray,
  IsInt,
  IsOptional,
  IsString,
  Length,
  Max,
  Min,
  ArrayMaxSize,
  ValidateNested,
} from 'class-validator';

// Shapes only; byte lengths and key types are checked by KeysService after
// decoding. Key ids are 24-bit, chosen by the device (Signal's convention).
// Every key is base64 (or base64url) of libsignal's serialized PUBLIC key.

export const MAX_KEYS_PER_UPLOAD = 100;

export class SignedPreKeyDto {
  @IsInt() @Min(1) @Max(16777215) keyId;
  @IsString() @Length(44, 46) publicKey;
  @IsString() @Length(84, 88) signature;
}

export class KyberPreKeyDto {
  @IsInt() @Min(1) @Max(16777215) keyId;
  @IsString() @Length(1300, 2300) publicKey;
  @IsString() @Length(84, 88) signature;
}

export class OneTimePreKeyDto {
  @IsInt() @Min(1) @Max(16777215) keyId;
  @IsString() @Length(44, 46) publicKey;
}

export class UploadKeysDto {
  @IsOptional()
  @ValidateNested()
  @Type(() => SignedPreKeyDto)
  signedPreKey;

  @IsOptional()
  @ValidateNested()
  @Type(() => KyberPreKeyDto)
  lastResortKyberPreKey;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(MAX_KEYS_PER_UPLOAD)
  @ValidateNested({ each: true })
  @Type(() => OneTimePreKeyDto)
  oneTimePreKeys;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(MAX_KEYS_PER_UPLOAD)
  @ValidateNested({ each: true })
  @Type(() => KyberPreKeyDto)
  kyberPreKeys;
}
