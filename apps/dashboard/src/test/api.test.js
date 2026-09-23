import { describe, expect, it, vi } from 'vitest';
import { api, ApiError, describeError, request, setUnauthorizedHandler } from '../lib/api';
import { canManage, capabilities } from '../lib/auth';
import { fakeBackend, OWNER, MODERATOR, person } from './helpers';

describe('api client', () => {
  it('stays same-origin, never sends a token, and always marks itself as the dashboard (CSRF)', async () => {
    const { calls } = fakeBackend({ 'POST /admin/users/x/suspend': { status: 204 } });
    await api.suspend('x');
    expect(calls[0].credentials).toBe('same-origin');
    expect(calls[0].headers['x-skyline-client']).toBe('dashboard');
    expect(calls[0].headers.authorization).toBeUndefined();
  });

  it('a 401 on an ordinary call means the session ended', async () => {
    const ended = vi.fn();
    setUnauthorizedHandler(ended);
    fakeBackend({ 'GET /admin/users': { status: 401, body: {} } });
    await expect(api.users()).rejects.toBeInstanceOf(ApiError);
    expect(ended).toHaveBeenCalledOnce();
  });

  it('a 401 from the sign-in steps is just a wrong password, not a session end', async () => {
    const ended = vi.fn();
    setUnauthorizedHandler(ended);
    fakeBackend({
      'POST /admin/auth/login': { status: 401, body: {} },
      'POST /admin/auth/mfa': { status: 401, body: {} },
    });
    await expect(api.login('a', 'b')).rejects.toMatchObject({ status: 401 });
    await expect(api.completeMfa('t', '123456')).rejects.toMatchObject({ status: 401 });
    expect(ended).not.toHaveBeenCalled();
  });

  it("passes the server's input reasons through and is generic otherwise", async () => {
    fakeBackend({
      'POST /x': { status: 400, body: { message: ['that username is taken'] } },
      'POST /y': { status: 403, body: { message: 'Forbidden' } },
    });
    const e1 = await request('POST', '/x', {}).catch((e) => e);
    const e2 = await request('POST', '/y', {}).catch((e) => e);
    expect(describeError(e1)).toBe('that username is taken');
    expect(describeError(e2)).toBe('You are not allowed to do that.');
    expect(describeError(new Error('boom'))).toBe('Something went wrong. Try again.');
  });
});

describe('who may manage whom (mirrors admin-policy.js)', () => {
  const admin = { ...OWNER, userId: 'a2', isOwner: false };
  const member = person(1);
  const otherAdmin = person(2, { role: 'admin' });
  const owner = { ...OWNER, status: 'active' };

  it('nobody manages themselves here', () => {
    expect(canManage(OWNER, OWNER)).toBe(false);
  });
  it('only the owner can manage an administrator, and nobody but the owner touches the owner', () => {
    expect(canManage(OWNER, otherAdmin)).toBe(true);
    expect(canManage(admin, otherAdmin)).toBe(false);
    expect(canManage(admin, owner)).toBe(false);
  });
  it('moderators manage members only', () => {
    expect(canManage(MODERATOR, member)).toBe(true);
    expect(canManage(MODERATOR, person(3, { role: 'moderator' }))).toBe(false);
  });
  it('only the owner can make administrators; moderators cannot create or delete', () => {
    expect(capabilities(OWNER).makeAdmins).toBe(true);
    expect(capabilities(admin).makeAdmins).toBe(false);
    expect(capabilities(MODERATOR)).toMatchObject({ createUsers: false, deleteUsers: false, editContacts: true });
  });
});
