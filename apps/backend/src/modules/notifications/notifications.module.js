import { Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PushController } from './push.controller';
import { PushService } from './push.service';
import { FcmTransport, NullTransport, PUSH_TRANSPORT } from './push.transport';

// Content-free push wake-ups (Phase 8a). The transport is chosen from
// configuration; tests replace it with a recording fake.
@Module({
  controllers: [PushController],
  providers: [
    PushService,
    {
      provide: PUSH_TRANSPORT,
      inject: [ConfigService],
      useFactory: (config) => {
        const file = config.get('push.fcmServiceAccountFile');
        return file ? new FcmTransport(file) : new NullTransport();
      },
    },
  ],
  exports: [PushService],
})
export class NotificationsModule {}
