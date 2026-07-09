# Feature-first layout

Each feature under this directory is a self-contained vertical slice, structured with Clean Architecture layers:

- `domain/` — entities, repository interfaces, use cases. No Flutter or infrastructure imports.
- `data/` — repository implementations, DTOs/models, remote (REST/WebSocket) and local (Drift) data sources. Implements the interfaces defined in `domain/`.
- `presentation/` — widgets, screens, and Riverpod providers/notifiers that expose feature state to the UI.

Dependencies only point inward: `presentation` → `domain` ← `data`. `domain` never depends on `data` or `presentation`.

Current features (scaffolded, logic added per phase): `auth`, `chats`, `messages`, `groups`, `calls`, `media`, `settings`, `admin`.
