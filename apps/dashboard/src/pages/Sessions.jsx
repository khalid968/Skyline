import { useCallback, useEffect, useMemo, useState } from 'react';
import { api, describeError } from '../lib/api';
import { useAuth, capabilities } from '../lib/auth';
import { Avatar, Dialog, Icon, ROLE_LABEL, timeAgo } from '../components/ui';

// Board 39: who is signed in to this dashboard, and where. Everyone sees and
// ends their own sessions; the owner sees and ends everyone's. Ending one
// takes effect on its very next click (the server checks every request).
export default function Sessions() {
  const { me } = useAuth();
  const can = capabilities(me);
  const [sessions, setSessions] = useState(null);
  const [error, setError] = useState('');
  const [asking, setAsking] = useState(false);
  const [done, setDone] = useState('');

  const load = useCallback(async () => {
    try {
      setSessions(await api.sessions());
      setError('');
    } catch (err) {
      setError(describeError(err));
    }
  }, []);
  useEffect(() => {
    load();
  }, [load]);

  const people = useMemo(() => {
    const byOperator = new Map();
    for (const s of sessions ?? []) {
      const key = s.operator.userId;
      if (!byOperator.has(key)) byOperator.set(key, { operator: s.operator, sessions: [] });
      byOperator.get(key).sessions.push(s);
    }
    return [...byOperator.values()];
  }, [sessions]);
  const others = (sessions ?? []).filter((s) => !s.current).length;

  const end = async (s) => {
    try {
      await api.revokeSession(s.sessionId);
      setDone(`${browser(s.userAgent)} is signed out.`);
      load();
    } catch (err) {
      setError(describeError(err));
    }
  };
  const endOthers = async () => {
    setAsking(false);
    try {
      const r = await api.revokeOtherSessions();
      setDone(`${r.signedOut} ${r.signedOut === 1 ? 'session' : 'sessions'} signed out.`);
      load();
    } catch (err) {
      setError(describeError(err));
    }
  };

  return (
    <>
      <header className="topbar">
        <div>
          <h1>Sessions</h1>
          <div className="topbar-sub">
            {can.allSessions
              ? 'Who is signed in to this dashboard, and where. Signing a session out takes effect on its very next click.'
              : 'Where you are signed in to this dashboard. Signing a session out takes effect on its very next click.'}
          </div>
        </div>
        <button className="btn danger" disabled={others === 0} onClick={() => setAsking(true)}>
          {can.allSessions ? 'Sign out everyone except me' : 'Sign out my other sessions'}
        </button>
      </header>
      <div className="content">
        {error && <p className="error" role="alert">{error}</p>}
        {done && (
          <p className="small" role="status" style={{ color: 'var(--ok)', margin: 0 }}>
            {done}
          </p>
        )}
        {people.map(({ operator, sessions: list }) => (
          <section key={operator.userId} className="table" aria-label={operator.displayName}>
            <div className="row" style={{ padding: '14px 18px', borderBottom: '1px solid #f0f3f8' }}>
              <Avatar name={operator.displayName} seed={operator.userId} />
              <span className="stack" style={{ flex: 1, gap: 1 }}>
                <span className="who-name">{operator.displayName}</span>
                <span className="hint">
                  {operator.isOwner ? 'Owner' : ROLE_LABEL[operator.role]} · two-factor{' '}
                  {operator.twoFactorEnabled ? 'on' : 'off'}
                </span>
              </span>
              <span className="hint">
                {list.length} {list.length === 1 ? 'session' : 'sessions'}
              </span>
            </div>
            <table>
              <tbody>
                {list.map((s) => (
                  <tr key={s.sessionId}>
                    <td style={{ width: '32%' }}>
                      <span className="row" style={{ gap: 9 }}>
                        <Icon name="sessions" size={16} />
                        {browser(s.userAgent)}
                        {s.current && <span className="tag-current">THIS SESSION</span>}
                      </span>
                    </td>
                    <td className="mono" style={{ fontSize: 12 }}>
                      {s.ip ?? '—'}
                    </td>
                    <td className="muted">Signed in {timeAgo(s.signedInAt).toLowerCase()}</td>
                    <td style={{ color: s.newAddress ? '#8a5a0b' : undefined }} className={s.newAddress ? '' : 'muted'}>
                      {s.current ? 'Active now' : `Active ${timeAgo(s.lastActiveAt).toLowerCase()}`}
                      {s.newAddress && ' · new address'}
                    </td>
                    <td style={{ textAlign: 'right', width: 120 }}>
                      {!s.current && (
                        <button
                          className="btn danger small"
                          aria-label={`Sign out ${operator.displayName}'s ${browser(s.userAgent)}`}
                          onClick={() => end(s)}
                        >
                          Sign out
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
        ))}
        <span className="hint">
          Member phones and computers are on the Devices page. They have no password, so the way to sign one out is to
          revoke it. You can sign out your own sessions{can.allSessions ? ', and as the owner anyone’s' : ''}; every
          sign-out is in the audit log.
        </span>
      </div>

      {asking && (
        <Dialog
          title={can.allSessions ? 'Sign out everyone except you?' : 'Sign out your other sessions?'}
          onClose={() => setAsking(false)}
        >
          <p style={{ margin: 0 }}>
            {can.allSessions
              ? 'Every other operator session ends now, including your own other browsers. They sign in again with their password and two-factor code. Use it if you think a sign-in was stolen.'
              : 'Your other browsers are signed out now. This one stays signed in.'}
          </p>
          <div className="row end">
            <button className="btn" onClick={() => setAsking(false)}>
              Cancel
            </button>
            <button className="btn danger-fill" onClick={endOthers}>
              Sign them out
            </button>
          </div>
        </Dialog>
      )}
    </>
  );
}

// "Mozilla/5.0 (Windows NT 10.0; ...) Firefox/131.0" -> "Firefox on Windows".
export function browser(ua) {
  if (!ua) return 'Unknown browser';
  const name = /Edg\//.test(ua)
    ? 'Edge'
    : /OPR\//.test(ua)
      ? 'Opera'
      : /Firefox\//.test(ua)
        ? 'Firefox'
        : /Chrome\//.test(ua)
          ? 'Chrome'
          : /Safari\//.test(ua)
            ? 'Safari'
            : null;
  const os = /Windows/.test(ua)
    ? 'Windows'
    : /iPhone|iPad/.test(ua)
      ? /iPad/.test(ua) ? 'iPad' : 'iPhone'
      : /Mac OS X|Macintosh/.test(ua)
        ? 'macOS'
        : /Android/.test(ua)
          ? 'Android'
          : /Linux/.test(ua)
            ? 'Linux'
            : null;
  if (name && os) return `${name} on ${os}`;
  return name || os || ua.slice(0, 40);
}
