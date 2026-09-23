import { Module } from '@nestjs/common';
import { WebsocketModule } from '../websocket/websocket.module';
import { ActivationService } from './activation.service';
import { AdminAuthService } from './admin-auth.service';
import { AuthController } from './auth.controller';
import { MeController } from './me.controller';
import { AdminAuthController } from './admin-auth.controller';

@Module({
  // For ConnectionRegistry: revoking a device closes its socket.
  imports: [WebsocketModule],
  controllers: [AuthController, MeController, AdminAuthController],
  providers: [ActivationService, AdminAuthService],
})
export class AuthModule {}
