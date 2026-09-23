import { Global, Module } from '@nestjs/common';
import { AccountService } from './account.service';
import { GraphService } from './graph.service';
import { SessionService } from './session.service';

@Global()
@Module({
  providers: [AccountService, GraphService, SessionService],
  exports: [AccountService, GraphService, SessionService],
})
export class AuthorizationModule {}
