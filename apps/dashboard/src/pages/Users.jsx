import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { api, describeError } from '../lib/api';
import { useAuth, capabilities } from '../lib/auth';
import { Avatar, Icon, OneTimeSecret, OwnerPill, ROLE_LABEL, StatusPill, timeAgo } from '../components/ui';

// Board 6: everyone in this Skyline, and creating someone new.
export default function Users() {
  const { me } = useAuth();
  const can = capabilities(me);
  const navigate = useNavigate();
  const [users, setUsers] = useState(null);
  const [error, setError] = useState('');
  const [filter, setFilter] = useState('');
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    try {
      setUsers(await api.users());
    } catch (err) {
      setError(describeError(err));
    }
  }, []);
  useEffect(() => {
    load();
  }, [load]);

  const shown = useMemo(() => {
    const f = filter.trim().toLowerCase();
    if (!users) return [];
    return f ? users.filter((u) => u.displayName.toLowerCase().includes(f) || u.username.includes(f)) : users;
  }, [users, filter]);

  const pending = users ? users.filter((u) => u.status === 'pending').length : 0;

  return (
    <>
      <header className="topbar">
        <div>
          <h1>Users</h1>
          <div className="topbar-sub">
            {users ? `${users.length} accounts · ${pending} waiting to activate` : 'Loading…'}
          </div>
        </div>
        <div className="row">
          <label htmlFor="filter" className="sr-only">
            Filter by name or username
          </label>
          <input
            id="filter"
            className="input search"
            style={{ width: 268 }}
            placeholder="Filter by name or username"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
          />
          {can.createUsers && (
            <button className="btn primary" onClick={() => setCreating(true)}>
              <Icon name="plus" size={15} width={2.3} />
              Create user
            </button>
          )}
        </div>
      </header>

      <div className="content">
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <div className="table">
          <table>
            <thead>
              <tr>
                <th>User</th>
                <th>Role</th>
                <th>Status</th>
                <th>Devices</th>
                <th>Contacts</th>
                <th>Last seen</th>
              </tr>
            </thead>
            <tbody>
              {shown.map((u) => (
                <tr
                  key={u.userId}
                  className="clickable"
                  onClick={() => navigate(`/users/${u.userId}`)}
                >
                  <td>
                    <a
                      href={`/users/${u.userId}`}
                      className="who"
                      onClick={(e) => {
                        e.preventDefault();
                        navigate(`/users/${u.userId}`);
                      }}
                    >
                      <Avatar name={u.displayName} seed={u.userId} />
                      <span style={{ display: 'flex', flexDirection: 'column', minWidth: 0 }}>
                        <span className="who-name">
                          {u.displayName} {u.isOwner && <OwnerPill />}
                        </span>
                        <span className="who-handle">@{u.username}</span>
                      </span>
                    </a>
                  </td>
                  <td>{ROLE_LABEL[u.role]}</td>
                  <td>
                    <StatusPill status={u.status} />
                  </td>
                  <td>{u.devices}</td>
                  <td>{u.contacts}</td>
                  <td className="muted">{u.status === 'pending' ? (u.hasLiveCode ? 'Code issued' : 'No live code') : timeAgo(u.lastSeenAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {users && shown.length === 0 && (
            <div className="empty">{filter ? 'Nobody matches that filter.' : 'No accounts yet. Create the first one.'}</div>
          )}
        </div>
      </div>

      {creating && (
        <CreateUserPanel
          me={me}
          everyone={users || []}
          onClose={() => setCreating(false)}
          onCreated={load}
        />
      )}
    </>
  );
}

const suggestUsername = (name) =>
  name
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '.')
    .replace(/^\.+|\.+$/g, '')
    .slice(0, 30);

export function CreateUserPanel({ me, everyone, onClose, onCreated }) {
  const [displayName, setDisplayName] = useState('');
  const [username, setUsername] = useState('');
  const [touchedUsername, setTouchedUsername] = useState(false);
  const [role, setRole] = useState('member');
  const [contacts, setContacts] = useState([]);
  const [search, setSearch] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);

  const effectiveUsername = touchedUsername ? username : suggestUsername(displayName);
  const candidates = everyone.filter(
    (u) =>
      u.status !== 'deleted' &&
      !contacts.some((c) => c.userId === u.userId) &&
      search.trim() &&
      (u.displayName.toLowerCase().includes(search.toLowerCase()) || u.username.includes(search.toLowerCase())),
  );

  const submit = async (e) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      const r = await api.createUser({
        displayName: displayName.trim(),
        username: effectiveUsername,
        role,
        contactIds: contacts.map((c) => c.userId),
      });
      setResult(r);
      onCreated();
    } catch (err) {
      setError(describeError(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="scrim" onClick={result ? onClose : undefined} />
      <aside className="panel" role="dialog" aria-modal="true" aria-labelledby="create-title">
        <div className="panel-head">
          <div>
            <h2 id="create-title">{result ? 'Account created' : 'Create user'}</h2>
            <span className="hint">Accounts exist only when you make them</span>
          </div>
          <button className="icon-btn" onClick={onClose} aria-label="Close panel">
            <Icon name="close" size={15} width={2.3} />
          </button>
        </div>

        {result ? (
          <>
            <div className="panel-body">
              <p style={{ margin: 0 }}>
                <b>{result.user.displayName}</b> <span className="mono muted">@{result.user.username}</span> can now
                activate a device.
              </p>
              <OneTimeSecret
                label="Activation code"
                value={result.activationCode}
                note="Single use · expires in 72 hours · binds to one device. Give it to them in person or over a call you trust."
              />
              {result.temporaryPassword && (
                <OneTimeSecret
                  label="Temporary dashboard password"
                  value={result.temporaryPassword}
                  note="They must choose their own password the first time they sign in to the dashboard."
                />
              )}
              <div className="notice warn">
                <Icon name="warn" size={16} width={2} />
                <span>This is the only time {result.temporaryPassword ? 'these are' : 'this is'} shown. Skyline does not keep a copy.</span>
              </div>
            </div>
            <div className="panel-foot">
              <button className="btn primary" onClick={onClose}>
                Done
              </button>
            </div>
          </>
        ) : (
          <form onSubmit={submit} style={{ display: 'contents' }}>
            <div className="panel-body">
              <div className="field">
                <label htmlFor="new-name">Full name</label>
                <input id="new-name" className="input" value={displayName} onChange={(e) => setDisplayName(e.target.value)} />
              </div>
              <div className="field">
                <label htmlFor="new-username">Username</label>
                <input
                  id="new-username"
                  className="input mono"
                  autoCapitalize="none"
                  spellCheck="false"
                  value={effectiveUsername}
                  onChange={(e) => {
                    setTouchedUsername(true);
                    setUsername(e.target.value.toLowerCase());
                  }}
                />
                <span className="hint">3–30 characters. Once used, a username is never given to anyone else.</span>
              </div>
              <div className="field">
                <span className="label" id="role-label">
                  Role
                </span>
                <div className="seg" role="group" aria-labelledby="role-label">
                  {['member', 'moderator', 'admin'].map((r) => (
                    <button
                      key={r}
                      type="button"
                      aria-pressed={role === r}
                      disabled={r === 'admin' && !me?.isOwner}
                      title={r === 'admin' && !me?.isOwner ? 'Only the owner can create administrators' : undefined}
                      onClick={() => setRole(r)}
                    >
                      {r === 'admin' ? 'Admin' : ROLE_LABEL[r]}
                    </button>
                  ))}
                </div>
                {role !== 'member' && (
                  <span className="hint">They also get a temporary password for this dashboard.</span>
                )}
              </div>
              <div className="field">
                <label htmlFor="contact-search">Initial contacts</label>
                {contacts.length > 0 && (
                  <div className="chips">
                    {contacts.map((c) => (
                      <span className="chip" key={c.userId}>
                        <Avatar name={c.displayName} seed={c.userId} size="sm" />
                        {c.displayName}
                        <button
                          type="button"
                          aria-label={`Remove ${c.displayName}`}
                          onClick={() => setContacts(contacts.filter((x) => x.userId !== c.userId))}
                        >
                          <Icon name="close" size={11} width={2.8} />
                        </button>
                      </span>
                    ))}
                  </div>
                )}
                <input
                  id="contact-search"
                  className="input search"
                  placeholder="Add from directory"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
                {candidates.length > 0 && (
                  <div className="suggest">
                    {candidates.slice(0, 8).map((u) => (
                      <button
                        type="button"
                        key={u.userId}
                        onClick={() => {
                          setContacts([...contacts, u]);
                          setSearch('');
                        }}
                      >
                        <Avatar name={u.displayName} seed={u.userId} size="sm" />
                        {u.displayName} <span className="mono muted">@{u.username}</span>
                      </button>
                    ))}
                  </div>
                )}
                <span className="hint">
                  They will see only the people added here, and cannot search or browse anyone else.
                </span>
              </div>
              {error && (
                <p className="error" role="alert">
                  {error}
                </p>
              )}
            </div>
            <div className="panel-foot">
              <button type="button" className="btn" onClick={onClose}>
                Cancel
              </button>
              <button className="btn primary" disabled={busy || !displayName.trim() || !effectiveUsername}>
                {busy ? 'Creating…' : 'Create user'}
              </button>
            </div>
          </form>
        )}
      </aside>
    </>
  );
}
