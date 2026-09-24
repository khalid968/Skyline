import { Module } from '@nestjs/common';
import { WebsocketModule } from '../websocket/websocket.module';
import { MessagesController } from './messages.controller';
import { MessagesService } from './messages.service';

// Phase 8a: sending, the per-device inbox, delivery receipts, typing signals.
@Module({
  imports: [WebsocketModule],
  controllers: [MessagesController],
  providers: [MessagesService],
})
export class MessagesModule {}
