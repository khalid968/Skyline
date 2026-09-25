import { Module } from '@nestjs/common';
import { WebsocketModule } from '../websocket/websocket.module';
import { AdminUsersService } from './admin-users.service';
import { AdminGroupsService } from './admin-groups.service';
import {
  AdminUsersController,
  AdminContactLinksController,
  AdminDevicesController,
  AdminGroupsController,
} from './admin.controllers';

@Module({
  // FanoutService (rename notices) and ConnectionRegistry (closing the sockets
  // of a suspended user or revoked device).
  imports: [WebsocketModule],
  controllers: [
    AdminUsersController,
    AdminContactLinksController,
    AdminDevicesController,
    AdminGroupsController,
  ],
  providers: [AdminUsersService, AdminGroupsService],
})
export class AdminModule {}
