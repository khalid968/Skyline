import { describe, expect, it } from 'vitest';
import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { fakeBackend, renderApp, OWNER, MODERATOR, person, OVERVIEW } from './helpers';
import { browser } from '../pages/Sessions';
import { about } from '../pages/AuditLog';
import { capabilities } from '../lib/auth';

// Phase 11, boards 36-39. Access rules are owner decisions (decisions.md
// 2026-09-26): moderators see the overview and their own sessions, but not
// the audit log or alerts; only the owner sees everyone's sessions.

const ADMIN = { ...OWNER, userId: '00000000-0000-4000-8000-000000000003', displayName: 'Ada Admin', isOwner: false };
const NO_ALERTS = { alerts: [], open: 0, reviewed: 0 };

const alert = (over = {}) => ({
  alertId: '00000000-0000-4000-8000-00000000a001',
  kind: 'send_rate',
  level: 'high',
  subject: { ...person(1), status: 'active' },
  device: { deviceId: 'd1', name: 'Pixel 9', platform: 'android' },
  ip: null,
  evidence: { messages: 412, minutes: 5 },
  autoAction: 'Slowed automatically: this device can send 1 message every 5 seconds',
  limitUntil: new Date(Date.now() + 26 * 60000).toISOString(),
  limitActive: true,
  liftedAt: null,
  liftedBy: null,
  reviewedAt: null,
  reviewedBy: null,
  outcome: null,
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
  ...over,
});

describe('who sees what (Phase 11)', () => {
  it('moderators get the overview and sessions, never the audit log or alerts', () => {
    expect(capabilities(MODERATOR)).toMatchObject({ overview: true, audit: false, alerts: false, allSessions: false });
    expect(capabilities(ADMIN)).toMatchObject({ overview: true, audit: true, alerts: true, allSessions: false });
    expect(capabilities(OWNER)).toMatchObject({ audit: true, alerts: true, allSessions: true });
  });

  it('the menu hides Alerts and Audit log from a moderator', async () => {
    fakeBackend({ 'GET /admin/auth/me': MODERATOR, 'GET /admin/overview?days=14': OVERVIEW });
    renderApp('/overview');
    const nav = await screen.findByRole('navigation');
    expect(within(nav).getByText('Overview')).toBeInTheDocument();
    expect(within(nav).getByText('Sessions')).toBeInTheDocument();
    expect(within(nav).queryByText('Alerts')).toBeNull();
    expect(within(nav).queryByText('Audit log')).toBeNull();
  });
});

describe('overview (board 36)', () => {
  it('shows health, totals and storage, and warns when a service is down', async () => {
    const down = {
      ...OVERVIEW,
      services: OVERVIEW.services.map((s) => (s.id === 'relay' ? { ...s, ok: false, ms: null } : s)),
    };
    fakeBackend({
      'GET /admin/auth/me': OWNER,
      'GET /admin/overview?days=14': down,
      'GET /admin/overview?days=30': { ...OVERVIEW, perDay: [...OVERVIEW.perDay, ...OVERVIEW.perDay, ...OVERVIEW.perDay.slice(0, 2)] },
      'GET /admin/alerts?state=open': { ...NO_ALERTS, open: 2 },
    });
    renderApp('/overview');
    expect(await screen.findByText('146')).toBeInTheDocument();
    expect(screen.getByText('112')).toBeInTheDocument();
    expect(screen.getByText(/The call relay is not answering/)).toBeInTheDocument();
    expect(screen.getByText('Not answering')).toBeInTheDocument();
    expect(screen.getByText(/118 devices connected/)).toBeInTheDocument();
    expect(screen.getByText('42.0 GB · 812 files')).toBeInTheDocument();
    // The open-alert count sits in the menu.
    expect(await screen.findByLabelText('2 open')).toBeInTheDocument();

    await userEvent.setup().click(screen.getByRole('button', { name: '30 days' }));
    expect(await screen.findByText('30 days ago')).toBeInTheDocument();
  });
});

describe('alerts (board 37)', () => {
  it('lifts a limit, and suspends only after asking', async () => {
    let current = alert();
    const id = current.alertId;
    const { calls } = fakeBackend({
      'GET /admin/auth/me': OWNER,
      'GET /admin/alerts?state=open': () => ({
        alerts: current.reviewedAt ? [] : [current],
        open: current.reviewedAt ? 0 : 1,
        reviewed: 0,
      }),
      [`POST /admin/alerts/${id}/lift`]: () => {
        current = { ...current, limitActive: false, liftedAt: new Date().toISOString(), liftedBy: 'Olivia Owner' };
        return current;
      },
      [`POST /admin/alerts/${id}/review`]: () => {
        current = { ...current, reviewedAt: new Date().toISOString(), reviewedBy: 'Olivia Owner', outcome: 'suspended' };
        return current;
      },
    });
    renderApp('/alerts');
    const user = userEvent.setup();
    expect(await screen.findByText("Person 1's Pixel 9 is sending far faster than a person types")).toBeInTheDocument();
    expect(screen.getByText(/412 messages in 5 minutes/)).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Lift now' }));
    expect(await screen.findByText(/Lifted by Olivia Owner/)).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Suspend Person' }));
    expect(screen.getByRole('dialog')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Suspend and mark reviewed' }));
    await waitFor(() => expect(screen.getByText('Nothing needs you right now.')).toBeInTheDocument());
    expect(calls.find((c) => c.path.endsWith('/review')).body).toEqual({ suspend: true });
  });

  it('offers no Suspend for someone this operator may not manage', async () => {
    const aboutAdmin = alert({
      kind: 'admin_password',
      subject: { ...person(2), role: 'admin', status: 'active' },
      device: null,
      evidence: { wrongAttempts: 5, minutes: 10 },
    });
    fakeBackend({
      'GET /admin/auth/me': ADMIN,
      'GET /admin/alerts?state=open': { alerts: [aboutAdmin], open: 1, reviewed: 0 },
    });
    renderApp('/alerts');
    expect(await screen.findByText(/Wrong passwords for the dashboard account "person2"/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Suspend/ })).toBeNull();
    expect(screen.getByRole('button', { name: 'Mark as reviewed' })).toBeInTheDocument();
  });
});

describe('audit log (board 38)', () => {
  const entry = (id, over = {}) => ({
    id: String(id),
    at: new Date().toISOString(),
    action: 'contacts.grant',
    actor: { userId: OWNER.userId, username: 'owner', displayName: 'Olivia Owner' },
    target: { userId: 'p1', username: 'person1', displayName: 'Person 1' },
    other: { username: 'person2', displayName: 'Person 2' },
    group: null,
    device: null,
    ip: '198.51.100.7',
    detail: { otherUserId: 'p2' },
    ...over,
  });
  const automatic = entry(8, {
    action: 'abuse.auto_limit',
    actor: null,
    target: null,
    other: null,
    detail: { kind: 'code_guessing', address: '203.0.113.40' },
  });

  it('filters, shows details, pages, and offers a CSV of the same view', async () => {
    const { calls } = fakeBackend({
      'GET /admin/auth/me': OWNER,
      'GET /admin/alerts?state=open': NO_ALERTS,
      'GET /admin/audit': { entries: [entry(9), automatic], next: '8' },
      'GET /admin/audit?before=8': { entries: [entry(7, { action: 'users.suspend', other: null })], next: null },
      'GET /admin/audit?category=links': { entries: [entry(9)], next: null },
    });
    renderApp('/audit');
    const user = userEvent.setup();
    expect((await screen.findAllByText('Person 1 ↔ Person 2')).length).toBeGreaterThan(0);
    expect(screen.getByText('Skyline')).toBeInTheDocument();
    expect(screen.getByText('203.0.113.40')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Show older entries' }));
    expect(await screen.findByText('Suspended an account')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Links' }));
    await waitFor(() => expect(calls.some((c) => c.path === '/admin/audit?category=links')).toBe(true));
    expect(screen.getByRole('link', { name: /Download CSV/ })).toHaveAttribute('href', '/api/admin/audit/export?category=links');
  });

  it('names both people in a link', () => {
    expect(about(entry(1))).toBe('Person 1 ↔ Person 2');
  });
});

describe('sessions (board 39)', () => {
  const session = (id, operator, over = {}) => ({
    sessionId: id,
    current: false,
    operator: {
      userId: operator.userId,
      displayName: operator.displayName,
      username: operator.username,
      role: operator.role,
      isOwner: operator.isOwner,
      twoFactorEnabled: true,
    },
    ip: '198.51.100.7',
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0',
    usedTwoFactor: true,
    newAddress: false,
    signedInAt: new Date().toISOString(),
    lastActiveAt: new Date().toISOString(),
    ...over,
  });
  const SAFARI = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15';

  it('the owner signs out another operator’s session, but never the one in use', async () => {
    let list = [session('s1', OWNER, { current: true }), session('s2', MODERATOR, { newAddress: true, userAgent: SAFARI })];
    const { calls } = fakeBackend({
      'GET /admin/auth/me': OWNER,
      'GET /admin/alerts?state=open': NO_ALERTS,
      'GET /admin/sessions': () => list,
      'POST /admin/sessions/s2/revoke': () => {
        list = list.filter((s) => s.sessionId !== 's2');
        return { status: 204 };
      },
    });
    renderApp('/sessions');
    const user = userEvent.setup();
    expect(await screen.findByText('THIS SESSION')).toBeInTheDocument();
    expect(screen.getByText(/new address/)).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: /^Sign out .*'s / })).toHaveLength(1);

    await user.click(screen.getByRole('button', { name: "Sign out Mo Derator's Safari on macOS" }));
    expect(await screen.findByText('Safari on macOS is signed out.')).toBeInTheDocument();
    expect(calls.some((c) => c.method === 'POST' && c.path === '/admin/sessions/s2/revoke')).toBe(true);
  });

  it('a moderator is offered only their own other sessions, after confirming', async () => {
    fakeBackend({
      'GET /admin/auth/me': MODERATOR,
      'GET /admin/sessions': [session('s1', MODERATOR, { current: true }), session('s3', MODERATOR)],
      'POST /admin/sessions/revoke-others': { signedOut: 1 },
    });
    renderApp('/sessions');
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Sign out my other sessions' }));
    await user.click(screen.getByRole('button', { name: 'Sign them out' }));
    expect(await screen.findByText('1 session signed out.')).toBeInTheDocument();
  });

  it('reads browsers the way people say them', () => {
    expect(browser('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/129.0 Safari/537.36 Edg/129.0')).toBe(
      'Edge on Windows',
    );
    expect(browser('Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile Safari/604.1')).toBe(
      'Safari on iPad',
    );
    expect(browser(null)).toBe('Unknown browser');
  });
});
