import { useCallback, useEffect, useState } from 'react';
import { api, describeError } from '../lib/api';
import { Avatar, Icon } from '../components/ui';

// Board 38: every change an operator or Skyline itself made. Owner and admins
// only. Entries can never be edited or deleted, by anyone (the database
// refuses); this page only reads them.
const FILTERS = [
  ['', 'All'],
  ['links', 'Links'],
  ['groups', 'Groups'],
  ['accounts', 'Accounts and devices'],
  ['signins', 'Sign-ins'],
  ['automatic', 'Automatic'],
];

const KINDS = {
  contacts: ['LINK', '#eef2fd', '#2a4fb8'],
  groups: ['GROUP', '#eef7f2', '#1f6b4a'],
  users: ['ACCOUNT', '#f4eefc', '#6a3fc4'],
  codes: ['ACCOUNT', '#f4eefc', '#6a3fc4'],
  devices: ['DEVICE', '#fbe9ea', '#b42f3a'],
  admin_auth: ['SIGN-IN', '#f2f4f8', '#475467'],
  sessions: ['SIGN-IN', '#f2f4f8', '#475467'],
  abuse: ['AUTO', '#fdf3e2', '#8a5a0b'],
  alerts: ['ALERT', '#fdf3e2', '#8a5a0b'],
};

// Plain words for each action; the unknown fall back to the action's name.
const WHAT = {
  'contacts.grant': 'Linked two people',
  'contacts.revoke': 'Unlinked two people',
  'users.create': 'Created an account',
  'users.rename': 'Renamed a person',
  'users.suspend': 'Suspended an account',
  'users.reinstate': 'Reinstated an account',
  'users.role': 'Changed a role',
  'users.delete': 'Deleted an account',
  'codes.issue': 'Issued an activation code',
  'codes.revoke': 'Revoked an activation code',
  'devices.activate': 'Activated a device',
  'devices.revoke': 'Revoked a device',
  'sessions.revoke': 'Ended a device session',
  'groups.create': 'Created a group',
  'groups.update': 'Changed a group',
  'groups.add_member': 'Added a member to a group',
  'groups.remove_member': 'Removed a member from a group',
  'groups.archive': 'Archived a group',
  'groups.reopen': 'Reopened a group',
  'groups.leave': 'Left a group',
  'admin_auth.login': 'Signed in to the dashboard',
  'admin_auth.login_failed': 'Failed to sign in',
  'admin_auth.password_change': 'Changed their password',
  'admin_auth.two_factor_enable': 'Turned two-factor on',
  'admin_auth.two_factor_disable': 'Turned two-factor off',
  'admin_auth.reset': 'Reset an operator’s sign-in',
  'admin_auth.session_revoke': 'Signed out a dashboard session',
  'admin_auth.sessions_revoke_others': 'Signed out other dashboard sessions',
  'abuse.auto_limit': 'Applied an automatic limit',
  'abuse.alert': 'Raised an alert',
  'alerts.lift': 'Lifted an automatic limit',
  'alerts.review': 'Reviewed an alert',
};

export default function AuditLog() {
  const [category, setCategory] = useState('');
  const [query, setQuery] = useState('');
  const [q, setQ] = useState('');
  const [entries, setEntries] = useState(null);
  const [next, setNext] = useState(null);
  const [selected, setSelected] = useState(null);
  const [error, setError] = useState('');

  // Typing settles for a moment before the server is asked.
  useEffect(() => {
    const timer = setTimeout(() => setQ(query.trim()), 300);
    return () => clearTimeout(timer);
  }, [query]);

  const load = useCallback(
    async (before) => {
      try {
        const r = await api.audit({ category, q, before });
        setEntries((prev) => (before ? [...prev, ...r.entries] : r.entries));
        setNext(r.next);
        if (!before) setSelected(r.entries[0] ?? null);
        setError('');
      } catch (err) {
        setError(describeError(err));
      }
    },
    [category, q],
  );
  useEffect(() => {
    load();
  }, [load]);

  return (
    <>
      <header className="topbar">
        <div>
          <h1>Audit log</h1>
          <div className="topbar-sub">
            Every change an operator or Skyline itself made. Entries can never be edited or deleted, by anyone. Owner
            and admins only.
          </div>
        </div>
        <a className="btn" href={api.auditExportUrl({ category, q })} download>
          <Icon name="download" size={15} />
          Download CSV
        </a>
      </header>
      <div className="content">
        <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
          <div className="filter-chips" role="group" aria-label="Show">
            {FILTERS.map(([key, label]) => (
              <button key={label} aria-pressed={category === key} onClick={() => setCategory(key)}>
                {label}
              </button>
            ))}
          </div>
          <label htmlFor="audit-filter" className="sr-only">
            Filter by operator or person
          </label>
          <input
            id="audit-filter"
            className="input search"
            style={{ width: 260, height: 36 }}
            placeholder="Filter by operator or person"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
        {error && <p className="error" role="alert">{error}</p>}
        <div className="columns">
          <div className="col-main">
            <div className="table">
              <table>
                <thead>
                  <tr>
                    <th style={{ width: 110 }}>When</th>
                    <th style={{ width: 170 }}>Who</th>
                    <th>What</th>
                    <th style={{ width: 190 }}>About</th>
                  </tr>
                </thead>
                <tbody>
                  {entries?.map((e) => {
                    const [kind, bg, fg] = kindOf(e.action);
                    return (
                      <tr
                        key={e.id}
                        className={`clickable${selected?.id === e.id ? ' selected' : ''}`}
                        onClick={() => setSelected(e)}
                      >
                        <td className="mono" style={{ fontSize: 11.5 }}>
                          {when(e.at)}
                        </td>
                        <td>
                          <Who actor={e.actor} action={e.action} />
                        </td>
                        <td style={{ whiteSpace: 'nowrap' }}>
                          <span className="row" style={{ gap: 8 }}>
                            <span className="kind" style={{ background: bg, color: fg }}>
                              {kind}
                            </span>
                            <button className="linkish" onClick={() => setSelected(e)}>
                              {WHAT[e.action] ?? e.action}
                            </button>
                          </span>
                        </td>
                        <td>{about(e)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
              {entries && entries.length === 0 && <div className="empty">Nothing matches.</div>}
            </div>
            {next && (
              <button className="btn" style={{ alignSelf: 'center' }} onClick={() => load(next)}>
                Show older entries
              </button>
            )}
          </div>

          {selected && (
            <aside className="card" style={{ width: 330, flexShrink: 0, position: 'sticky', top: 0 }} aria-label="Entry details">
              <span className="kind" style={{ alignSelf: 'flex-start', background: kindOf(selected.action)[1], color: kindOf(selected.action)[2] }}>
                {kindOf(selected.action)[0]}
              </span>
              <span style={{ fontSize: 15, fontWeight: 600, lineHeight: 1.4 }}>
                {WHAT[selected.action] ?? selected.action}
                {about(selected) ? ` — ${about(selected)}` : ''}
              </span>
              <Field k="When" v={new Date(selected.at).toLocaleString('en-GB')} mono />
              <Field k="By" v={byLine(selected)} />
              {selected.ip && <Field k="From" v={selected.ip} mono />}
              {Object.entries(selected.detail || {})
                .filter(([k]) => !['otherUserId', 'alertId', 'codeId'].includes(k))
                .map(([k, v]) => (
                  <Field key={k} k={label(k)} v={value(v)} />
                ))}
              <span className="hint">
                The log records who did what to whom, and never message content: there is none on the server to
                record.
              </span>
            </aside>
          )}
        </div>
      </div>
    </>
  );
}

// No actor: Skyline itself for automatic actions; otherwise nobody was
// signed in (a failed sign-in, for instance).
const automatic = (action) => action.startsWith('abuse.');

function byLine(e) {
  if (e.actor) return `${e.actor.displayName} (@${e.actor.username})`;
  return automatic(e.action) ? 'Skyline, automatically' : 'Someone not signed in';
}

function value(v) {
  if (v === true) return 'Yes';
  if (v === false) return 'No';
  return typeof v === 'object' ? JSON.stringify(v) : String(v);
}

function Who({ actor, action }) {
  if (!actor && !automatic(action)) return <span className="muted">Not signed in</span>;
  if (!actor)
    return (
      <span className="row" style={{ gap: 8 }}>
        <span className="avatar" style={{ width: 24, height: 24, fontSize: 10, borderRadius: 6, background: 'var(--ink)' }}>
          S
        </span>
        Skyline
      </span>
    );
  return (
    <span className="row" style={{ gap: 8, minWidth: 0 }}>
      <Avatar name={actor.displayName} seed={actor.userId} size="sm" />
      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{actor.displayName}</span>
    </span>
  );
}

function Field({ k, v, mono }) {
  return (
    <div className="detail-field">
      <span className="k">{k}</span>
      <span className={`v${mono ? ' mono' : ''}`}>{v}</span>
    </div>
  );
}

const kindOf = (action) => KINDS[action.split('.')[0]] ?? ['OTHER', '#f2f4f8', '#475467'];

export function about(e) {
  const parts = [];
  if (e.target) parts.push(e.target.displayName);
  if (e.other) parts[0] = `${parts[0] ?? ''} ↔ ${e.other.displayName}`;
  if (e.group) parts.push(e.group.name);
  if (e.device) parts.push(e.device.name);
  if (!parts.length && e.detail?.address) parts.push(e.detail.address);
  return parts.join(' · ');
}

function when(at) {
  const d = new Date(at);
  const today = new Date().toDateString() === d.toDateString();
  return today
    ? d.toLocaleTimeString('en-GB')
    : `${d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })} ${d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}`;
}

// "wrongAttempts" -> "Wrong attempts"
const label = (k) => k.replace(/([A-Z])/g, ' $1').replace(/^./, (c) => c.toUpperCase()).replace(/ ([A-Z])/g, (m) => m.toLowerCase());
