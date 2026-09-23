# Skyline Admin (dashboard)

The operator console: create accounts, issue activation codes, decide who can talk to whom, and revoke
devices. It is a separate web app, and it never holds message keys or plaintext.

Stack: React 19, Vite, and react-router, written in plain JavaScript. Tests use Vitest and Testing Library.

```bash
npm install
npm run dev      # http://localhost:5173; forwards /api/* to the backend (SKYLINE_API, default http://localhost:3000)
npm test         # no backend needed
npm run build    # outputs to dist/
```

## Rules for changing it

- **All requests go through `src/lib/api.js`.** It uses the same origin through `/api` and always sends
  `x-skyline-client: dashboard`, which the backend requires on cookie-authenticated changes (CSRF). The
  session is an HttpOnly cookie, and this code never sees or stores a token.
- **Screens follow approved prototypes** (`docs/architecture/design.md`, boards 6-12). A new screen needs an
  approved prototype before any code is written.
- **`capabilities()` and `canManage()` in `src/lib/auth.jsx` only hide controls.** The backend enforces the
  same rules on its own (`apps/backend/src/modules/admin/admin-policy.js`). Keep the two in step.

Full security model: `docs/security/authorization.md`.
