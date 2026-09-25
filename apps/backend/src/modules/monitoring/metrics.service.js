import { Injectable } from '@nestjs/common';

const KEEP_MINUTES = 60;
const MAX_SAMPLES_PER_MINUTE = 2000;

// Request statistics for the overview page (board 36): how busy this server
// instance is, how many requests failed, how slow the slow ones are. Only a
// status code and a duration per request, in memory, for the last hour: no
// path, no caller, nothing that says who did what.
@Injectable()
export class MetricsService {
  constructor() {
    this.minutes = new Map(); // minute number -> { count, errors, durations[] }
    this.startedAt = Date.now();
  }

  record(status, durationMs, now = Date.now()) {
    const minute = Math.floor(now / 60000);
    let b = this.minutes.get(minute);
    if (!b) {
      b = { count: 0, errors: 0, durations: [] };
      this.minutes.set(minute, b);
      for (const m of this.minutes.keys()) if (m <= minute - KEEP_MINUTES) this.minutes.delete(m);
    }
    b.count += 1;
    if (status >= 500) b.errors += 1;
    if (b.durations.length < MAX_SAMPLES_PER_MINUTE) b.durations.push(durationMs);
  }

  snapshot(now = Date.now()) {
    const current = Math.floor(now / 60000);
    const recent = [...this.minutes.entries()].filter(([m]) => m > current - KEEP_MINUTES);
    const lastFive = recent.filter(([m]) => m >= current - 5 && m < current);
    const durations = recent.filter(([m]) => m > current - 15).flatMap(([, b]) => b.durations).sort((a, b) => a - b);
    return {
      // The average of the last five complete minutes, so it does not dip at
      // the start of every minute.
      requestsPerMinute: Math.round(lastFive.reduce((n, [, b]) => n + b.count, 0) / 5),
      errorsLastHour: recent.reduce((n, [, b]) => n + b.errors, 0),
      p95Ms: durations.length ? Math.round(durations[Math.min(durations.length - 1, Math.floor(durations.length * 0.95))]) : null,
      uptimeSeconds: Math.round((now - this.startedAt) / 1000),
    };
  }
}

// Express middleware: times every request and records it when the response
// finishes, whatever produced it (a guard's 401 counts as much as a 200).
export function metricsMiddleware(metrics) {
  return (req, res, next) => {
    const start = process.hrtime.bigint();
    res.on('finish', () => {
      metrics.record(res.statusCode, Number(process.hrtime.bigint() - start) / 1e6);
    });
    next();
  };
}
