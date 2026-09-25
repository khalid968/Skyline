//! Skyline's crypto core: Signal's official `libsignal` protocol behind a small,
//! byte-oriented API that `flutter_rust_bridge` exposes to the app.
//!
//! No cryptography is implemented here. libsignal does the protocol (PQXDH,
//! Double Ratchet, safety numbers); the vault composes standard primitives
//! (AES-256-GCM-SIV, HKDF, HMAC) to keep keys encrypted at rest.
//!
//! Licence: AGPL-3.0-only, because libsignal is (decisions.md, 2026-09-23).

pub mod api;
pub mod error;
pub mod media;
mod store;
mod vault;

pub use api::*;
pub use error::{CryptoError, CryptoErrorKind};
