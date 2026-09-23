import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import { ApiError } from '../lib/api';
import { Icon } from '../components/ui';

export function AuthBrand({ title, children }) {
  return (
    <div className="auth-brand">
      <div className="brand" style={{ padding: 0 }}>
        <Icon name="shield" size={30} stroke="#6E96FF" width={1.8} />
        <span className="brand-word" style={{ fontSize: 17 }}>SKYLINE</span>
        <span className="brand-tag">ADMIN</span>
      </div>
      <div style={{ flex: 1 }} />
      <h1>{title}</h1>
      <p>{children}</p>
    </div>
  );
}

// Board 9. A wrong username and a wrong password get the same message, on
// purpose: the page must not reveal which usernames exist.
export default function SignIn() {
  const { signIn } = useAuth();
  const navigate = useNavigate();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      const r = await signIn(username.trim(), password);
      if (r.mfaToken) navigate('/two-factor', { state: { mfaToken: r.mfaToken } });
      else navigate('/users');
    } catch (err) {
      if (err instanceof ApiError && err.status === 429) {
        setError('Too many attempts. Sign-in for this username is paused for 15 minutes.');
      } else if (err instanceof ApiError && (err.status === 401 || err.status === 400)) {
        setError("That username and password didn't work.");
      } else {
        setError('Sign-in is unavailable right now. Try again shortly.');
      }
      setPassword('');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="auth">
      <AuthBrand title="The operator console.">
        Create accounts, issue activation codes, and decide who can talk to whom. Members never sign in here, and
        nothing here can read a message.
      </AuthBrand>
      <div className="auth-form">
        <form onSubmit={submit} noValidate>
          <div>
            <h2>Sign in</h2>
            <p className="muted" style={{ margin: '8px 0 0' }}>Administrators and moderators only.</p>
          </div>
          <div className="field">
            <label htmlFor="username">Username</label>
            <input
              id="username"
              className="input mono"
              autoComplete="username"
              autoCapitalize="none"
              spellCheck="false"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              required
            />
          </div>
          <div className="field">
            <label htmlFor="password">Password</label>
            <input
              id="password"
              className="input"
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <button className="btn primary block" disabled={busy || !username || !password}>
            {busy ? 'Signing in…' : 'Sign in'}
          </button>
          <p className="small muted" style={{ margin: 0 }}>
            Forgotten your password or lost your authenticator? Ask the owner of this Skyline to reset your sign-in.
          </p>
        </form>
      </div>
    </div>
  );
}
