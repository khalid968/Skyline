import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { api, describeError } from '../lib/api';
import { useAuth, capabilities } from '../lib/auth';
import { Avatar, Notice, ROLE_LABEL, StatusPill } from '../components/ui';

// Board 7: who can talk to whom. Pick a person on the left; every switch on
// the right is one contact link. Links are always both ways.
export default function ContactGraph() {
  const { me } = useAuth();
  const can = capabilities(me);
  const [params, setParams] = useSearchParams();
  const selectedId = params.get('user');
  const [people, setPeople] = useState(null);
  const [pickerFilter, setPickerFilter] = useState('');
  const [error, setError] = useState('');

  const loadPeople = useCallback(async () => {
    try {
      setPeople(await api.users());
    } catch (err) {
      setError(describeError(err));
    }
  }, []);
  useEffect(() => {
    loadPeople();
  }, [loadPeople]);

  const shown = useMemo(() => {
    const f = pickerFilter.trim().toLowerCase();
    if (!people) return [];
    return f ? people.filter((u) => u.displayName.toLowerCase().includes(f) || u.username.includes(f)) : people;
  }, [people, pickerFilter]);

  const selected = people?.find((u) => u.userId === selectedId) || null;

  // Keep the left-hand counts honest without refetching everyone.
  const bump = (userId, otherId, delta) =>
    setPeople((list) =>
      list.map((u) => (u.userId === userId || u.userId === otherId ? { ...u, contacts: u.contacts + delta } : u)),
    );

  return (
    <>
      <header className="topbar">
        <div>
          <h1>Contact graph</h1>
          <div className="topbar-sub">People can see and message only who is switched on here — nobody else.</div>
        </div>
      </header>
      <div className="content" style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 20 }}>
        <div className="picker">
          <div style={{ padding: 12, borderBottom: '1px solid var(--border)' }}>
            <label htmlFor="picker-filter" className="sr-only">
              Find a person
            </label>
            <input
              id="picker-filter"
              className="input search"
              placeholder="Find a person"
              value={pickerFilter}
              onChange={(e) => setPickerFilter(e.target.value)}
            />
          </div>
          <div className="picker-list" role="list">
            {error && <p className="error" role="alert">{error}</p>}
            {!people && !error && <span className="muted small" style={{ padding: 10 }}>Loading…</span>}
            {shown.map((u) => (
              <button
                key={u.userId}
                role="listitem"
                className="picker-item"
                aria-current={u.userId === selectedId}
                onClick={() => setParams({ user: u.userId })}
              >
                <Avatar name={u.displayName} seed={u.userId} />
                <span style={{ flex: 1, minWidth: 0 }}>
                  <span className="who-name" style={{ display: 'block' }}>{u.displayName}</span>
                  <span className="who-handle">@{u.username}</span>
                </span>
                <span className={`count ${u.contacts === 0 ? 'zero' : ''}`} aria-label={`${u.contacts} contacts`}>
                  {u.contacts}
                </span>
              </button>
            ))}
          </div>
        </div>

        <div style={{ flex: 1, minWidth: 0 }}>
          {selected ? (
            <Directory key={selected.userId} person={selected} canEdit={can.editContacts} onChanged={bump} />
          ) : (
            <div className="card">
              <div className="empty">Choose a person on the left to see and change who they can talk to.</div>
            </div>
          )}
        </div>
      </div>
    </>
  );
}

function Directory({ person, canEdit, onChanged }) {
  const [entries, setEntries] = useState(null);
  const [filter, setFilter] = useState('');
  const [pending, setPending] = useState({});
  const [error, setError] = useState('');

  useEffect(() => {
    let live = true;
    api
      .contactsOf(person.userId)
      .then((rows) => live && setEntries(rows))
      .catch((err) => live && setError(describeError(err)));
    return () => {
      live = false;
    };
  }, [person.userId]);

  const toggle = async (other) => {
    const next = !other.linked;
    setError('');
    setPending((p) => ({ ...p, [other.userId]: true }));
    // Optimistic: flip now, put it back if the server says no.
    setEntries((list) => list.map((e) => (e.userId === other.userId ? { ...e, linked: next } : e)));
    try {
      const r = await api.setLink(person.userId, other.userId, next);
      if (r?.changed) onChanged(person.userId, other.userId, next ? 1 : -1);
    } catch (err) {
      setEntries((list) => list.map((e) => (e.userId === other.userId ? { ...e, linked: !next } : e)));
      setError(`${other.displayName}: ${describeError(err)}`);
    } finally {
      setPending((p) => ({ ...p, [other.userId]: false }));
    }
  };

  const f = filter.trim().toLowerCase();
  const shown = (entries || []).filter(
    (e) => !f || e.displayName.toLowerCase().includes(f) || e.username.includes(f),
  );
  const linkedCount = (entries || []).filter((e) => e.linked).length;
  const first = person.displayName.split(' ')[0];

  return (
    <div className="card">
      <div className="card-head">
        <div className="row" style={{ gap: 12 }}>
          <Avatar name={person.displayName} seed={person.userId} size="lg" />
          <div>
            <h2 style={{ margin: 0 }}>
              <Link to={`/users/${person.userId}`}>{person.displayName}</Link>
            </h2>
            <span className="hint">
              {entries ? `${linkedCount} ${linkedCount === 1 ? 'contact' : 'contacts'}` : 'Loading…'} · links work both ways
            </span>
          </div>
        </div>
        <StatusPill status={person.status} />
      </div>

      {entries && linkedCount === 0 && (
        <Notice kind="warn">{first} has no contacts yet, so the app will be empty for them. Switch someone on below.</Notice>
      )}
      {!canEdit && <Notice kind="info" icon="lock">You can look, but only administrators and moderators can change links.</Notice>}
      {error && <p className="error" role="alert">{error}</p>}

      <label htmlFor="dir-filter" className="sr-only">
        Filter the directory
      </label>
      <input
        id="dir-filter"
        className="input search"
        placeholder="Filter the directory"
        value={filter}
        onChange={(e) => setFilter(e.target.value)}
      />

      <div className="stack" style={{ gap: 2 }}>
        {shown.map((e) => (
          <div key={e.userId} className={`dir-item ${e.linked ? 'on' : ''}`}>
            <Avatar name={e.displayName} seed={e.userId} />
            <span style={{ flex: 1, minWidth: 0 }}>
              <span className="who-name" style={{ display: 'block' }}>{e.displayName}</span>
              <span className="who-handle">
                @{e.username}
                {e.role !== 'member' && ` · ${ROLE_LABEL[e.role].toLowerCase()}`}
                {e.status !== 'active' && ` · ${e.status}`}
              </span>
            </span>
            <button
              type="button"
              role="switch"
              className="switch"
              aria-checked={e.linked}
              aria-label={`${first} can talk to ${e.displayName}`}
              disabled={!canEdit || pending[e.userId]}
              onClick={() => toggle(e)}
            >
              <span />
            </button>
          </div>
        ))}
        {entries && shown.length === 0 && <div className="empty">Nobody matches that filter.</div>}
      </div>
    </div>
  );
}
