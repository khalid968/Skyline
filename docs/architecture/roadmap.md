# Development Roadmap

Skyline is built in phases. Each phase gets its own plan and stops for explicit approval before the next begins — nothing in a later phase is started early.

1. **System architecture** *(this phase)* — project identity, tech stack decisions, monorepo scaffolding, local dev environment. No feature logic.
2. **Backend** — core NestJS API conventions: DTO validation, error handling, logging, health checks, base guards/interceptors/filters, WebSocket gateway skeleton.
3. **Database** — full normalized PostgreSQL schema (users, devices, sessions, chats, messages, attachments, groups, roles, permissions, invites, notifications, audit logs), migrations, indexes, constraints.
4. **Authentication** — invite-only registration, username auth, optional email, passkeys, device authentication, biometric login, recovery codes. No public registration; only admins issue invites.
5. **Encryption** — `libsignal-client` integration in `crypto-core`, `flutter_rust_bridge` bindings, on-device key generation/storage, X3DH session establishment, Double Ratchet messaging, the Web/WASM risk spike (see `known-risks.md`).
6. **Messaging** — private chats, group chats, channels, replies/threads, edit/delete, typing/read/delivered receipts, pinned messages, search, reactions, mentions, forwarding, drafts, bookmarks, archive/mute/block, scheduled messages, disappearing messages.
7. **Media** — image/video/audio/document sharing, voice messages, GIFs, media gallery, client-side encryption before upload, MinIO storage, compression/lazy loading.
8. **Calls** — WebRTC voice/video calls and screen sharing, E2EE call signaling and media.
9. **Administration** — admin dashboard, invite/user/role/permission management, audit logs, server/storage monitoring, active sessions/device management, rate limiting, abuse detection.
10. **Testing** — unit, widget, integration, backend, API, security, and performance test suites across client and server.
11. **Deployment** — production Docker Compose, Nginx TLS, CI/CD (GitHub Actions), secrets management, automated backups, monitoring, logging, health checks, deployment/admin/maintenance guides.

Phases 2–11 are not started until the current phase is explicitly approved.
