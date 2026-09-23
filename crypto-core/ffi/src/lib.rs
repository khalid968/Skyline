//! The Flutter-facing edge of the crypto core. `flutter_rust_bridge` reads
//! `api/` and generates the Dart bindings in apps/mobile/lib/src/rust. Every
//! function here only converts types and calls skyline_crypto_core.

pub mod api;
mod frb_generated;
