import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, describeError } from '../lib/api';
import { useAuth, capabilities, canManage } from '../lib/auth';
import { Avatar, Dialog, Icon, Notice, timeAgo, formatDate } from '../components/ui';

// Every signed-in phone and PC, and a way to cut one off at once.
export default function Devices() {
  const { me } = useAuth();
  const can = capabilities(me);
  const [devices, setDevices] = useState(null);
  const [people, setPeople] = useState({});
  const [filter, setFilter] = useState('');
  const [error, setError] = useState('');
  const [revoking, setRevoking] = useState(null);

  const load = useCallback(async () => {
    try {
      const [ds, us] = await Promise.all([api.devices(), api.users()]);
      setDevices(ds);
      setPeople(Object.fromEntries(us.map((u) => [u.userId, u])));
    } catch (err) {
      setError(describeError(err));
    }
  }, []);
  useEffect(() => {
    load();
  }, [load]);

  const shown = useMemo(() => {
    const f = filter.trim().toLowerCase();
    if (!devices) return [];
    return f
      ? devices.filter(
          (d) =>
            d.displayName.toLowerCase().includes(f) || d.username.includes(f) || d.name.toLowerCase().includes(f),
        )
      : devices;
  }, [devices, filter]);

  const mayRevoke = (d) => {
    if (!can.revokeDevices) return false;
    const owner = people[d.userId];
    return d.userId === me.userId || canManage(me, owner);
  };

  return (
    <>
      <header className="topbar">
        <div>
          <h1>Devices</h1>
          <div className="topbar-sub">{devices ? `${devices.length} active devices` : 'Loading…'}</div>
        </div>
        <label htmlFor="device-filter" className="sr-only">
          Filter by person or device
        </label>
        <input
          id="device-filter"
          className="input search"
          style={{ width: 268 }}
          placeholder="Filter by person or device"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
        />
      </header>
      <div className="content">
        {error && <p className="error" role="alert">{error}</p>}
        <div className="table">
          <table>
            <thead>
              <tr>
                <th>Person</th>
                <th>Device</th>
                <th>Activated</th>
                <th>Last active</th>
                <th aria-label="Actions" />
              </tr>
            </thead>
            <tbody>
              {shown.map((d) => (
                <tr key={d.deviceId}>
                  <td>
                    <Link to={`/users/${d.userId}`} className="who">
                      <Avatar name={d.displayName} seed={d.userId} />
                      <span style={{ display: 'flex', flexDirection: 'column', minWidth: 0 }}>
                        <span className="who-name">{d.displayName}</span>
                        <span className="who-handle">@{d.username}</span>
                      </span>
                    </Link>
                  </td>
                  <td>
                    <span className="row" style={{ gap: 8 }}>
                      <Icon name="device" size={15} />
                      <span>
                        {d.name} <span className="muted">· {d.platform}</span>
                      </span>
                    </span>
                  </td>
                  <td className="muted">{formatDate(d.activatedAt)}</td>
                  <td className="muted">{timeAgo(d.lastSeenAt)}</td>
                  <td style={{ textAlign: 'right' }}>
                    {mayRevoke(d) && (
                      <button className="btn danger small" onClick={() => setRevoking(d)}>
                        Revoke
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {devices && shown.length === 0 && (
            <div className="empty">{filter ? 'Nothing matches that filter.' : 'No devices are signed in yet.'}</div>
          )}
        </div>
      </div>

      {revoking && (
        <RevokeDialog
          device={revoking}
          onClose={() => setRevoking(null)}
          onDone={() => {
            setRevoking(null);
            load();
          }}
        />
      )}
    </>
  );
}

function RevokeDialog({ device, onClose, onDone }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const first = device.displayName.split(' ')[0];
  const revoke = async () => {
    setBusy(true);
    setError('');
    try {
      await api.revokeDevice(device.deviceId);
      onDone();
    } catch (err) {
      setError(describeError(err));
      setBusy(false);
    }
  };
  return (
    <Dialog title={`Revoke ${first}'s ${device.name}?`} onClose={onClose}>
      <p style={{ margin: 0 }}>
        It is signed out immediately and cannot connect again. To come back, {first} needs a new activation code.
      </p>
      <Notice kind="warn">
        Messages already on that device stay on it. Revoking stops new ones, but no one can reach into a phone and
        erase what it already holds.
      </Notice>
      {error && <p className="error" role="alert">{error}</p>}
      <div className="row end">
        <button className="btn" onClick={onClose}>
          Cancel
        </button>
        <button className="btn danger-fill" disabled={busy} onClick={revoke}>
          Revoke device
        </button>
      </div>
    </Dialog>
  );
}
