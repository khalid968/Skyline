import fs from 'fs';
import { Controller, Get, Module, Dependencies } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Public } from '../../common/decorators/access.decorators';
import { RateLimit } from '../../common/rate-limit/rate-limit';

// Boards 41-42: what the current app version is, where to get it, and the
// oldest version still allowed. Public: the download page and not-yet-
// activated apps read it. The manifest is a JSON file written at release
// time (infra/production/releases); it holds download links and checksums,
// nothing about any person.
@Controller('app')
@Dependencies(ConfigService)
export class ReleasesController {
  constructor(config) {
    this.app = config.get('app');
  }

  @Public()
  @Get('releases')
  @RateLimit('releases', [{ by: 'ip', limit: 120, windowSec: 60 }])
  releases() {
    let manifest = {};
    if (this.app.releasesFile) {
      try {
        manifest = JSON.parse(fs.readFileSync(this.app.releasesFile, 'utf8'));
      } catch {
        manifest = {}; // no release published yet
      }
    }
    return {
      latest: manifest.latest ?? null,
      // The server's setting wins: it is what the 426 gate enforces.
      minimum: this.app.minVersion,
    };
  }
}

@Module({ controllers: [ReleasesController] })
export class ReleasesModule {}
