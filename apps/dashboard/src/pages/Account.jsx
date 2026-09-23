import { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { api, ApiError, describeError } from '../lib/api';
import { useAuth } from '../lib/auth';
import { Avatar, Notice, OwnerPill, ROLE_LABEL } from '../components/ui';

// Boards 11-12: your own account — password and two-factor sign-in.
export default function Account() {
  const { me, refresh, signOut } = useAuth();

  return (
    <>
      <header className="topbar">
        <div className="row" style={{ gap: 13 }}>
          <Avatar name={me.displayName} seed={me.userId} size="lg" />
          <div>
            <h1 className="row" style={{ gap: 10 }}>
              {me.displayName} {me.isOwner && <OwnerPill />}
            </h1>
            <div className="topbar-sub mono">
              @{me.username} · {ROLE_LABEL[me.role].toLowerCase()}
            </div>
          </div>
        </div>
        <button className="btn" onClick={signOut}>
          Sign out
        </button>
      </header>
      <div className="content">
        {me.mustChangePassword && (
          <Notice kind="warn" icon="lock">
            You signed in with a temporary password. Choose your own password to continue — the rest of the dashboard
            unlocks once you do.
          </Notice>
        )}
        {me.isOwner && !me.mustChangePassword && (
          <Notice kind="owner" icon="crown">
            You are the owner of this Skyline. Nobody can demote, suspend, rename or delete you, and only you can
            create or remove administrators. Turn on two-factor sign-in: this is the account that matters most.
          </Notice>
        )}
        <div className="columns">
          <div className="col-main">
            <ChangePassword forced={me.mustChangePassword} onChanged={refresh} />
          </div>
          <div className="col-side">
            {!me.mustChangePassword && <TwoFactor enabled={me.twoFactorEnabled} onChanged={refresh} />}
          </div>
        </div>
      </div>
    </>
  );
}

function ChangePassword({ forced, onChanged }) {
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [again, setAgain] = useState('');
  const [error, setError] = useState('');
  const [done, setDone] = useState(false);
  const [busy, setBusy] = useState(false);

  const tooShort = next.length > 0 && next.length < 12;
  const mismatch = again.length > 0 && next !== again;

  const submit = async (e) => {
    e.preventDefault();
    setError('');
    setDone(false);
    setBusy(true);
    try {
      await api.changePassword(current, next);
      setCurrent('');
      setNext('');
      setAgain('');
      setDone(true);
      await onChanged();
    } catch (err) {
      setError(
        err instanceof ApiError && err.status === 400 && !err.messages.length
          ? 'Your current password is not right.'
          : describeError(err),
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="card" onSubmit={submit}>
      <h2>{forced ? 'Choose your password' : 'Change password'}</h2>
      <div className="field">
        <label htmlFor="pw-current">{forced ? 'Temporary password' : 'Current password'}</label>
        <input id="pw-current" className="input" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} />
      </div>
      <div className="field">
        <label htmlFor="pw-new">New password</label>
        <input id="pw-new" className="input" type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} aria-describedby="pw-new-hint" />
        <span id="pw-new-hint" className={tooShort ? 'error' : 'hint'}>
          At least 12 characters. A few unrelated words is easier to remember than symbols.
        </span>
      </div>
      <div className="field">
        <label htmlFor="pw-again">New password again</label>
        <input id="pw-again" className="input" type="password" autoComplete="new-password" value={again} onChange={(e) => setAgain(e.target.value)} />
        {mismatch && <span className="error">The two new passwords do not match.</span>}
      </div>
      <span className="hint">Changing your password signs out your other dashboard sessions.</span>
      {error && <p className="error" role="alert">{error}</p>}
      {done && <Notice kind="ok" icon="check">Password changed.</Notice>}
      <div className="row end">
        <button className="btn primary" disabled={busy || !current || next.length < 12 || next !== again}>
          {busy ? 'Saving…' : 'Save password'}
        </button>
      </div>
    </form>
  );
}

// off -> setup (QR + secret, confirm with a code) -> on. Switching off needs
// the password AND a code, so a stolen session alone cannot do it.
function TwoFactor({ enabled, onChanged }) {
  const [setup, setSetup] = useState(null); // { secret, otpauthUri }
  const [qr, setQr] = useState('');
  const [code, setCode] = useState('');
  const [password, setPassword] = useState('');
  const [disabling, setDisabling] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!setup) return undefined;
    let live = true;
    QRCode.toDataURL(setup.otpauthUri, { margin: 1, width: 200 })
      .then((url) => live && setQr(url))
      .catch(() => live && setQr(''));
    return () => {
      live = false;
    };
  }, [setup]);

  const act = async (fn, badCode) => {
    setError('');
    setBusy(true);
    try {
      await fn();
      return true;
    } catch (err) {
      setError(err instanceof ApiError && err.status === 400 ? badCode : describeError(err));
      return false;
    } finally {
      setBusy(false);
    }
  };

  const begin = () =>
    act(async () => {
      setSetup(await api.beginTwoFactor());
    });

  const confirm = async (e) => {
    e.preventDefault();
    if (await act(() => api.enableTwoFactor(code), "That code didn't work. Check your phone's clock and try the next one.")) {
      setSetup(null);
      setCode('');
      await onChanged();
    }
  };

  const disable = async (e) => {
    e.preventDefault();
    if (await act(() => api.disableTwoFactor(password, code), 'That password and code did not both check out.')) {
      setDisabling(false);
      setCode('');
      setPassword('');
      await onChanged();
    }
  };

  const codeField = (
    <div className="field">
      <label htmlFor="tf-code">Six-digit code</label>
      <input
        id="tf-code"
        className="input code-input"
        inputMode="numeric"
        autoComplete="one-time-code"
        maxLength={6}
        value={code}
        onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
      />
    </div>
  );

  if (enabled) {
    return (
      <div className="card">
        <div className="card-head">
          <h2 style={{ margin: 0 }}>Two-factor sign-in</h2>
          <span className="pill active"><span className="dot" />On</span>
        </div>
        <span className="small muted">Signing in needs your password and a code from your authenticator app.</span>
        {disabling ? (
          <form className="stack" onSubmit={disable}>
            <div className="field">
              <label htmlFor="tf-password">Password</label>
              <input id="tf-password" className="input" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
            </div>
            {codeField}
            {error && <p className="error" role="alert">{error}</p>}
            <div className="row end">
              <button type="button" className="btn" onClick={() => { setDisabling(false); setError(''); }}>
                Cancel
              </button>
              <button className="btn danger-fill" disabled={busy || !password || code.length !== 6}>
                Turn off
              </button>
            </div>
          </form>
        ) : (
          <button className="btn danger" onClick={() => setDisabling(true)}>
            Turn off two-factor…
          </button>
        )}
      </div>
    );
  }

  if (setup) {
    return (
      <form className="card" onSubmit={confirm}>
        <h2>Set up two-factor sign-in</h2>
        <span className="small">1. Scan this with an authenticator app (Google Authenticator, Microsoft Authenticator, 1Password…).</span>
        {qr ? (
          <img src={qr} alt="QR code for your authenticator app" width={200} height={200} style={{ alignSelf: 'center', borderRadius: 8 }} />
        ) : (
          <span className="muted small">Drawing the QR code…</span>
        )}
        <span className="hint">Can’t scan? Type this key instead:</span>
        <span className="mono" style={{ wordBreak: 'break-all', fontSize: 13 }} data-testid="totp-secret">
          {setup.secret}
        </span>
        <span className="small">2. Enter the code it shows, to prove it works.</span>
        {codeField}
        {error && <p className="error" role="alert">{error}</p>}
        <div className="row end">
          <button type="button" className="btn" onClick={() => { setSetup(null); setCode(''); setError(''); }}>
            Cancel
          </button>
          <button className="btn primary" disabled={busy || code.length !== 6}>
            Turn on
          </button>
        </div>
      </form>
    );
  }

  return (
    <div className="card">
      <div className="card-head">
        <h2 style={{ margin: 0 }}>Two-factor sign-in</h2>
        <span className="pill neutral">Off</span>
      </div>
      <span className="small muted">
        Recommended. With it on, a stolen password alone is not enough to get into this dashboard.
      </span>
      {error && <p className="error" role="alert">{error}</p>}
      <button className="btn primary" disabled={busy} onClick={begin}>
        Set up two-factor
      </button>
    </div>
  );
}
