import { Global, Module } from '@nestjs/common';
import { AbuseService } from './abuse.service';

// Metadata-only abuse detection and its automatic limits (board 37). Global:
// sending, uploading, activation and dashboard sign-in all report to it.
@Global()
@Module({
  providers: [AbuseService],
  exports: [AbuseService],
})
export class AbuseModule {}
