import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, describeError } from '../lib/api';
import { useAuth, canManage } from '../lib/auth';
import { Dialog, Icon, timeAgo } from '../components/ui';
import { ALERTS_CHANGED } from '../components/Shell';

// Board 37: unusual activity, from counts and timing alone. Skyline slows
// things down by itself; suspending someone is always an operator's decision.
export default function Alerts() {
  const { me } = useAuth();
  const [state, setState] = useState('open');
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [suspending, setSuspending] = useState(null);

  const load = useCallback(async () => {
    try {
      setData(await api.alerts(state));
      setError('');
    } catch (err) {
      setError(describeError(err));
    }
  }, [state]);
  useEffect(() => {
    load();
  }, [load]);

  const changed = () => {
    window.dispatchEvent(new Event(ALERTS_CHANGED));
    load();
  };
  const act = async (fn) => {
    try {
      await fn();
      changed();
    } catch (err) {
      setError(describeError(err));
      load();
    }
  };

  return (
    <>
      <header className="topbar">
        <div>
          <h1>Alerts</h1>
          <div className="topbar-sub">
            Unusual activity, spotted from timing and counts alone. Skyline slows things down by itself; suspending
            someone is always your call.
          </div>
        </div>
        <div className="tabs" role="group" aria-label="Which alerts">
          <button aria-pressed={state === 'open'} onClick={() => setState('open')}>
            Open · {data?.open ?? '…'}
          </button>
          <button aria-pressed={state === 'reviewed'} onClick={() => setState('reviewed')}>
            Reviewed · {data?.reviewed ?? '…'}
          </button>
        </div>
      </header>
      <div className="content">
        {error && <p className="error" role="alert">{error}</p>}
        <div className="columns">
          <div className="col-main" style={{ gap: 12 }}>
            {data && data.alerts.length === 0 && (
              <div className="card empty">{state === 'open' ? 'Nothing needs you right now.' : 'No reviewed alerts yet.'}</div>
            )}
            {data?.alerts.map((a) => {
              const t = describe(a);
              const mayManage = a.subject && canManage(me, a.subject);
              return (
                <article key={a.alertId} className={`alert-card ${a.level}`} aria-label={t.title}>
                  <div className="row" style={{ alignItems: 'flex-start', gap: 12 }}>
                    <span className={`level ${a.level}`}>{a.level.toUpperCase()}</span>
                    <span className="stack" style={{ flex: 1, gap: 3 }}>
                      <span style={{ fontSize: 14.5, fontWeight: 600, color: 'var(--text)' }}>{t.title}</span>
                      <span className="small muted">{t.evidence}</span>
                    </span>
                    <span className="hint" style={{ flexShrink: 0 }}>
                      {timeAgo(a.updatedAt)}
                    </span>
                  </div>
                  <div className={`auto${a.liftedAt ? ' lifted' : ''}`}>
                    <Icon name="clock" size={15} />
                    <span style={{ flex: 1 }}>{autoLine(a)}</span>
                    {a.limitActive && !a.reviewedAt && (
                      <button className="btn small" onClick={() => act(() => api.liftAlert(a.alertId))}>
                        Lift now
                      </button>
                    )}
                  </div>
                  {a.reviewedAt ? (
                    <span className="small" style={{ color: 'var(--ok)' }}>
                      Reviewed by {a.reviewedBy} {timeAgo(a.reviewedAt).toLowerCase()} ·{' '}
                      {a.outcome === 'suspended' ? `${first(a.subject)} suspended` : 'no action'}
                    </span>
                  ) : (
                    <div className="row end">
                      {a.subject && (
                        <Link to={`/users/${a.subject.userId}`} className="small" style={{ marginRight: 'auto' }}>
                          Open {a.subject.displayName}
                        </Link>
                      )}
                      {mayManage && a.subject.status !== 'suspended' && (
                        <button className="btn small danger" onClick={() => setSuspending(a)}>
                          Suspend {first(a.subject)}
                        </button>
                      )}
                      <button className="btn small primary" onClick={() => act(() => api.reviewAlert(a.alertId, false))}>
                        Mark as reviewed
                      </button>
                    </div>
                  )}
                </article>
              );
            })}
          </div>

          <aside className="card" style={{ width: 330, flexShrink: 0 }}>
            <h3 style={{ fontSize: 15 }}>What Skyline does by itself</h3>
            {RULES.map(([when, then]) => (
              <div key={when} className="detail-field">
                <span className="small" style={{ fontWeight: 600, color: 'var(--text-2)' }}>
                  {when}
                </span>
                <span className="hint">{then}</span>
              </div>
            ))}
            <span className="hint">
              Alerts look only at counts and timing. Skyline cannot see what anyone writes, so it cannot flag content,
              and it never will.
            </span>
          </aside>
        </div>
      </div>

      {suspending && (
        <Dialog title={`Suspend ${suspending.subject.displayName}?`} onClose={() => setSuspending(null)}>
          <p style={{ margin: 0 }}>
            They are signed out on every device at once and cannot send or receive until someone reinstates them. The
            alert is marked reviewed.
          </p>
          <div className="row end">
            <button className="btn" onClick={() => setSuspending(null)}>
              Cancel
            </button>
            <button
              className="btn danger-fill"
              onClick={() => {
                const a = suspending;
                setSuspending(null);
                act(() => api.reviewAlert(a.alertId, true));
              }}
            >
              Suspend and mark reviewed
            </button>
          </div>
        </Dialog>
      )}
    </>
  );
}

const RULES = [
  ['A device sends far faster than a person can', 'That device is slowed to 1 message every 5 seconds for 30 minutes. Its person can still read and call.'],
  ['Wrong activation codes keep coming from one address', 'That address cannot try codes for 1 hour. Real codes stay valid.'],
  ['Wrong dashboard passwords for one account', 'Sign-in to that account pauses for 15 minutes.'],
  ['Several new devices for one person', 'Alert only. Devices need a code you issued, so you check with the person.'],
  ['Media uploads far above normal', 'That device is slowed to one upload at a time for 30 minutes.'],
];

const first = (subject) => subject?.displayName.split(' ')[0] ?? '';

// The words on each card, from the alert's kind and its evidence.
export function describe(a) {
  const e = a.evidence || {};
  const who = a.subject?.displayName;
  const device = a.device ? `${who}'s ${a.device.name}` : who;
  switch (a.kind) {
    case 'send_rate':
      return {
        title: `${device} is sending far faster than a person types`,
        evidence: `${e.messages} messages in ${e.minutes} minutes (usual for anyone: under 40). Could be a stuck app or a stolen device.`,
      };
    case 'upload_rate':
      return {
        title: `${device} is uploading far more than usual`,
        evidence: `${e.uploads} uploads started in ${e.minutes} minutes.`,
      };
    case 'code_guessing':
      return {
        title: 'Someone is guessing activation codes',
        evidence: `${e.wrongAttempts} wrong codes in under ${e.minutes} minutes from one internet address (${a.ip}). All were refused.`,
      };
    case 'admin_password':
      return {
        title: `Wrong passwords for the dashboard account "${a.subject?.username}"`,
        evidence: `${e.wrongAttempts} wrong passwords or codes in ${e.minutes} minutes.`,
      };
    case 'device_burst':
      return {
        title: `${e.devices} new devices for ${who} in one hour`,
        evidence: 'Each was activated with a code an operator issued. Check this was them.',
      };
    default:
      return { title: a.kind, evidence: '' };
  }
}

function autoLine(a) {
  if (a.liftedAt) return `Lifted by ${a.liftedBy} ${timeAgo(a.liftedAt).toLowerCase()}. The limit is off.`;
  if (a.limitActive) return `${a.autoAction}, until ${clock(a.limitUntil)}.`;
  if (a.limitUntil) return `${a.autoAction} (ended ${clock(a.limitUntil)}).`;
  return a.autoAction;
}

const clock = (v) => new Date(v).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
