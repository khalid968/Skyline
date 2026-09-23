import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// In development the dashboard and the API share one origin: Vite serves the
// app and forwards /api/* to the backend. That keeps the session cookie
// SameSite=Strict and first-party, exactly as behind Nginx in production
// (Phase 13), and means the backend needs no CORS at all.
const API = process.env.SKYLINE_API || 'http://localhost:3000';

export default defineConfig({
  plugins: [react()],
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
