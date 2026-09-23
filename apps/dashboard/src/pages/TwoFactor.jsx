import { useState } from 'react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import { AuthBrand } from './SignIn';
import { Notice } from '../components/ui';

// Board 10. The short-lived "enter your code" token lives only in memory
// (router state): reloading the page means signing in again, by design.
export default function TwoFactor() {
  const { completeMfa } = useAuth();
  const navigate = useNavigate();
  const mfaToken = useLocation().state?.mfaToken;
  const [code, setCode] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  if (!mfaToken) return <Navigate to="/sign-in" replace />;

  const submit = async (e) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      await completeMfa(mfaToken, code);
      navigate('/users');
    } catch {
      setError("That code didn't work. Codes change every 30 seconds, and each one works only once.");
      setCode('');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="auth">
      <AuthBrand title="One more step.">
        Your password was right. Because you turned on two-factor sign-in, we also need the code from your
        authenticator app.
      </AuthBrand>
      <div className="auth-form">
        <form onSubmit={submit}>
          <div>
            <h2>Enter your code</h2>
            <p className="muted" style={{ margin: '8px 0 0' }}>
              Open your authenticator app and type the 6-digit code for Skyline.
            </p>
          </div>
          <div className="field">
            <label htmlFor="code">Six-digit code</label>
            <input
              id="code"
              className="input code-input"
              inputMode="numeric"
              autoComplete="one-time-code"
              maxLength={6}
              value={code}
              onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
              autoFocus
            />
          </div>
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <button className="btn primary block" disabled={busy || code.length !== 6}>
            {busy ? 'Checking…' : 'Verify and sign in'}
          </button>
          <span className="small muted">You have 5 minutes before you need to sign in again.</span>
          <Link to="/sign-in">Back to sign in</Link>
          <Notice kind="warn">
            Lost your phone? Only the owner can switch off your two-factor sign-in, after confirming who you are.
          </Notice>
        </form>
      </div>
    </div>
  );
}
