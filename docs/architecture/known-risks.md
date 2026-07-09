# Known Architectural Risks

## Web platform E2EE (open — resolve at the start of Phase 5)

Skyline's E2EE plan wraps Signal's official `libsignal-client` Rust crate and exposes it to Flutter via `flutter_rust_bridge` FFI. That works cleanly for Android, iOS, Windows, macOS, and Linux, where Flutter can link a native/dynamic library per platform.

**The Web target is different.** `libsignal-client` has no official, stable WebAssembly build, and Flutter Web cannot load native FFI libraries at all — it runs in the browser. This means the Web client cannot use the same crypto core as the other five platforms without further work.

This is **not solved in Phase 1** — it's flagged now so it isn't discovered late. It gets a dedicated spike at the start of Phase 5 (Encryption), evaluating, in order of preference:

1. **Community/experimental WASM builds of `libsignal-client`** — if one exists and is trustworthy/maintainable, reuse it directly to keep one crypto implementation across all six platforms.
2. **Compiling `crypto-core` itself to WASM** via `wasm-pack`/`wasm-bindgen` — `libsignal-client`'s dependency tree would need to be WASM-compatible; this needs verification before committing.
3. **Scoped Web feature reduction** — if neither of the above is viable, the Web client ships with a reduced feature set (e.g. view-only for existing sessions established on a native device, or E2EE disabled with a clear, prominent in-app warning) rather than silently weakening security guarantees or inventing a second, unproven crypto implementation just for Web.

Whatever is chosen, the non-negotiable constraint carries over from the project's founding rules: no custom cryptographic primitives, ever — only established, audited libraries, even in the fallback path.

## Docker daemon unavailable in the development sandbox

The `infra/docker/docker-compose.yml` dev stack (Postgres, Redis, MinIO) has been syntax-validated (`docker compose config`) but could not be live-tested in this remote build environment, because the Docker daemon cannot start under its sandboxing (unprivileged container, no `dockerd`). This is an environment limitation, not a config issue. Verify with `docker compose -f infra/docker/docker-compose.yml up` on a machine with a working Docker daemon before relying on it.

## Flutter SDK unavailable in the development sandbox

The Flutter SDK is not installed in this remote build environment, so `apps/mobile` ships as a hand-authored `lib/` + `pubspec.yaml` without the SDK-generated platform runner folders (`android/`, `ios/`, `windows/`, `macos/`, `linux/`, `web/`). See `apps/mobile/README.md` for the one-time `flutter create --platforms=... .` bootstrap step required locally before `flutter pub get`/`flutter run` will work.
