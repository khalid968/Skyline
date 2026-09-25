import { useCallback, useEffect, useState } from 'react';
import { api, describeError } from '../lib/api';
import { Notice, timeAgo } from '../components/ui';

// Board 36: is every service up, and how much is Skyline used, in TOTALS.
// Nothing here is per person, and the server has no way to make it so.
const SERVICES = {
  server: 'Server',
  database: 'Database',
  realtime: 'Realtime (Redis)',
  storage: 'File storage',
  relay: 'Call relay',
};
const DOWN_TEXT = {
  database: 'Nothing works until it is back.',
  realtime: 'Messages still send; open apps hear about them late.',
  storage: 'Messages still work; photos, videos and files cannot upload or download.',
  relay: 'Messages still work; new calls cannot connect until it is back.',
};
const RANGES = [7, 14, 30];

export default function Overview() {
  const [days, setDays] = useState(14);
  const [data, setData] = useState(null);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      setData(await api.overview(days));
      setError('');
    } catch (err) {
      setError(describeError(err));
    }
  }, [days]);
  useEffect(() => {
    load();
    const timer = setInterval(load, 30000);
    return () => clearInterval(timer);
  }, [load]);

  const down = data?.services.filter((s) => !s.ok) ?? [];

  return (
    <>
      <header className="topbar">
        <div>
          <h1>Overview</h1>
          <div className="topbar-sub">Totals only. No one's messages, contacts or activity are shown here, and none can be.</div>
        </div>
        <div className="tabs" role="group" aria-label="Period">
          {RANGES.map((d) => (
            <button key={d} aria-pressed={d === days} onClick={() => setDays(d)}>
              {d} days
            </button>
          ))}
        </div>
      </header>
      <div className="content">
        {error && <p className="error" role="alert">{error}</p>}
        {down.map((s) => (
          <Notice key={s.id} kind="warn">
            <b>The {SERVICES[s.id].toLowerCase()} is not answering.</b> {DOWN_TEXT[s.id]} Checked{' '}
            {timeAgo(data.checkedAt).toLowerCase()}.
          </Notice>
        ))}
        {!data ? (
          !error && <div className="empty">Loading…</div>
        ) : (
          <>
            <div className="grid-5">
              {data.services.map((s) => (
                <div key={s.id} className={`service${s.ok ? '' : ' down'}`}>
                  <span className="service-name">
                    <span className="service-dot" />
                    {SERVICES[s.id]}
                  </span>
                  <span className="small" style={{ color: s.ok ? 'var(--ok)' : 'var(--danger)' }}>
                    {s.ok ? 'Healthy' : 'Not answering'}
                  </span>
                  <span className="hint">{serviceDetail(s, data)}</span>
                </div>
              ))}
            </div>

            <div className="grid-4">
              <Stat
                label="PEOPLE"
                value={data.totals.people}
                sub={`${data.totals.notActivated} not activated yet · ${data.totals.suspended} suspended`}
              />
              <Stat label="ACTIVE TODAY" value={data.totals.activeToday} sub="used Skyline in the last 24 hours" />
              <Stat
                label="DEVICES"
                value={data.totals.devices}
                sub={data.totals.people ? `${(data.totals.devices / data.totals.people).toFixed(1)} per person on average` : ' '}
              />
              <Stat label="WAITING MESSAGES" value={data.totals.waitingMessages} sub="encrypted, for offline devices" />
            </div>

            <div className="columns">
              <div className="card" style={{ flex: 2, minWidth: 0 }}>
                <div className="card-head">
                  <h3 style={{ fontSize: 15 }}>Messages and calls per day</h3>
                  <span className="row small muted" style={{ gap: 14 }}>
                    <span className="row" style={{ gap: 6 }}>
                      <span style={{ width: 10, height: 10, borderRadius: 3, background: 'var(--accent)' }} />
                      Messages
                    </span>
                    <span className="row" style={{ gap: 6 }}>
                      <span style={{ width: 10, height: 10, borderRadius: 3, background: '#2fa36b' }} />
                      Calls
                    </span>
                  </span>
                </div>
                <Bars perDay={data.perDay} />
                <div className="row hint" style={{ justifyContent: 'space-between' }}>
                  <span>{days} days ago</span>
                  <span>Today</span>
                </div>
                <span className="hint">
                  Counted by the server as messages pass through, never per person. Group messages count once.
                  Edits, reactions and call set-up travel as messages too. Calls are counted from relay sign-ins.
                </span>
              </div>

              <div className="col-side" style={{ width: 360 }}>
                <div className="card">
                  <h3 style={{ fontSize: 15 }}>Storage</h3>
                  <Meter
                    label="Media files"
                    value={`${bytes(data.storage.mediaBytes)} · ${data.storage.mediaFiles} files`}
                    pct={data.storage.disk ? data.storage.mediaBytes / data.storage.disk.totalBytes : 0}
                    color="var(--accent)"
                  />
                  <Meter
                    label="Database"
                    value={bytes(data.storage.databaseBytes)}
                    pct={data.storage.disk ? data.storage.databaseBytes / data.storage.disk.totalBytes : 0}
                    color="#7a5af0"
                  />
                  {data.storage.disk && (
                    <Meter
                      label="Disk free on the server"
                      value={`${bytes(data.storage.disk.freeBytes)} of ${bytes(data.storage.disk.totalBytes)}`}
                      pct={data.storage.disk.freeBytes / data.storage.disk.totalBytes}
                      color="#2fa36b"
                    />
                  )}
                  <span className="hint">Media files are deleted by the server at 30 days, encrypted all along.</span>
                </div>
                <div className="card" style={{ gap: 4 }}>
                  <h3 style={{ fontSize: 15, marginBottom: 6 }}>Server</h3>
                  <KV k="Version" v={data.server.version} />
                  <KV k="Up for" v={duration(data.server.uptimeSeconds)} />
                  <KV k="Requests per minute" v={data.server.requestsPerMinute.toLocaleString('en-GB')} />
                  <KV k="Errors in the last hour" v={data.server.errorsLastHour} bad={data.server.errorsLastHour > 0} />
                  <KV k="Slowest requests (p95)" v={data.server.p95Ms == null ? '—' : `${data.server.p95Ms} ms`} />
                  <KV k="Memory" v={bytes(data.server.memoryBytes)} />
                </div>
              </div>
            </div>
          </>
        )}
      </div>
    </>
  );
}

function serviceDetail(s, data) {
  if (!s.ok) return 'Checked just now';
  switch (s.id) {
    case 'server':
      return `Up ${duration(data.server.uptimeSeconds)}`;
    case 'realtime':
      return `${s.connectedDevices} devices connected`;
    case 'storage':
      return `${bytes(data.storage.mediaBytes)} used`;
    default:
      return `${s.ms} ms per check`;
  }
}

function Stat({ label, value, sub }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className="stat-value">{value.toLocaleString('en-GB')}</span>
      <span className="hint">{sub}</span>
    </div>
  );
}

function Bars({ perDay }) {
  const top = Math.max(1, ...perDay.map((d) => d.messages));
  const topCalls = Math.max(1, ...perDay.map((d) => d.calls));
  return (
    <div className="bars" role="img" aria-label="Messages and calls per day">
      {perDay.map((d) => (
        <div key={d.day} className="day" title={`${d.day}: ${d.messages} messages, ${d.calls} calls`}>
          <div className="m" style={{ height: `${(d.messages / top) * 100}%` }} />
          <div className="c" style={{ height: `${(d.calls / topCalls) * 60}%` }} />
        </div>
      ))}
    </div>
  );
}

function Meter({ label, value, pct, color }) {
  return (
    <div className="stack" style={{ gap: 5 }}>
      <span className="row small" style={{ justifyContent: 'space-between' }}>
        <span>{label}</span>
        <span className="muted">{value}</span>
      </span>
      <span className="meter">
        <span style={{ width: `${Math.min(100, Math.max(0.5, pct * 100))}%`, background: color }} />
      </span>
    </div>
  );
}

function KV({ k, v, bad }) {
  return (
    <span className="kv">
      <span>{k}</span>
      <span className="mono" style={{ fontSize: 12, color: bad ? 'var(--danger)' : undefined }}>
        {v}
      </span>
    </span>
  );
}

export function bytes(n) {
  if (!n) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  return `${(n / 1024 ** i).toFixed(i >= 3 ? 1 : 0)} ${units[i]}`;
}

export function duration(s) {
  if (s < 3600) return `${Math.max(1, Math.round(s / 60))} min`;
  if (s < 86400) return `${Math.round(s / 3600)} hours`;
  return `${Math.round(s / 86400)} days`;
}
