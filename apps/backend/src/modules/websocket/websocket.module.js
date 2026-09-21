import { Module } from '@nestjs/common';
import { ConnectionRegistry } from './connection-registry';
import { EventsGateway } from './events.gateway';
import { FanoutService } from './fanout.service';
import { WS_AUTHENTICATOR, DenyAllWsAuthenticator } from './ws-authenticator';

@Module({
  providers: [
    ConnectionRegistry,
    EventsGateway,
    FanoutService,
    // Phase 5 replaces this with real token authentication.
    { provide: WS_AUTHENTICATOR, useClass: DenyAllWsAuthenticator },
  ],
  exports: [FanoutService, ConnectionRegistry],
})
export class WebsocketModule {}
