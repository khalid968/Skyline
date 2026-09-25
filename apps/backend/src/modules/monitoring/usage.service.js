import { Injectable, Dependencies, Logger } from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';

// Daily usage totals (board 36): one counter per day and metric, nothing per
// person (usage_daily has no user, device or chat column, by design).
//
// Counting never gets in the way: a failure is logged and the message still
// goes, since a missed count is worth far less than a missed message.
@Injectable()
@Dependencies(DatabaseService)
export class UsageService {
  constructor(db) {
    this.db = db;
    this.logger = new Logger('Usage');
  }

  async bump(metric) {
    try {
      await this.db.query(
        `INSERT INTO usage_daily (day, metric, count) VALUES (current_date, $1, 1)
         ON CONFLICT (day, metric) DO UPDATE SET count = usage_daily.count + 1`,
        [metric],
      );
    } catch (err) {
      this.logger.warn(`could not count ${metric}: ${err.message}`);
    }
  }
}
