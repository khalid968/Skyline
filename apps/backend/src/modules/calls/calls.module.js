import { Module } from '@nestjs/common';
import { CallsController } from './calls.controller';
import { CallsService } from './calls.service';

// Phase 10: relay credentials for calls. Everything else about a call is
// end-to-end encrypted between the two devices.
@Module({
  controllers: [CallsController],
  providers: [CallsService],
})
export class CallsModule {}
