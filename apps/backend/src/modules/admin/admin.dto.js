import {
  IsString,
  IsIn,
  IsOptional,
  IsBoolean,
  IsArray,
  IsUUID,
  Length,
  Matches,
  ArrayMaxSize,
} from 'class-validator';

export const ROLES = ['member', 'moderator', 'admin'];

// Mirrors the users_username_format CHECK (migration 003): 3 to 30 characters,
// lower-case letters, digits, dot, dash, underscore, starting and ending with a
// letter or digit. Checked here too so the dashboard gets a readable message.
const USERNAME = /^[a-z0-9][a-z0-9._-]{1,28}[a-z0-9]$/;
const USERNAME_MSG =
  'username must be 3-30 characters: lower-case letters, digits, dot, dash or underscore, starting and ending with a letter or digit';

export class CreateUserDto {
  @IsString() @Matches(USERNAME, { message: USERNAME_MSG }) username;
  @IsString() @Length(1, 80) displayName;
  @IsIn(ROLES) role;
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(500)
  @IsUUID('4', { each: true })
  contactIds;
}

export class UpdateUserDto {
  @IsOptional() @IsString() @Length(1, 80) displayName;
  @IsOptional()
  @IsString()
  @Matches(USERNAME, { message: USERNAME_MSG })
  username;
}

export class SetRoleDto {
  @IsIn(ROLES) role;
}

export class ResetSignInDto {
  @IsBoolean() resetTwoFactor;
}

export class SetLinkDto {
  @IsUUID('4') userId;
  @IsUUID('4') otherUserId;
  @IsBoolean() linked;
}

// ---------------------------------------------------------------- groups

export class CreateGroupDto {
  @IsString() @Length(1, 80) name;
  @IsOptional() @IsString() @Length(0, 500) description;
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(1000)
  @IsUUID('all', { each: true })
  memberIds;
}

export class UpdateGroupDto {
  @IsOptional() @IsString() @Length(1, 80) name;
  @IsOptional() @IsString() @Length(0, 500) description;
}

export class SetGroupMemberDto {
  @IsUUID() userId;
  @IsBoolean() member;
}

export class ArchiveGroupDto {
  @IsBoolean() archived;
}

// Board 37: mark an alert reviewed, optionally suspending its person.
export class ReviewAlertDto {
  @IsBoolean() suspend;
}
