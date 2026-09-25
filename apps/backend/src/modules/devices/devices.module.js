import { Module } from '@nestjs/common';
import { KeysController } from './keys.controller';
import { KeysService } from './keys.service';

// Phase 7: the device key directory (public prekeys for the Signal Protocol).
@Module({
  controllers: [KeysController],
  providers: [KeysService],
  exports: [KeysService],
})
export class DevicesModule {}
