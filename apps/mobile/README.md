# Skyline — Flutter client

v1 platforms: Android, iOS, Windows. Their runner folders (`android/`, `ios/`, `windows/`) are committed;
there is no web build (no official WASM libsignal).

```
flutter pub get
flutter analyze
flutter test
flutter test integration_test/crypto_test.dart -d windows   # the native crypto core, end to end
flutter run -d windows
```

## The crypto core

End-to-end encryption is Signal's libsignal, compiled from `../../crypto-core` (Rust) into the app:

- `rust_builder/` is a Flutter FFI plugin. Its cargokit scripts build `crypto-core/ffi` for each platform
  during `flutter build` / `flutter run`. This needs Rust, and protoc on PATH (see the root CLAUDE.md).
- `lib/src/rust/` holds the Dart bindings, **generated** by `flutter_rust_bridge_codegen generate` (config:
  `flutter_rust_bridge.yaml`). Never edit them by hand.
- `lib/core/crypto/device_crypto.dart` is what the app uses. It opens the device's encrypted key vault, with
  the vault's storage key held in the OS keystore.

iOS has not been built yet: there is no Mac (`docs/architecture/known-risks.md`).

## Layout

See `lib/features/README.md` for the feature-first Clean Architecture convention. `lib/core/` holds
cross-cutting concerns (theming, routing, crypto, DI wiring, error handling); `lib/shared/` holds widgets and
providers reused across features.
