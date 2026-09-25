import { Module } from '@nestjs/common';
import { WebsocketModule } from '../websocket/websocket.module';
import { AdminUsersService } from './admin-users.service';
import { AdminGroupsService } from './admin-groups.service';
import { AdminAuditService } from './admin-audit.service';
import { AdminAlertsService } from './admin-alerts.service';
import { AdminSessionsService } from './admin-sessions.service';
import {
  AdminOverviewController,
  AdminAuditController,
  AdminAlertsController,
  AdminSessionsController,
} from './admin-v2.controllers';
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
    // Dashboard v2 (Phase 11).
    AdminOverviewController,
    AdminAuditController,
    AdminAlertsController,
    AdminSessionsController,
  ],
  providers: [
    AdminUsersService,
    AdminGroupsService,
    AdminAuditService,
    AdminAlertsService,
    AdminSessionsService,
  ],
})
export class AdminModule {}
