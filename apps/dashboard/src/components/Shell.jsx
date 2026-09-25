import { NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import { Avatar, Icon, ROLE_LABEL } from './ui';

// The sidebar: Users, Contact graph, Groups (brought forward to Phase 8b,
// decisions.md 2026-09-25), Devices. The audit log is v2. While a temporary password is in force, only the account
// page is reachable, so the rest of the navigation is shown disabled.
export default function Shell() {
  const { me } = useAuth();
  const locked = me?.mustChangePassword;
  const link = (to, icon, label) => (
    <NavLink to={to} aria-disabled={locked ? 'true' : undefined} tabIndex={locked ? -1 : undefined}>
      <Icon name={icon} />
      {label}
    </NavLink>
  );

  return (
    <div className="shell">
      <aside className="sidebar" aria-label="Main">
        <div className="brand">
          <Icon name="shield" size={24} stroke="#6E96FF" width={1.8} />
          <span className="brand-word">SKYLINE</span>
          <span className="brand-tag">ADMIN</span>
        </div>
        <nav className="nav">
          {link('/users', 'users', 'Users')}
          {link('/contacts', 'graph', 'Contact graph')}
          {link('/groups', 'groups', 'Groups')}
          {link('/devices', 'device', 'Devices')}
        </nav>
        <div style={{ flex: 1 }} />
        <NavLink to="/account" className={({ isActive }) => `account-card${isActive ? ' active' : ''}`}>
          <Avatar name={me?.displayName} seed={me?.userId} />
          <span style={{ minWidth: 0, display: 'flex', flexDirection: 'column' }}>
            <span className="account-name">{me?.displayName}</span>
            <span className="account-role">{me?.isOwner ? 'Owner · your account' : `${ROLE_LABEL[me?.role]} · your account`}</span>
          </span>
        </NavLink>
      </aside>
      <main className="main">
        <Outlet />
      </main>
    </div>
  );
}
