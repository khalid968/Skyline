import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { api, setUnauthorizedHandler } from './api';

// Who is signed in. The session itself lives in an HttpOnly cookie the browser
// manages; this only remembers the account details the server reports, and
// forgets them the moment the server says the session is gone.

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [state, setState] = useState({ status: 'loading', me: null });

  const loadMe = useCallback(async () => {
    try {
      const me = await api.me();
      setState({ status: 'signedIn', me });
      return me;
    } catch {
      setState({ status: 'signedOut', me: null });
      return null;
    }
  }, []);

  useEffect(() => {
    setUnauthorizedHandler(() => setState({ status: 'signedOut', me: null }));
    loadMe();
  }, [loadMe]);

  const value = useMemo(
    () => ({
      ...state,
      refresh: loadMe,
      // Returns { mfaToken } when a code is still needed, else signs in.
      async signIn(username, password) {
        const r = await api.login(username, password);
        if (r.mfaRequired) return { mfaToken: r.mfaToken };
        await loadMe();
        return {};
      },
      async completeMfa(mfaToken, code) {
        await api.completeMfa(mfaToken, code);
        await loadMe();
      },
      async signOut() {
        try {
          await api.logout();
        } finally {
          setState({ status: 'signedOut', me: null });
        }
      },
    }),
    [state, loadMe],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth outside AuthProvider');
  return ctx;
}

// What the signed-in operator may do, mirroring the backend's permission seed
// (migrations 002 and 010). The server enforces all of it regardless; this only
// hides controls that would be refused.
export function capabilities(me) {
  const admin = me?.role === 'admin';
  return {
    createUsers: admin,
    rename: admin,
    suspend: admin || me?.role === 'moderator',
    deleteUsers: admin,
    changeRoles: admin,
    codes: admin,
    resetSignIn: admin,
    editContacts: admin || me?.role === 'moderator',
    revokeDevices: admin,
    makeAdmins: !!me?.isOwner,
  };
}

// Mirrors admin-policy.js: may this operator act on that person at all?
export function canManage(me, target) {
  if (!me || !target) return false;
  if (target.userId === me.userId) return false;
  if (target.isOwner && !me.isOwner) return false;
  if (target.role === 'admin' && !me.isOwner) return false;
  if (me.role === 'moderator' && target.role !== 'member') return false;
  return true;
}
