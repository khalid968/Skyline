// The dashboard's only way to reach the backend.
//
// - Same origin, always (/api is proxied): the session is an HttpOnly cookie
//   the browser attaches by itself. This code never sees or stores a token.
// - Every request carries X-Skyline-Client: dashboard. The backend refuses any
//   cookie-authenticated change without it, and another website cannot add a
//   custom header, so it cannot forge an admin action (CSRF).

export class ApiError extends Error {
  constructor(status, body) {
    super(`request failed with ${status}`);
    this.status = status;
    this.body = body;
  }

  // The backend passes a LIST of human-readable reasons through only for 400s
  // about the caller's own input; everything else is deliberately generic.
  get messages() {
    return Array.isArray(this.body?.message) ? this.body.message : [];
  }
}

let onUnauthorized = () => {};
export function setUnauthorizedHandler(fn) {
  onUnauthorized = fn;
}

// Sign-in steps answer 401 for a wrong password; that is not "your session
// ended", so it must not bounce the user around.
const SIGN_IN_PATHS = ['/admin/auth/login', '/admin/auth/mfa'];

export async function request(method, path, body) {
  const res = await fetch(`/api${path}`, {
    method,
    credentials: 'same-origin',
    headers: {
      'x-skyline-client': 'dashboard',
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  if (res.status === 204) return null;
  let data = null;
  try {
    data = await res.json();
  } catch {
    // an empty or non-JSON body; the status says enough
  }
  if (!res.ok) {
    if (res.status === 401 && !SIGN_IN_PATHS.includes(path)) onUnauthorized();
    throw new ApiError(res.status, data);
  }
  return data;
}

const get = (p) => request('GET', p);
const post = (p, b) => request('POST', p, b);
const patch = (p, b) => request('PATCH', p, b);
const q = (params) => {
  const s = new URLSearchParams(Object.entries(params).filter(([, v]) => v !== undefined && v !== '')).toString();
  return s ? `?${s}` : '';
};

export const api = {
  // own account
  login: (username, password) => post('/admin/auth/login', { username, password }),
  completeMfa: (mfaToken, code) => post('/admin/auth/mfa', { mfaToken, code }),
  logout: () => post('/admin/auth/logout'),
  me: () => get('/admin/auth/me'),
  changePassword: (currentPassword, newPassword) => post('/admin/auth/password', { currentPassword, newPassword }),
  beginTwoFactor: () => post('/admin/auth/two-factor/setup'),
  enableTwoFactor: (code) => post('/admin/auth/two-factor/enable', { code }),
  disableTwoFactor: (password, code) => post('/admin/auth/two-factor/disable', { password, code }),

  // people
  users: (params = {}) => get(`/admin/users${q(params)}`),
  user: (id) => get(`/admin/users/${id}`),
  createUser: (body) => post('/admin/users', body),
  renameUser: (id, body) => patch(`/admin/users/${id}`, body),
  suspend: (id) => post(`/admin/users/${id}/suspend`),
  reinstate: (id) => post(`/admin/users/${id}/reinstate`),
  setRole: (id, role) => post(`/admin/users/${id}/role`, { role }),
  deleteUser: (id) => post(`/admin/users/${id}/delete`),
  issueCode: (id) => post(`/admin/users/${id}/codes`),
  revokeCode: (id) => post(`/admin/users/${id}/codes/revoke`),
  resetSignIn: (id, resetTwoFactor) => post(`/admin/users/${id}/reset-sign-in`, { resetTwoFactor }),

  // contact graph
  contactsOf: (id) => get(`/admin/users/${id}/contacts`),
  setLink: (userId, otherUserId, linked) => post('/admin/contact-links', { userId, otherUserId, linked }),

  // devices
  devices: (params = {}) => get(`/admin/devices${q(params)}`),
  revokeDevice: (id) => post(`/admin/devices/${id}/revoke`),
};

// One sentence for whatever went wrong, for the error line under a form.
export function describeError(err, fallback = 'Something went wrong. Try again.') {
  if (err instanceof ApiError) {
    if (err.messages.length) return err.messages.join(' ');
    if (err.status === 403) return 'You are not allowed to do that.';
    if (err.status === 404) return 'That no longer exists. Refresh the page.';
    if (err.status === 429) return 'Too many attempts. Wait a few minutes and try again.';
    if (err.status >= 500) return 'The server could not do that right now. Try again shortly.';
  }
  return fallback;
}
