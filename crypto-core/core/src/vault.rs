//! The on-device vault: every secret this device holds (its identity key pair,
//! prekeys, sessions, contacts' identity keys, its Ed25519 credential) lives in
//! one SQLite file, and every value in it is encrypted.
//!
//! - Values are sealed with AES-256-GCM-SIV (a vetted AEAD, used as designed;
//!   SIV so that a repeated nonce cannot break confidentiality). Each value gets
//!   a fresh random nonce, and the row id is the associated data, so a value
//!   moved to another row fails to open.
//! - Row ids are HMAC-SHA256 of (namespace, key), so the file does not reveal
//!   WHO this device talks to (session keys are named after contacts).
//! - Both subkeys come from one 32-byte storage key via HKDF. The app keeps
//!   that storage key in the OS keystore (Keychain, Android Keystore, Windows
//!   DPAPI); it never sits next to the file.
//!
//! This is composition of standard primitives, not new cryptography.

use aes_gcm_siv::aead::{Aead, KeyInit as _, Payload};
use aes_gcm_siv::{Aes256GcmSiv, Nonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::TryRngCore as _;
use rand::rngs::OsRng;
use rusqlite::{Connection, OptionalExtension, params};
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::error::CryptoError;

const NONCE_BYTES: usize = 12;

pub struct Vault {
    conn: Connection,
    cipher: Aes256GcmSiv,
    index_key: Zeroizing<[u8; 32]>,
}

impl Vault {
    /// Opens (or creates) the vault at `path`; `None` keeps it in memory.
    pub fn open(path: Option<&str>, storage_key: &[u8]) -> Result<Self, CryptoError> {
        if storage_key.len() != 32 {
            return Err(CryptoError::invalid("the storage key must be 32 bytes"));
        }
        let hk = Hkdf::<Sha256>::new(Some(b"skyline-vault-v1"), storage_key);
        let mut enc = Zeroizing::new([0u8; 32]);
        let mut index_key = Zeroizing::new([0u8; 32]);
        hk.expand(b"value-encryption", enc.as_mut())
            .and_then(|_| hk.expand(b"row-index", index_key.as_mut()))
            .map_err(|_| CryptoError::storage("key derivation failed"))?;
        let cipher = Aes256GcmSiv::new_from_slice(enc.as_ref())
            .map_err(|_| CryptoError::storage("bad value key"))?;

        let conn = match path {
            Some(p) => Connection::open(p),
            None => Connection::open_in_memory(),
        }
        .map_err(storage)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA secure_delete = ON;
             CREATE TABLE IF NOT EXISTS vault (id BLOB PRIMARY KEY, value BLOB NOT NULL);",
        )
        .map_err(storage)?;

        Ok(Self {
            conn,
            cipher,
            index_key,
        })
    }

    fn row_id(&self, ns: &str, key: &[u8]) -> Vec<u8> {
        let mut mac = Hmac::<Sha256>::new_from_slice(self.index_key.as_ref())
            .expect("HMAC takes any key length");
        mac.update(ns.as_bytes());
        mac.update(&[0]);
        mac.update(key);
        mac.finalize().into_bytes().to_vec()
    }

    pub fn get(&self, ns: &str, key: &[u8]) -> Result<Option<Vec<u8>>, CryptoError> {
        let id = self.row_id(ns, key);
        let sealed: Option<Vec<u8>> = self
            .conn
            .query_row("SELECT value FROM vault WHERE id = ?1", params![id], |r| {
                r.get(0)
            })
            .optional()
            .map_err(storage)?;
        let Some(sealed) = sealed else {
            return Ok(None);
        };
        if sealed.len() < NONCE_BYTES {
            return Err(CryptoError::storage("corrupt vault entry"));
        }
        let (nonce, body) = sealed.split_at(NONCE_BYTES);
        let plain = self
            .cipher
            .decrypt(
                &Nonce::try_from(nonce).map_err(|_| CryptoError::locked())?,
                Payload {
                    msg: body,
                    aad: &id,
                },
            )
            // Wrong storage key, or a tampered/moved row. Either way: refuse.
            .map_err(|_| CryptoError::locked())?;
        Ok(Some(plain))
    }

    pub fn put(&self, ns: &str, key: &[u8], value: &[u8]) -> Result<(), CryptoError> {
        let id = self.row_id(ns, key);
        let mut nonce = [0u8; NONCE_BYTES];
        OsRng
            .try_fill_bytes(&mut nonce)
            .map_err(|_| CryptoError::storage("no randomness"))?;
        let body = self
            .cipher
            .encrypt(
                &Nonce::from(nonce),
                Payload {
                    msg: value,
                    aad: &id,
                },
            )
            .map_err(|_| CryptoError::storage("sealing failed"))?;
        let mut sealed = nonce.to_vec();
        sealed.extend_from_slice(&body);
        self.conn
            .execute(
                "INSERT INTO vault (id, value) VALUES (?1, ?2)
                 ON CONFLICT (id) DO UPDATE SET value = excluded.value",
                params![id, sealed],
            )
            .map_err(storage)?;
        Ok(())
    }

    pub fn delete(&self, ns: &str, key: &[u8]) -> Result<(), CryptoError> {
        let id = self.row_id(ns, key);
        self.conn
            .execute("DELETE FROM vault WHERE id = ?1", params![id])
            .map_err(storage)?;
        Ok(())
    }

    /// True for a brand-new vault. Row ids depend on the storage key, so a
    /// vault opened with the WRONG key looks empty to every lookup; this is
    /// how that case is told apart from a genuinely new one.
    pub fn is_empty(&self) -> Result<bool, CryptoError> {
        let n: i64 = self
            .conn
            .query_row("SELECT count(*) FROM vault", [], |r| r.get(0))
            .map_err(storage)?;
        Ok(n == 0)
    }

    /// Transaction control: an operation's writes (a new session, a used
    /// prekey destroyed) land together or not at all.
    pub fn begin(&self) -> Result<(), CryptoError> {
        self.conn.execute_batch("BEGIN IMMEDIATE").map_err(storage)
    }
    pub fn commit(&self) -> Result<(), CryptoError> {
        self.conn.execute_batch("COMMIT").map_err(storage)
    }
    pub fn rollback(&self) {
        let _ = self.conn.execute_batch("ROLLBACK");
    }

    /// Every sealed value, raw. Only for tests that prove nothing is plaintext.
    #[doc(hidden)]
    pub fn raw_values_for_tests(&self) -> Vec<Vec<u8>> {
        let mut stmt = self.conn.prepare("SELECT id, value FROM vault").unwrap();
        stmt.query_map([], |r| {
            Ok([r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?].concat())
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
    }
}

fn storage(e: rusqlite::Error) -> CryptoError {
    CryptoError::storage(e.to_string())
}
