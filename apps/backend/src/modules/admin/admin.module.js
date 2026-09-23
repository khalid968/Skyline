import { Module } from '@nestjs/common';
import { WebsocketModule } from '../websocket/websocket.module';
import { AdminUsersService } from './admin-users.service';
import {
  AdminUsersController,
  AdminContactLinksController,
  AdminDevicesController,
} from './admin.controllers';

@Module({
  // FanoutService (rename notices) and ConnectionRegistry (closing the sockets
  // of a suspended user or revoked device).
  imports: [WebsocketModule],
  controllers: [
    AdminUsersController,
    AdminContactLinksController,
    AdminDevicesController,
  ],
  providers: [AdminUsersService],
})
export class AdminModule {}
