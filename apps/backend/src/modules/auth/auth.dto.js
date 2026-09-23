import { IsString, IsInt, IsIn, Length, Matches } from 'class-validator';

// Shapes only. Whether a code, token or signature is actually GOOD is decided
// by the services, and every such failure looks identical to the caller.

export const PLATFORMS = ['ios', 'android', 'windows', 'macos', 'linux'];
const SIX_DIGITS = /^\d{6}$/;

export class ActivateDto {
  @IsString() @Length(16, 64) code;
  @IsString() @Length(1, 60) deviceName;
  @IsIn(PLATFORMS) platform;
  // Ed25519 public key (32 bytes) and signature (64 bytes), base64 or base64url.
  @IsString() @Length(40, 48) signingKey;
  @IsString() @Length(80, 96) signature;
}

export class RefreshDto {
  @IsString() @Length(40, 64) refreshToken;
  // Unix seconds; signed together with the refresh token.
  @IsInt() timestamp;
  @IsString() @Length(80, 96) signature;
}

export class AdminLoginDto {
  @IsString() @Length(1, 64) username;
  @IsString() @Length(1, 256) password;
}

export class MfaDto {
  @IsString() @Length(40, 64) mfaToken;
  @IsString() @Matches(SIX_DIGITS, { message: 'code must be 6 digits' }) code;
}

export class TwoFactorCodeDto {
  @IsString() @Matches(SIX_DIGITS, { message: 'code must be 6 digits' }) code;
}

export class DisableTwoFactorDto {
  @IsString() @Length(1, 256) password;
  @IsString() @Matches(SIX_DIGITS, { message: 'code must be 6 digits' }) code;
}

export class ChangePasswordDto {
  @IsString() @Length(1, 256) currentPassword;
  @IsString()
  @Length(12, 256, { message: 'newPassword must be at least 12 characters' })
  newPassword;
}
