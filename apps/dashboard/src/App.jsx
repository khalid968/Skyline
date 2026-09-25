import { Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { useAuth } from './lib/auth';
import Shell from './components/Shell';
import SignIn from './pages/SignIn';
import TwoFactor from './pages/TwoFactor';
import Users from './pages/Users';
import UserDetail from './pages/UserDetail';
import Groups from './pages/Groups';
import ContactGraph from './pages/ContactGraph';
import Devices from './pages/Devices';
import Account from './pages/Account';

// Signed out -> sign-in. Signed in with a temporary password -> the account
// page only, until a new password is chosen (the server enforces the same).
function RequireAuth({ children }) {
  const { status, me } = useAuth();
  const location = useLocation();
  if (status === 'loading') return <div className="splash">Loading…</div>;
  if (status === 'signedOut') return <Navigate to="/sign-in" replace />;
  if (me?.mustChangePassword && location.pathname !== '/account') return <Navigate to="/account" replace />;
  return children;
}

function SignedOutOnly({ children }) {
  const { status } = useAuth();
  if (status === 'loading') return <div className="splash">Loading…</div>;
  if (status === 'signedIn') return <Navigate to="/users" replace />;
  return children;
}

export default function App() {
  return (
    <Routes>
      <Route path="/sign-in" element={<SignedOutOnly><SignIn /></SignedOutOnly>} />
      <Route path="/two-factor" element={<SignedOutOnly><TwoFactor /></SignedOutOnly>} />
      <Route element={<RequireAuth><Shell /></RequireAuth>}>
        <Route path="/users" element={<Users />} />
        <Route path="/users/:userId" element={<UserDetail />} />
        <Route path="/contacts" element={<ContactGraph />} />
        <Route path="/groups" element={<Groups />} />
        <Route path="/devices" element={<Devices />} />
        <Route path="/account" element={<Account />} />
      </Route>
      <Route path="*" element={<Navigate to="/users" replace />} />
    </Routes>
  );
}
