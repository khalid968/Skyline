import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, describeError } from '../lib/api';
import { useAuth, capabilities, canManage } from '../lib/auth';
import {
  Avatar,
  Dialog,
  Icon,
  Notice,
  OneTimeSecret,
  OwnerPill,
  ROLE_LABEL,
  StatusPill,
  formatDate,
  timeAgo,
} from '../components/ui';

// Board 8: one person's account.
export default function UserDetail() {
  const { userId } = useParams();
  const { me, refresh: refreshMe } = useAuth();
  const can = capabilities(me);
  const navigate = useNavigate();
  const [user, setUser] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [dialog, setDialog] = useState(null); // { kind, ... }

  const load = useCallback(async () => {
    try {
      setUser(await api.user(userId));
    } catch (err) {
      setLoadError(describeError(err));
    }
  }, [userId]);
  useEffect(() => {
    load();
  }, [load]);

  if (loadError) return <div className="content"><p className="error" role="alert">{loadError}</p></div>;
  if (!user) return <div className="splash">Loading…</div>;

  const self = user.userId === me.userId;
  const manage = canManage(me, user);
  const deleted = user.status === 'deleted';
  const operator = user.role !== 'member';

  // Why the controls are missing, said plainly.
  let readOnly = null;
  if (deleted) readOnly = 'This account was deleted. Its username stays reserved and can never be reused.';
  else if (!self && !manage) {
    readOnly = user.isOwner
      ? "This is the owner's account. Only the owner can change it."
      : user.role === 'admin'
        ? 'Only the owner can change another administrator.'
        : 'Moderators can only manage members.';
  }

  return (
    <>
      <header className="topbar">
        <div className="row" style={{ gap: 13 }}>
          <Link to="/users" className="icon-btn" aria-label="Back to users">
            <Icon name="back" size={18} width={2.1} />
          </Link>
          <Avatar name={user.displayName} seed={user.userId} size="lg" />
          <div>
            <h1 className="row" style={{ gap: 10 }}>
              {user.displayName} {user.isOwner && <OwnerPill />}
            </h1>
            <div className="topbar-sub mono">
              @{user.username} · {ROLE_LABEL[user.role].toLowerCase()} ·{' '}
              <Link to={`/contacts?user=${user.userId}`}>{user.contacts} contacts</Link>
            </div>
          </div>
        </div>
        <StatusPill status={user.status} />
      </header>

      <div className="content">
        {readOnly && <Notice kind={deleted ? 'warn' : 'owner'} icon="lock">{readOnly}</Notice>}

        <div className="columns">
          <div className="col-main">
            {!deleted && (self || manage) && can.rename && (
              <RenameCard user={user} onSaved={(u) => { setUser(u); if (self) refreshMe(); }} />
            )}

            <div className="card">
              <h2>Activation codes</h2>
              {user.codes.length === 0 && <span className="muted small">No codes issued yet.</span>}
              {user.codes.map((c) => (
                <div key={c.codeId} className="row between" style={{ padding: '10px 12px', background: '#f7f9fd', border: '1px solid #e2e7f0', borderRadius: 10 }}>
                  <span className="small">
                    Issued {formatDate(c.issuedAt)}
                    {c.state === 'spent' && ` · redeemed ${formatDate(c.redeemedAt)}${c.redeemedOn ? ` on ${c.redeemedOn}` : ''}`}
                    {c.state === 'live' && ` · expires ${formatDate(c.expiresAt)}`}
                  </span>
                  <span className={`pill ${c.state === 'live' ? 'active' : 'neutral'}`}>
                    {{ spent: 'Spent', revoked: 'Revoked', expired: 'Expired', live: 'Live' }[c.state]}
                  </span>
                </div>
              ))}
              <Notice kind="info" icon="lock">
                A code can be redeemed exactly once. Once spent it is dead — issuing a new code does not revive it.
              </Notice>
              {!deleted && manage && can.codes && (
                <div className="row">
                  <button className="btn" disabled={!['pending', 'active'].includes(user.status)} onClick={() => setDialog({ kind: 'issue' })}>
                    Issue a new code
                  </button>
                  {user.codes.some((c) => c.state === 'live') && (
                    <button className="btn danger" onClick={() => setDialog({ kind: 'revokeCode' })}>
                      Revoke the live code
                    </button>
                  )}
                </div>
              )}
            </div>
          </div>

          <div className="col-side">
            {!deleted && !self && manage && (
              <div className="card">
                <h2>Role</h2>
                {can.changeRoles ? (
                  <RolePicker me={me} user={user} onChanged={(r) => { setUser(r.user); if (r.temporaryPassword) setDialog({ kind: 'secret', title: 'Temporary dashboard password', value: r.temporaryPassword }); }} />
                ) : (
                  <span>{ROLE_LABEL[user.role]}</span>
                )}
              </div>
            )}

            <div className="card">
              <h2>Devices</h2>
              {user.devices.filter((d) => !d.revokedAt).length === 0 && (
                <span className="muted small">No active devices.</span>
              )}
              {user.devices
                .filter((d) => !d.revokedAt)
                .map((d) => (
                  <div className="row" key={d.deviceId}>
                    <span className="icon-btn" aria-hidden="true">
                      <Icon name="device" size={15} />
                    </span>
                    <span style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontWeight: 600, fontSize: 12.5 }}>{d.name}</div>
                      <div className="hint">
                        {d.platform} · active {timeAgo(d.lastSeenAt || d.activatedAt).toLowerCase()}
                      </div>
                    </span>
                    {can.revokeDevices && (manage || self) && (
                      <button className="btn danger small" onClick={() => setDialog({ kind: 'revokeDevice', device: d })}>
                        Revoke
                      </button>
                    )}
                  </div>
                ))}
            </div>

            {!deleted && operator && manage && can.resetSignIn && (
              <div className="card">
                <h2>Dashboard sign-in</h2>
                <span className="small muted">
                  If {user.displayName.split(' ')[0]} is locked out, give them a new temporary password. You can also
                  switch off their two-factor sign-in if they lost their phone.
                </span>
                <button className="btn" onClick={() => setDialog({ kind: 'reset' })}>
                  Reset sign-in…
                </button>
              </div>
            )}

            {!deleted && !self && manage && (can.suspend || can.deleteUsers) && (
              <div className="card danger">
                <h2>Danger zone</h2>
                <div className="row">
                  {can.suspend &&
                    (user.status === 'suspended' ? (
                      <button className="btn" onClick={() => setDialog({ kind: 'reinstate' })}>
                        Reinstate
                      </button>
                    ) : (
                      <button className="btn danger" onClick={() => setDialog({ kind: 'suspend' })}>
                        Suspend
                      </button>
                    ))}
                  {can.deleteUsers && (
                    <button className="btn danger" onClick={() => setDialog({ kind: 'delete' })}>
                      Delete account
                    </button>
                  )}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      {dialog && (
        <ActionDialog
          dialog={dialog}
          user={user}
          onClose={() => setDialog(null)}
          onShowSecret={(title, value) => setDialog({ kind: 'secret', title, value })}
          onDone={async (next) => {
            if (next === 'deleted') return navigate('/users');
            await load();
          }}
        />
      )}
    </>
  );
}

function RenameCard({ user, onSaved }) {
  const [displayName, setDisplayName] = useState(user.displayName);
  const [username, setUsername] = useState(user.username);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const changed = displayName.trim() !== user.displayName || username !== user.username;

  const save = async (e) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      const body = {};
      if (displayName.trim() !== user.displayName) body.displayName = displayName.trim();
      if (username !== user.username) body.username = username;
      onSaved(await api.renameUser(user.userId, body));
    } catch (err) {
      setError(describeError(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="card" onSubmit={save}>
      <h2>Identity</h2>
      <div className="field">
        <label htmlFor="rename-display">Display name</label>
        <input id="rename-display" className="input" value={displayName} onChange={(e) => setDisplayName(e.target.value)} />
      </div>
      <div className="field">
        <label htmlFor="rename-username">Username</label>
        <input
          id="rename-username"
          className="input mono"
          autoCapitalize="none"
          spellCheck="false"
          value={username}
          onChange={(e) => setUsername(e.target.value.toLowerCase())}
        />
        <span className="hint">Old usernames are never given to anyone else.</span>
      </div>
      <Notice kind="warn">
        Every rename is written to the audit log and announced inside each of their conversations, so a name change
        cannot be used to quietly impersonate someone. It never touches their encryption keys.
      </Notice>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      <div className="row end">
        <button className="btn primary" disabled={!changed || busy || !displayName.trim()}>
          {busy ? 'Saving…' : 'Save changes'}
        </button>
      </div>
    </form>
  );
}

function RolePicker({ me, user, onChanged }) {
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const choose = async (role) => {
    if (role === user.role) return;
    setError('');
    setBusy(true);
    try {
      onChanged(await api.setRole(user.userId, role));
    } catch (err) {
      setError(describeError(err));
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <div className="seg" role="group" aria-label="Role">
        {['member', 'moderator', 'admin'].map((r) => (
          <button
            key={r}
            type="button"
            aria-pressed={user.role === r}
            disabled={busy || (r === 'admin' && !me.isOwner)}
            onClick={() => choose(r)}
          >
            {r === 'admin' ? 'Admin' : ROLE_LABEL[r]}
          </button>
        ))}
      </div>
      <span className="hint">
        {me.isOwner ? 'Only you, as the owner, can make or remove administrators.' : 'Only the owner can make someone an administrator.'}
      </span>
      {error && <p className="error" role="alert">{error}</p>}
    </>
  );
}

// Every confirmation and one-time result on this page.
function ActionDialog({ dialog, user, onClose, onDone, onShowSecret }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [resetTwoFactor, setResetTwoFactor] = useState(false);
  const first = user.displayName.split(' ')[0];

  // Resolves to { value } on success, or null after showing the error; the
  // dialog stays open on failure so the reason is visible.
  const run = async (fn, after) => {
    setBusy(true);
    setError('');
    try {
      const value = await fn();
      await onDone(after);
      return { value };
    } catch (err) {
      setError(describeError(err));
      return null;
    } finally {
      setBusy(false);
    }
  };
  const runThenClose = async (fn) => {
    if (await run(fn)) onClose();
  };

  const buttons = (label, action, danger = true) => (
    <>
      {error && <p className="error" role="alert">{error}</p>}
      <div className="row end">
        <button className="btn" onClick={onClose}>
          Cancel
        </button>
        <button className={`btn ${danger ? 'danger-fill' : 'primary'}`} disabled={busy} onClick={action}>
          {label}
        </button>
      </div>
    </>
  );

  switch (dialog.kind) {
    case 'secret':
      return (
        <Dialog title={dialog.title} onClose={onClose}>
          <OneTimeSecret label={dialog.title} value={dialog.value} note="This is the only time it is shown." />
          <div className="row end">
            <button className="btn primary" onClick={onClose}>
              Done
            </button>
          </div>
        </Dialog>
      );
    case 'issue':
      return (
        <Dialog title={`New activation code for ${first}?`} onClose={onClose}>
          <p style={{ margin: 0 }}>Any earlier unused code stops working at once. Use this to let {first} add another device, or replace a code that was lost.</p>
          {buttons('Issue code', async () => {
            const r = await run(() => api.issueCode(user.userId));
            if (r) onShowSecret('Activation code', r.value.activationCode);
          }, false)}
        </Dialog>
      );
    case 'revokeCode':
      return (
        <Dialog title="Revoke the live code?" onClose={onClose}>
          <p style={{ margin: 0 }}>It stops working immediately. Devices already activated are not affected.</p>
          {buttons('Revoke code', () => runThenClose(() => api.revokeCode(user.userId)))}
        </Dialog>
      );
    case 'revokeDevice':
      return (
        <Dialog title={`Revoke ${first}'s ${dialog.device.name}?`} onClose={onClose}>
          <p style={{ margin: 0 }}>It is signed out immediately and cannot connect again. To come back, {first} needs a new activation code.</p>
          <Notice kind="warn">Messages already on that device stay on it. Revoking stops new ones, but no one can reach into a phone and erase what it already holds.</Notice>
          {buttons('Revoke device', () => runThenClose(() => api.revokeDevice(dialog.device.deviceId)))}
        </Dialog>
      );
    case 'suspend':
      return (
        <Dialog title={`Suspend ${user.displayName}?`} onClose={onClose}>
          <p style={{ margin: 0 }}>They are signed out everywhere at once and cannot send or receive until reinstated. Nothing is deleted.</p>
          {buttons('Suspend', () => runThenClose(() => api.suspend(user.userId)))}
        </Dialog>
      );
    case 'reinstate':
      return (
        <Dialog title={`Reinstate ${user.displayName}?`} onClose={onClose}>
          <p style={{ margin: 0 }}>Their devices work again, with the same contacts as before.</p>
          {buttons('Reinstate', () => runThenClose(() => api.reinstate(user.userId)), false)}
        </Dialog>
      );
    case 'delete':
      return (
        <Dialog title={`Delete ${user.displayName}?`} onClose={onClose}>
          <p style={{ margin: 0 }}>
            This cannot be undone. Every device is signed out, every contact link and code is revoked, and the username
            <span className="mono"> @{user.username} </span>is reserved for ever.
          </p>
          {buttons('Delete account', () => run(() => api.deleteUser(user.userId), 'deleted'))}
        </Dialog>
      );
    case 'reset':
      return (
        <Dialog title={`Reset ${first}'s dashboard sign-in?`} onClose={onClose}>
          <p style={{ margin: 0 }}>They get a new temporary password, are signed out of every dashboard session, and must choose their own password next time.</p>
          <label className="row" style={{ gap: 8 }}>
            <input type="checkbox" checked={resetTwoFactor} onChange={(e) => setResetTwoFactor(e.target.checked)} />
            Also switch off their two-factor sign-in (they lost their phone)
          </label>
          {buttons('Reset sign-in', async () => {
            const r = await run(() => api.resetSignIn(user.userId, resetTwoFactor));
            if (r) onShowSecret('Temporary dashboard password', r.value.temporaryPassword);
          })}
        </Dialog>
      );
    default:
      return null;
  }
}
