import { vi } from 'vitest';
import { render } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { AuthProvider } from '../lib/auth';
import App from '../App';

// A fake backend: routes are "METHOD /path" -> response or (body, call) => response.
// A response is { status, body } or just a body (200). Unmatched calls fail the test loudly.
export function fakeBackend(routes) {
  const calls = [];
  const fetchMock = vi.fn(async (url, init = {}) => {
    const path = url.replace(/^\/api/, '');
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method, path, body, headers: init.headers, credentials: init.credentials });
    let handler = routes[`${method} ${path}`];
    if (handler === undefined) throw new Error(`unexpected request ${method} ${path}`);
    if (typeof handler === 'function') handler = await handler(body, calls.at(-1));
    const { status = 200, body: out } = handler && typeof handler.status === 'number' ? handler : { body: handler };
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => {
        if (out === undefined) throw new Error('no body');
        return out;
      },
    };
  });
  vi.stubGlobal('fetch', fetchMock);
  return { calls, fetchMock };
}

export function renderApp(path = '/users') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AuthProvider>
        <App />
      </AuthProvider>
    </MemoryRouter>,
  );
}

export const OWNER = {
  userId: '00000000-0000-4000-8000-000000000001',
  username: 'owner',
  displayName: 'Olivia Owner',
  role: 'admin',
  isOwner: true,
  twoFactorEnabled: false,
  mustChangePassword: false,
};

export const MODERATOR = {
  userId: '00000000-0000-4000-8000-000000000002',
  username: 'mo',
  displayName: 'Mo Derator',
  role: 'moderator',
  isOwner: false,
  twoFactorEnabled: false,
  mustChangePassword: false,
};

export const person = (n, over = {}) => ({
  userId: `00000000-0000-4000-8000-0000000001${String(n).padStart(2, '0')}`,
  username: `person${n}`,
  displayName: `Person ${n}`,
  role: 'member',
  status: 'active',
  isOwner: false,
  devices: 1,
  contacts: 0,
  lastSeenAt: null,
  hasLiveCode: false,
  ...over,
});

export const UNAUTHORIZED = { status: 401, body: { statusCode: 401, message: 'Unauthorized' } };

// Board 36's data, as the server sends it.
export const OVERVIEW = {
  checkedAt: new Date().toISOString(),
  services: [
    { id: 'server', ok: true, ms: 0 },
    { id: 'database', ok: true, ms: 4 },
    { id: 'realtime', ok: true, ms: 2, connectedDevices: 118 },
    { id: 'storage', ok: true, ms: 9 },
    { id: 'relay', ok: true, ms: 3 },
  ],
  totals: { people: 146, notActivated: 9, suspended: 3, activeToday: 112, devices: 231, waitingMessages: 37 },
  perDay: Array.from({ length: 14 }, (_, i) => ({ day: `2026-09-${String(i + 10).padStart(2, '0')}`, messages: 100 + i, calls: i })),
  storage: {
    mediaBytes: 42 * 1024 ** 3,
    mediaFiles: 812,
    databaseBytes: 1.8 * 1024 ** 3,
    disk: { freeBytes: 612 * 1024 ** 3, totalBytes: 1000 * 1024 ** 3 },
  },
  server: { version: '0.0.1 · 0e2a91c', uptimeSeconds: 12 * 86400, requestsPerMinute: 1240, errorsLastHour: 0, p95Ms: 84, memoryBytes: 312 * 1024 ** 2 },
};
