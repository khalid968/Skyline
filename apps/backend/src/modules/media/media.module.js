import { Module } from '@nestjs/common';
import { MediaController } from './media.controller';
import { MediaService } from './media.service';
import { StorageService } from './storage.service';

// Encrypted media: resumable uploads, graph-checked downloads, 30-day
// retention (decisions.md 2026-09-25).
@Module({
  controllers: [MediaController],
  providers: [MediaService, StorageService],
  exports: [MediaService],
})
export class MediaModule {}
