import { Module } from '@nestjs/common';
import { WebsocketModule } from '../websocket/websocket.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { MediaModule } from '../media/media.module';
import { MessagesController } from './messages.controller';
import { MessagesService } from './messages.service';

// Phase 8a: sending, the per-device inbox, delivery receipts, typing signals.
@Module({
  imports: [WebsocketModule, NotificationsModule, MediaModule],
  controllers: [MessagesController],
  providers: [MessagesService],
  exports: [MessagesService],
})
export class MessagesModule {}
