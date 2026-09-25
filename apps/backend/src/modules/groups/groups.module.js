import { Module } from '@nestjs/common';
import { NotificationsModule } from '../notifications/notifications.module';
import { MediaModule } from '../media/media.module';
import { DevicesModule } from '../devices/devices.module';
import { MessagesModule } from '../messages/messages.module';
import { WebsocketModule } from '../websocket/websocket.module';
import { GroupsController } from './groups.controller';
import { GroupsService } from './groups.service';

// Phase 8b: groups as members see them (listing, Sender Key messages and key
// shares, leaving). Operators manage groups in modules/admin.
@Module({
  imports: [
    NotificationsModule,
    MediaModule,
    DevicesModule,
    MessagesModule,
    WebsocketModule,
  ],
  controllers: [GroupsController],
  providers: [GroupsService],
})
export class GroupsModule {}
