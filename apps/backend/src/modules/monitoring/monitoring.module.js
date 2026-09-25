import { Global, Module, Dependencies } from '@nestjs/common';
import { MediaModule } from '../media/media.module';
import { WebsocketModule } from '../websocket/websocket.module';
import { MetricsService, metricsMiddleware } from './metrics.service';
import { UsageService } from './usage.service';
import { OverviewService } from './overview.service';

// Board 36's data: request statistics for every route, daily usage totals
// (bumped by messages, groups and calls), and the overview itself. Global, so
// the modules that count usage need no import.
@Global()
@Module({
  imports: [MediaModule, WebsocketModule],
  providers: [MetricsService, UsageService, OverviewService],
  exports: [MetricsService, UsageService, OverviewService],
})
@Dependencies(MetricsService)
export class MonitoringModule {
  constructor(metrics) {
    this.metrics = metrics;
  }

  configure(consumer) {
    consumer.apply(metricsMiddleware(this.metrics)).forRoutes('*');
  }
}
