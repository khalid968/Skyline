import {
  Controller,
  Get,
  Post,
  Bind,
  Body,
  Param,
  Query,
  Req,
  Res,
  Ip,
  HttpCode,
  Dependencies,
} from '@nestjs/common';
import {
  RequirePermission,
  GraphExempt,
  DashboardSession,
} from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';
import { OverviewService } from '../monitoring/overview.service';
import { AdminAuditService } from './admin-audit.service';
import { AdminAlertsService } from './admin-alerts.service';
import { AdminSessionsService } from './admin-sessions.service';
import { ReviewAlertDto } from './admin.dto';

// Admin dashboard v2 (Phase 11, boards 36-39). Operator routes only: each one
// requires a permission (or, for sessions, a dashboard session), so a phone's
// session is never accepted here.

// Board 36: every operator (overview.read). Totals only, never per person.
@Controller('admin/overview')
@Dependencies(OverviewService)
export class AdminOverviewController {
  constructor(overview) {
    this.overview = overview;
  }

  @Get()
  @RequirePermission('overview.read')
  @Bind(Query('days'))
  get(days) {
    const n = [7, 14, 30].includes(Number(days)) ? Number(days) : 14;
    return this.overview.overview({ days: n });
  }
}

// Board 38: the owner and admins (audit.read; moderators lost it in 015).
@Controller('admin/audit')
@Dependencies(AdminAuditService)
export class AdminAuditController {
  constructor(audit) {
    this.audit = audit;
  }

  @Get()
  @RequirePermission('audit.read')
  @Bind(Query('category'), Query('q'), Query('before'), Query('limit'))
  list(category, q, before, limit) {
    return this.audit.list({ category, q, before, limit: limit ? Number(limit) : undefined });
  }

  @Get('export')
  @RequirePermission('audit.read')
  @Bind(Query('category'), Query('q'), Res())
  async export(category, q, res) {
    const csv = await this.audit.csv({ category, q });
    const day = new Date().toISOString().slice(0, 10);
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="skyline-audit-${day}.csv"`);
    res.setHeader('Cache-Control', 'no-store');
    res.send(csv);
  }
}

// Board 37: the owner and admins (alerts.manage).
const ALERTS = 'alerts are about devices, addresses and operators, not graph members; gated by alerts.manage';

@Controller('admin/alerts')
@Dependencies(AdminAlertsService)
export class AdminAlertsController {
  constructor(alerts) {
    this.alerts = alerts;
  }

  @Get()
  @RequirePermission('alerts.manage')
  @Bind(Query('state'))
  list(state) {
    return this.alerts.list({ state });
  }

  @Post(':alertId/lift')
  @HttpCode(200)
  @GraphExempt(ALERTS)
  @RequirePermission('alerts.manage')
  @Bind(Req(), Param('alertId'), Ip())
  lift(req, alertId, ip) {
    return this.alerts.lift(req.account, alertId, ip);
  }

  @Post(':alertId/review')
  @HttpCode(200)
  @GraphExempt(ALERTS)
  @RequirePermission('alerts.manage')
  @Bind(Req(), Param('alertId'), Body(), Ip())
  @Validated(undefined, undefined, ReviewAlertDto)
  review(req, alertId, dto, ip) {
    return this.alerts.review(req.account, alertId, dto, ip);
  }
}

// Board 39: any operator, for their own sessions; the owner for everyone's.
const SESSIONS = 'dashboard sessions belong to operators; own sessions, or the owner, checked in the service';

@Controller('admin/sessions')
@Dependencies(AdminSessionsService)
export class AdminSessionsController {
  constructor(sessions) {
    this.sessions = sessions;
  }

  @Get()
  @DashboardSession()
  @RequirePermission('dashboard.access')
  @Bind(Req())
  list(req) {
    return this.sessions.list(req.account);
  }

  @Post('revoke-others')
  @HttpCode(200)
  @DashboardSession()
  @RequirePermission('dashboard.access')
  @Bind(Req(), Ip())
  revokeOthers(req, ip) {
    return this.sessions.revokeOthers(req.account, ip);
  }

  @Post(':sessionId/revoke')
  @HttpCode(204)
  @DashboardSession()
  @GraphExempt(SESSIONS)
  @RequirePermission('dashboard.access')
  @Bind(Req(), Param('sessionId'), Ip())
  async revoke(req, sessionId, ip) {
    await this.sessions.revoke(req.account, sessionId, ip);
  }
}
