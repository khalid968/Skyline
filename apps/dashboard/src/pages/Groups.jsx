import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { api, describeError } from '../lib/api';
import { useAuth, capabilities } from '../lib/auth';
import { Avatar, Dialog, Notice, formatDate } from '../components/ui';

// Board 31: groups. Admins and moderators create them, rename them, change who
// is in them and archive them (owner decision, 2026-09-25). Members can leave
// by themselves in the app; only an operator can add them back. Operators
// never see what anyone writes in a group.
export default function Groups() {
  const { me } = useAuth();
  const can = capabilities(me);
  const [params, setParams] = useSearchParams();
  const selectedId = params.get('group');
  const [groups, setGroups] = useState(null);
  const [error, setError] = useState('');
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    try {
      setGroups(await api.groups());
    } catch (err) {
      setError(describeError(err));
    }
  }, []);
  useEffect(() => {
    load();
  }, [load]);

  const live = (groups || []).filter((g) => !g.archivedAt).length;

  return (
    <>
      <header className="topbar">
        <div>
          <h1>Groups</h1>
          <div className="topbar-sub">
            Members see and write in the groups you add them to, and nothing else. You never see what they write.
          </div>
        </div>
        {can.manageGroups && (
          <button type="button" className="btn primary" onClick={() => setCreating(true)}>
            New group
          </button>
        )}
      </header>
      <div className="content" style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 20 }}>
        <div className="picker">
          <div className="label" style={{ padding: '14px 16px', borderBottom: '1px solid var(--border)' }}>
            {groups ? `${live} ${live === 1 ? 'GROUP' : 'GROUPS'}` : 'GROUPS'}
          </div>
          <div className="picker-list" role="list">
            {error && <p className="error" role="alert">{error}</p>}
            {!groups && !error && <span className="muted small" style={{ padding: 10 }}>Loading…</span>}
            {groups && groups.length === 0 && (
              <div className="empty">No groups yet. People can only talk one to one until you make one.</div>
            )}
            {(groups || []).map((g) => (
              <button
                key={g.groupId}
                role="listitem"
                className="picker-item"
                aria-current={g.groupId === selectedId}
                onClick={() => setParams({ group: g.groupId })}
              >
                <Avatar name={g.name} seed={g.groupId} square />
                <span style={{ flex: 1, minWidth: 0 }}>
                  <span className="who-name" style={{ display: 'block' }}>{g.name}</span>
                  <span className="who-handle">
                    {g.archivedAt
                      ? `Archived ${formatDate(g.archivedAt)}`
                      : `${g.members} ${g.members === 1 ? 'member' : 'members'} · created ${formatDate(g.createdAt)}`}
                  </span>
                </span>
              </button>
            ))}
          </div>
        </div>

        <div style={{ flex: 1, minWidth: 0 }}>
          {selectedId ? (
            <GroupDetail key={selectedId} groupId={selectedId} canEdit={can.manageGroups} onChanged={load} />
          ) : (
            <div className="card">
              <div className="empty">Choose a group on the left to see and change who is in it.</div>
            </div>
          )}
        </div>
      </div>
      {creating && (
        <NewGroup
          onClose={() => setCreating(false)}
          onCreated={async (g) => {
            setCreating(false);
            await load();
            setParams({ group: g.groupId });
          }}
        />
      )}
    </>
  );
}

function GroupDetail({ groupId, canEdit, onChanged }) {
  const [g, setG] = useState(null);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [people, setPeople] = useState(null);
  const [find, setFind] = useState('');
  const [busy, setBusy] = useState({});
  const [error, setError] = useState('');
  const [saved, setSaved] = useState(false);

  const load = useCallback(async () => {
    try {
      const d = await api.group(groupId);
      setG(d);
      setName(d.name);
      setDescription(d.description ?? '');
    } catch (err) {
      setError(describeError(err));
    }
  }, [groupId]);
  useEffect(() => {
    load();
  }, [load]);
  useEffect(() => {
    if (canEdit) api.users().then(setPeople).catch(() => setPeople([]));
  }, [canEdit]);

  const current = (g?.history || []).filter((m) => !m.removedAt);
  const past = (g?.history || []).filter((m) => m.removedAt);
  const inGroup = new Set(current.map((m) => m.userId));
  const candidates = useMemo(() => {
    const f = find.trim().toLowerCase();
    if (!f || !people) return [];
    return people
      .filter((u) => !inGroup.has(u.userId) && u.status !== 'deleted')
      .filter((u) => u.displayName.toLowerCase().includes(f) || u.username.includes(f))
      .slice(0, 8);
  }, [find, people, g]);

  const act = async (key, fn) => {
    setError('');
    setBusy((b) => ({ ...b, [key]: true }));
    try {
      await fn();
      await load();
      onChanged();
    } catch (err) {
      setError(describeError(err));
    } finally {
      setBusy((b) => ({ ...b, [key]: false }));
    }
  };

  const setMember = (person, member) =>
    act(person.userId, () => api.setGroupMember(groupId, person.userId, member));

  const save = (e) => {
    e.preventDefault();
    setSaved(false);
    act('save', async () => {
      await api.updateGroup(groupId, { name: name.trim(), description: description.trim() });
      setSaved(true);
    });
  };

  if (!g) {
    return (
      <div className="card">
        {error ? <p className="error" role="alert">{error}</p> : <span className="muted small">Loading…</span>}
      </div>
    );
  }
  const archived = Boolean(g.archivedAt);
  const locked = !canEdit || archived;
  const changed = name.trim() !== g.name || description.trim() !== (g.description ?? '');

  return (
    <div className="card stack">
      {archived && (
        <Notice kind="warn">
          This group is archived. Nobody can write in it, and its members keep only what is already on their devices.
        </Notice>
      )}
      {!canEdit && <Notice kind="info" icon="lock">You can look, but only administrators and moderators can change groups.</Notice>}

      <form onSubmit={save} className="stack">
        <div className="row" style={{ gap: 14, alignItems: 'flex-end' }}>
          <div className="field" style={{ flex: 1 }}>
            <label htmlFor="group-name">Name</label>
            <input id="group-name" className="input" maxLength={80} value={name} disabled={locked}
              onChange={(e) => { setName(e.target.value); setSaved(false); }} />
          </div>
          <div className="field" style={{ flex: 2 }}>
            <label htmlFor="group-description">Description (members see it)</label>
            <input id="group-description" className="input" maxLength={500} value={description} disabled={locked}
              onChange={(e) => { setDescription(e.target.value); setSaved(false); }} />
          </div>
          {!locked && (
            <button type="submit" className="btn primary" disabled={!changed || !name.trim() || busy.save}>
              Save
            </button>
          )}
        </div>
        <span className="hint">
          {saved ? 'Saved. ' : ''}A rename is announced in the group, like a user rename. Members set the disappearing
          timer themselves.
        </span>
      </form>

      <div className="row between">
        <span className="label">MEMBERS · {current.length}</span>
        {!locked && (
          <div style={{ position: 'relative', width: 340 }}>
            <label htmlFor="add-member" className="sr-only">Add a member by name or username</label>
            <input id="add-member" className="input search" placeholder="Add a member by name or username"
              value={find} onChange={(e) => setFind(e.target.value)} autoComplete="off" />
            {candidates.length > 0 && (
              <div className="menu" role="listbox" aria-label="People to add">
                {candidates.map((u) => (
                  <button key={u.userId} type="button" role="option" aria-selected="false" className="picker-item"
                    disabled={busy[u.userId]}
                    onClick={async () => { await setMember(u, true); setFind(''); }}>
                    <Avatar name={u.displayName} seed={u.userId} />
                    <span style={{ flex: 1, minWidth: 0 }}>
                      <span className="who-name" style={{ display: 'block' }}>{u.displayName}</span>
                      <span className="who-handle">@{u.username}</span>
                    </span>
                    <span className="small muted">Add</span>
                  </button>
                ))}
              </div>
            )}
          </div>
        )}
      </div>
      {error && <p className="error" role="alert">{error}</p>}

      {current.length === 0 && <div className="empty">Nobody is in this group yet.</div>}
      <div className="member-grid">
        {current.map((m) => (
          <MemberRow key={m.userId} m={m} note={`Added ${formatDate(m.addedAt)}`}
            action={!locked && (
              <button type="button" className="btn small danger" disabled={busy[m.userId]}
                aria-label={`Remove ${m.displayName}`} onClick={() => setMember(m, false)}>
                Remove
              </button>
            )} />
        ))}
        {past.map((m) => (
          <MemberRow key={m.userId} m={m} faded
            note={`${m.left ? 'Left the group' : 'Removed'} ${formatDate(m.removedAt)}`}
            action={!locked && m.status !== 'deleted' && (
              <button type="button" className="btn small" disabled={busy[m.userId]}
                aria-label={`Add ${m.displayName} back`} onClick={() => setMember(m, true)}>
                Add back
              </button>
            )} />
        ))}
      </div>

      <div className="row between" style={{ paddingTop: 14, borderTop: '1px solid var(--border)' }}>
        <span className="hint">
          Removing someone stops their messages at once. New messages use new keys they do not have. Every change is in
          the audit log.
        </span>
        {canEdit && (
          <button type="button" className={`btn ${archived ? '' : 'danger'}`} disabled={busy.archive}
            onClick={() => act('archive', () => api.archiveGroup(groupId, !archived))}>
            {archived ? 'Reopen group' : 'Archive group'}
          </button>
        )}
      </div>
    </div>
  );
}

function MemberRow({ m, note, action, faded = false }) {
  return (
    <div className="member-row" style={{ opacity: faded ? 0.6 : 1 }}>
      <Avatar name={m.displayName} seed={m.userId} />
      <span style={{ flex: 1, minWidth: 0 }}>
        <Link className="who-name" style={{ display: 'block' }} to={`/users/${m.userId}`}>{m.displayName}</Link>
        <span className="who-handle">{note}</span>
      </span>
      {action}
    </div>
  );
}

function NewGroup({ onClose, onCreated }) {
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      onCreated(await api.createGroup({ name: name.trim(), description: description.trim() || undefined }));
    } catch (err) {
      setError(describeError(err));
      setBusy(false);
    }
  };

  return (
    <Dialog title="New group" onClose={onClose}>
      <form onSubmit={submit} className="stack">
        <div className="field">
          <label htmlFor="new-group-name">Name</label>
          <input id="new-group-name" className="input" maxLength={80} value={name} autoFocus
            onChange={(e) => setName(e.target.value)} />
        </div>
        <div className="field">
          <label htmlFor="new-group-description">Description (optional, members see it)</label>
          <input id="new-group-description" className="input" maxLength={500} value={description}
            onChange={(e) => setDescription(e.target.value)} />
        </div>
        <span className="hint">You add members next. Only people you add can see the group.</span>
        {error && <p className="error" role="alert">{error}</p>}
        <div className="row end">
          <button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button type="submit" className="btn primary" disabled={!name.trim() || busy}>Create group</button>
        </div>
      </form>
    </Dialog>
  );
}
