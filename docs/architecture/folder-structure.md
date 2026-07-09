# Monorepo Folder Structure

```
skyline/
  apps/
    mobile/                    # Flutter app — all 6 platforms, one codebase
      lib/
        core/                  # DI wiring, theming (Material 3, light/dark), routing, error handling, constants
          theme/                 app_theme.dart — Material 3 light/dark ColorSchemes
          routing/               app_router.dart — go_router route table
          di/ error/ constants/  reserved, populated as needed per feature phase
        features/              # feature-first; each has data/domain/presentation (see features/README.md)
          auth/ chats/ messages/ groups/ calls/ media/ settings/ admin/
        shared/                # shared widgets/providers used across features
      native/crypto_bridge/    # flutter_rust_bridge generated bindings (Phase 5)
      test/
      pubspec.yaml
    backend/                   # NestJS (JavaScript)
      src/
        modules/               # auth, users, devices, chats, messages, groups, media, notifications, admin, websocket
        common/                # guards, interceptors, filters, decorators, pipes
        config/                # configuration.js — env-driven runtime config
        database/              # migrations + schema (Phase 3)
        app.module.js
        main.js
      test/
      package.json
  crypto-core/                 # Rust workspace wrapping libsignal-client
    Cargo.toml                 # workspace manifest
    core/                      # skyline_crypto_core lib crate (empty until Phase 5)
  infra/
    docker/
      docker-compose.yml       # local dev only: Postgres, Redis, MinIO
    ci/                        # GitHub Actions workflows (Phase 11)
  docs/
    architecture/              # this file, overview, tech-stack-decisions, roadmap, known-risks
    api/                       # API reference (Phase 2+)
    database/                  # schema diagrams (Phase 3)
    security/                  # threat model, security docs (ongoing)
    deployment/                # deployment/admin guides (Phase 11)
  README.md
```

## Conventions

- **Feature-first, layered inside**: every client feature owns its full vertical slice (`data`/`domain`/`presentation`); nothing is organized by technical layer at the top level. See `apps/mobile/lib/features/README.md`.
- **Modules mirror features on the backend**: `apps/backend/src/modules/<name>` names match the client `features/<name>` where the domain concept is shared (e.g. `chats`, `messages`, `groups`), so a contributor can find the server counterpart of any client feature by name.
- **`crypto-core` is intentionally isolated** from both `apps/mobile` and `apps/backend` — it's a standalone Rust workspace consumed by the Flutter app via FFI, never by the backend (the backend never has key material to operate on).
