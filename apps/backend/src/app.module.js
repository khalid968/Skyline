import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_FILTER, APP_GUARD, APP_PIPE } from '@nestjs/core';
import configuration from './config/configuration';
import { validateEnv } from './config/validate-env';
import { DatabaseModule } from './database/database.module';
import { RedisModule } from './redis/redis.module';
import { AuthorizationModule } from './modules/authorization/authorization.module';
import { AuditModule } from './modules/audit/audit.module';
import { HealthModule } from './modules/health/health.module';
import { AuthModule } from './modules/auth/auth.module';
import { UsersModule } from './modules/users/users.module';
import { DevicesModule } from './modules/devices/devices.module';
import { ChatsModule } from './modules/chats/chats.module';
import { MessagesModule } from './modules/messages/messages.module';
import { GroupsModule } from './modules/groups/groups.module';
import { MediaModule } from './modules/media/media.module';
import { NotificationsModule } from './modules/notifications/notifications.module';
import { AdminModule } from './modules/admin/admin.module';
import { WebsocketModule } from './modules/websocket/websocket.module';
import { AllExceptionsFilter } from './common/filters/all-exceptions.filter';
import { createValidationPipe } from './common/pipes/validation.pipe';
import { AuthenticatedGuard } from './common/guards/authenticated.guard';
import { PermissionsGuard } from './common/guards/permissions.guard';
import { ContactGraphGuard } from './common/guards/contact-graph.guard';
import {
  RateLimitGuard,
  RateLimitModule,
} from './common/rate-limit/rate-limit';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      load: [configuration],
      // Refuses to boot on a missing or unsafe configuration.
      validate: validateEnv,
    }),
    DatabaseModule,
    RedisModule,
    RateLimitModule,
    AuthorizationModule,
    AuditModule,
    HealthModule,
    AuthModule,
    UsersModule,
    DevicesModule,
    ChatsModule,
    MessagesModule,
    GroupsModule,
    MediaModule,
    NotificationsModule,
    AdminModule,
    WebsocketModule,
  ],
  providers: [
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
    { provide: APP_PIPE, useFactory: createValidationPipe },
    // Guards run in this order, for EVERY route: are you over a rate limit (so
    // unauthenticated floods are throttled too), who are you, are you allowed
    // to do this, and is the person you named inside your contact graph.
    { provide: APP_GUARD, useClass: RateLimitGuard },
    { provide: APP_GUARD, useClass: AuthenticatedGuard },
    { provide: APP_GUARD, useClass: PermissionsGuard },
    { provide: APP_GUARD, useClass: ContactGraphGuard },
  ],
})
export class AppModule {}
