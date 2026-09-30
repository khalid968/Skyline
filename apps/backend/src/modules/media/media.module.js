import { Module } from '@nestjs/common';
import { MediaController, ProfilePhotoController } from './media.controller';
import { MediaService } from './media.service';
import { StorageService } from './storage.service';

// Encrypted media: resumable uploads, graph-checked downloads, 30-day
// retention (decisions.md 2026-09-25).
@Module({
  controllers: [MediaController, ProfilePhotoController],
  providers: [MediaService, StorageService],
  // StorageService: the dashboard overview checks the object store is up.
  exports: [MediaService, StorageService],
})
export class MediaModule {}
