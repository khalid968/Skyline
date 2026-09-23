import { useEffect, useRef, useState } from 'react';

// Small shared pieces. Icons are inline stroke SVGs (no icon font, no emoji),
// as the design system requires.

const PATHS = {
  shield: (
    <>
      <path d="M12 2.5 4.5 5.8v5.4c0 4.6 3.1 8.4 7.5 9.8 4.4-1.4 7.5-5.2 7.5-9.8V5.8Z" />
      <path d="M7.6 12.6h8.8" />
      <path d="M9.9 12.6 12 9.4l2.1 3.2" />
    </>
  ),
  users: (
    <>
      <circle cx="9" cy="8" r="3.4" />
      <path d="M3.5 20c0-3.2 2.5-5.4 5.5-5.4s5.5 2.2 5.5 5.4" />
      <path d="M16.5 5.2a3.4 3.4 0 0 1 0 6.4" />
      <path d="M17.5 14.9c1.9.6 3.2 2.4 3.2 5.1" />
    </>
  ),
  graph: (
    <>
      <circle cx="5.5" cy="6" r="2.5" />
      <circle cx="18.5" cy="6" r="2.5" />
      <circle cx="12" cy="18" r="2.5" />
      <path d="M8 6h8" />
      <path d="M6.6 8.2 11 15.8" />
      <path d="M17.4 8.2 13 15.8" />
    </>
  ),
  device: (
    <>
      <rect x="6.5" y="2.5" width="11" height="19" rx="2.6" />
      <path d="M10.5 18.3h3" />
    </>
  ),
  plus: <path d="M12 5.5v13M5.5 12h13" />,
  close: <path d="M6 6l12 12M18 6 6 18" />,
  back: <path d="M14.5 5 8 12l6.5 7" />,
  check: <path d="m4.5 12.5 5 5 10-11" />,
  warn: (
    <>
      <path d="M12 3.5 21 19.5H3Z" />
      <path d="M12 9.5v4" />
      <path d="M12 16.6h.01" />
    </>
  ),
  lock: (
    <>
      <rect x="4" y="10.5" width="16" height="10.5" rx="2.5" />
      <path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" />
    </>
  ),
  copy: (
    <>
      <rect x="8.5" y="8.5" width="11.5" height="11.5" rx="2.4" />
      <path d="M15.5 8.5v-2a2.4 2.4 0 0 0-2.4-2.4H6.4A2.4 2.4 0 0 0 4 6.5v6.7a2.4 2.4 0 0 0 2.4 2.4h2" />
    </>
  ),
  crown: <path d="m3 8 4.5 4L12 5l4.5 7L21 8l-2 10H5Z" />,
};

export function Icon({ name, size = 17, stroke = 'currentColor', width = 1.9 }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke={stroke}
      strokeWidth={width}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {PATHS[name]}
    </svg>
  );
}

const TINTS = ['#3A63D8', '#7A5AF0', '#C1743A', '#3F7AB8', '#2C7F6B', '#9A5AC4', '#B45A9E', '#5A6782'];

export function Avatar({ name = '', seed = name, size = '' }) {
  const initials =
    name
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((w) => w[0].toUpperCase())
      .join('') || '?';
  let h = 0;
  for (const c of seed) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return (
    <span className={`avatar ${size}`} style={{ background: TINTS[h % TINTS.length] }} aria-hidden="true">
      {initials}
    </span>
  );
}

const STATUS_LABEL = { active: 'Active', pending: 'Pending', suspended: 'Suspended', deleted: 'Deleted' };
export function StatusPill({ status }) {
  return (
    <span className={`pill ${status}`}>
      <span className="dot" />
      {STATUS_LABEL[status] || status}
    </span>
  );
}

export function OwnerPill() {
  return (
    <span className="pill owner">
      <Icon name="crown" size={12} width={2.2} />
      Owner
    </span>
  );
}

export const ROLE_LABEL = { member: 'Member', moderator: 'Moderator', admin: 'Administrator' };

// A secret shown exactly once: an activation code or a temporary password.
export function OneTimeSecret({ label, value, note }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      // Clipboard can be blocked; the value is on screen to copy by hand.
    }
  };
  return (
    <div className="secret">
      <span className="label" style={{ letterSpacing: '0.06em', textTransform: 'uppercase', fontSize: 11 }}>
        {label}
      </span>
      <div className="row between">
        <span className="secret-value" data-testid="secret-value">
          {value}
        </span>
        <button type="button" className="icon-btn" onClick={copy} aria-label={`Copy ${label.toLowerCase()}`}>
          <Icon name={copied ? 'check' : 'copy'} size={15} />
        </button>
      </div>
      {note && <span className="hint">{note}</span>}
    </div>
  );
}

// An accessible modal: labelled, focus moved in on open and restored on
// close, Escape to dismiss.
export function Dialog({ title, children, onClose, labelId = 'dialog-title' }) {
  const ref = useRef(null);
  useEffect(() => {
    const previous = document.activeElement;
    ref.current?.querySelector('button, input')?.focus();
    const onKey = (e) => e.key === 'Escape' && onClose();
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('keydown', onKey);
      previous?.focus?.();
    };
  }, [onClose]);
  return (
    <>
      <div className="scrim" onClick={onClose} />
      <div className="dialog" role="dialog" aria-modal="true" aria-labelledby={labelId} ref={ref}>
        <h2 id={labelId}>{title}</h2>
        {children}
      </div>
    </>
  );
}

export function Notice({ kind = 'info', icon = 'warn', children }) {
  return (
    <div className={`notice ${kind}`}>
      <Icon name={icon} size={16} width={2} />
      <span>{children}</span>
    </div>
  );
}

const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
export function timeAgo(value) {
  if (!value) return 'Never';
  const s = (new Date(value).getTime() - Date.now()) / 1000;
  const abs = Math.abs(s);
  if (abs < 60) return 'Just now';
  if (abs < 3600) return rtf.format(Math.round(s / 60), 'minute');
  if (abs < 86400) return rtf.format(Math.round(s / 3600), 'hour');
  if (abs < 86400 * 30) return rtf.format(Math.round(s / 86400), 'day');
  return new Date(value).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

export function formatDate(value) {
  return value ? new Date(value).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
}
