// The dashboard's session lives in an HttpOnly cookie, so a script running in
// the page (an XSS bug, a malicious dependency) cannot read or steal it.
//
// SameSite=Strict keeps the browser from sending it on cross-site requests,
// and every state-changing request that authenticates with it must also carry
// the X-Skyline-Client header (AuthenticatedGuard). A form or image on another
// site cannot add a custom header, so it cannot forge an admin action.

export const COOKIE_NAME = 'skyline_admin';
export const CLIENT_HEADER = 'x-skyline-client';
export const DASHBOARD_CLIENT = 'dashboard';

export const isDashboardClient = (req) =>
  req.headers[CLIENT_HEADER] === DASHBOARD_CLIENT;

export function setSessionCookie(res, token, expiresAt, secure) {
  const maxAge = Math.max(
    0,
    Math.floor((new Date(expiresAt).getTime() - Date.now()) / 1000),
  );
  res.setHeader(
    'Set-Cookie',
    `${COOKIE_NAME}=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAge}${secure ? '; Secure' : ''}`,
  );
}

export function clearSessionCookie(res, secure) {
  res.setHeader(
    'Set-Cookie',
    `${COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${secure ? '; Secure' : ''}`,
  );
}

export function readSessionCookie(req) {
  const header = req.headers.cookie;
  if (typeof header !== 'string') return null;
  for (const part of header.split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === COOKIE_NAME)
      return part.slice(i + 1).trim() || null;
  }
  return null;
}
