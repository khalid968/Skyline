import { useEffect, useState } from 'react';
import { NavLink, Outlet } from 'react-router-dom';
import { api } from '../lib/api';
import { useAuth, capabilities } from '../lib/auth';
import { Avatar, Icon, ROLE_LABEL } from './ui';

// Pages fire this after acting on an alert, so the count in the menu follows
// at once instead of on the next poll.
export const ALERTS_CHANGED = 'skyline:alerts-changed';

// The sidebar (boards 36-39 order): Overview, Users, Contact graph, Groups,
// Devices, Sessions, Alerts, Audit log. Alerts and the audit log appear only
// for the owner and admins. While a temporary password is in force, only the
// account page is reachable, so the rest is shown disabled.
export default function Shell() {
  const { me } = useAuth();
  const can = capabilities(me);
  const locked = me?.mustChangePassword;
  const openAlerts = useOpenAlerts(can.alerts && !locked);
  const link = (to, icon, label, badge) => (
    <NavLink to={to} aria-disabled={locked ? 'true' : undefined} tabIndex={locked ? -1 : undefined}>
      <Icon name={icon} />
      <span style={{ flex: 1 }}>{label}</span>
      {badge > 0 && (
        <span className="nav-badge" aria-label={`${badge} open`}>
          {badge}
        </span>
      )}
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
          {can.overview && link('/overview', 'overview', 'Overview')}
          {link('/users', 'users', 'Users')}
          {link('/contacts', 'graph', 'Contact graph')}
          {link('/groups', 'groups', 'Groups')}
          {link('/devices', 'device', 'Devices')}
          {link('/sessions', 'sessions', 'Sessions')}
          {can.alerts && link('/alerts', 'alert', 'Alerts', openAlerts)}
          {can.audit && link('/audit', 'audit', 'Audit log')}
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

// How many alerts are open, refreshed every 30 seconds and whenever a page
// says it changed them. A failure just leaves the last count.
function useOpenAlerts(enabled) {
  const [open, setOpen] = useState(0);
  useEffect(() => {
    if (!enabled) return undefined;
    let alive = true;
    const load = () =>
      api
        .alerts('open')
        .then((r) => alive && setOpen(r.open))
        .catch(() => {});
    load();
    const timer = setInterval(load, 30000);
    window.addEventListener(ALERTS_CHANGED, load);
    return () => {
      alive = false;
      clearInterval(timer);
      window.removeEventListener(ALERTS_CHANGED, load);
    };
  }, [enabled]);
  return open;
}
