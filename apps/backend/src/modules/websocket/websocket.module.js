import { Module } from '@nestjs/common';
import { ConnectionRegistry } from './connection-registry';
import { EventsGateway } from './events.gateway';
import { FanoutService } from './fanout.service';
import { WS_AUTHENTICATOR, TokenWsAuthenticator } from './ws-authenticator';

@Module({
  providers: [
    ConnectionRegistry,
    EventsGateway,
    FanoutService,
    // Device access tokens only (Phase 5).
    { provide: WS_AUTHENTICATOR, useClass: TokenWsAuthenticator },
  ],
  exports: [FanoutService, ConnectionRegistry],
})
export class WebsocketModule {}
