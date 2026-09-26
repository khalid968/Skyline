import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// In development the dashboard and the API share one origin: Vite serves the
// app and forwards /api/* to the backend. That keeps the session cookie
// SameSite=Strict and first-party, exactly as behind Nginx in production
// (Phase 13), and means the backend needs no CORS at all.
const API = process.env.SKYLINE_API || 'http://localhost:3000';

// The production build's content security policy (threat model A2): only this
// origin, no inline scripts, no third parties. Inline style ATTRIBUTES are
// allowed (React's style={...}). frame-ancestors cannot be set from a meta
// tag; Nginx sends it with X-Frame-Options (Phase 13). Development keeps
// Vite's own inline scripts working, so the policy is added at build only.
export const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "font-src 'self'",
  "img-src 'self' data:",
  "connect-src 'self'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'self'",
].join('; ');

const cspMeta = {
  name: 'skyline-csp',
  apply: 'build',
  transformIndexHtml: (html) =>
    html.replace('<meta charset="UTF-8" />', `<meta charset="UTF-8" />
    <meta http-equiv="Content-Security-Policy" content="${CSP}" />`),
};

export default defineConfig({
  // Production serves the dashboard at /admin/ on the same origin as the API
  // (infra/production); the build sets DASHBOARD_BASE=/admin/.
  base: process.env.DASHBOARD_BASE || '/',
  plugins: [react(), cspMeta],
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': {
        target: API,
        changeOrigin: false,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.js'],
    css: false,
  },
});
