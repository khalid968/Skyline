import { Global, Module } from '@nestjs/common';
import { AccountService } from './account.service';
import { GraphService } from './graph.service';

@Global()
@Module({
  providers: [AccountService, GraphService],
  exports: [AccountService, GraphService],
})
export class AuthorizationModule {}
