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
             CREATE TABLE IF NOT EXISTS vault (id BLOB PRIMARY KEY, value BLOB NOT NULL);
             CREATE TABLE IF NOT EXISTS records (
               id BLOB PRIMARY KEY, grp BLOB NOT NULL, sort INTEGER NOT NULL, value BLOB NOT NULL);
             CREATE INDEX IF NOT EXISTS records_grp_sort ON records (grp, sort);",
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
        sealed.map(|s| self.open_sealed(&id, &s)).transpose()
    }

    pub fn put(&self, ns: &str, key: &[u8], value: &[u8]) -> Result<(), CryptoError> {
        let id = self.row_id(ns, key);
        let sealed = self.seal(&id, value)?;
        self.conn
            .execute(
                "INSERT INTO vault (id, value) VALUES (?1, ?2)
                 ON CONFLICT (id) DO UPDATE SET value = excluded.value",
                params![id, sealed],
            )
            .map_err(storage)?;
        Ok(())
    }

    /// AES-256-GCM-SIV with a fresh nonce; `aad` binds the value to its row.
    fn seal(&self, aad: &[u8], value: &[u8]) -> Result<Vec<u8>, CryptoError> {
        let mut nonce = [0u8; NONCE_BYTES];
        OsRng
            .try_fill_bytes(&mut nonce)
            .map_err(|_| CryptoError::storage("no randomness"))?;
        let body = self
            .cipher
            .encrypt(&Nonce::from(nonce), Payload { msg: value, aad })
            .map_err(|_| CryptoError::storage("sealing failed"))?;
        let mut sealed = nonce.to_vec();
        sealed.extend_from_slice(&body);
        Ok(sealed)
    }

    fn open_sealed(&self, aad: &[u8], sealed: &[u8]) -> Result<Vec<u8>, CryptoError> {
        if sealed.len() < NONCE_BYTES {
            return Err(CryptoError::storage("corrupt vault entry"));
        }
        let (nonce, body) = sealed.split_at(NONCE_BYTES);
        self.cipher
            .decrypt(
                &Nonce::try_from(nonce).map_err(|_| CryptoError::locked())?,
                Payload { msg: body, aad },
            )
            // Wrong storage key, or a tampered/moved row. Either way: refuse.
            .map_err(|_| CryptoError::locked())
    }

    // ------------------------------------------------------------ records
    //
    // The app's own encrypted data (messages, chat summaries): same key, same
    // AEAD. The row id and the group are HMACs, so the file shows neither
    // which chat a record belongs to nor its id; only `sort` (the app's
    // ordering number, a timestamp) is readable, so a chat can be paged.

    fn record_id(&self, kind: &str, id: &str) -> Vec<u8> {
        self.row_id(&format!("record:{kind}"), id.as_bytes())
    }

    fn record_group(&self, kind: &str, group: &str) -> Vec<u8> {
        self.row_id(&format!("record-group:{kind}"), group.as_bytes())
    }

    pub fn record_put(
        &self,
        kind: &str,
        id: &str,
        group: &str,
        sort: i64,
        value: &[u8],
    ) -> Result<(), CryptoError> {
        let rid = self.record_id(kind, id);
        let sealed = self.seal(&rid, value)?;
        self.conn
            .execute(
                "INSERT INTO records (id, grp, sort, value) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT (id) DO UPDATE SET grp = excluded.grp, sort = excluded.sort,
                                                value = excluded.value",
                params![rid, self.record_group(kind, group), sort, sealed],
            )
            .map_err(storage)?;
        Ok(())
    }

    pub fn record_get(&self, kind: &str, id: &str) -> Result<Option<Vec<u8>>, CryptoError> {
        let rid = self.record_id(kind, id);
        let sealed: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT value FROM records WHERE id = ?1",
                params![rid],
                |r| r.get(0),
            )
            .optional()
            .map_err(storage)?;
        sealed.map(|s| self.open_sealed(&rid, &s)).transpose()
    }

    /// Newest first: records of one group with `sort` below `before` (all when
    /// `None`), at most `limit`.
    pub fn record_list(
        &self,
        kind: &str,
        group: &str,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<(i64, Vec<u8>)>, CryptoError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, sort, value FROM records
                  WHERE grp = ?1 AND sort < ?2
                  ORDER BY sort DESC LIMIT ?3",
            )
            .map_err(storage)?;
        let rows = stmt
            .query_map(
                params![
                    self.record_group(kind, group),
                    before.unwrap_or(i64::MAX),
                    limit
                ],
                |r| {
                    Ok((
                        r.get::<_, Vec<u8>>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, Vec<u8>>(2)?,
                    ))
                },
            )
            .map_err(storage)?;
        let mut out = Vec::new();
        for row in rows {
            let (rid, sort, sealed) = row.map_err(storage)?;
            out.push((sort, self.open_sealed(&rid, &sealed)?));
        }
        Ok(out)
    }

    pub fn record_delete(&self, kind: &str, id: &str) -> Result<bool, CryptoError> {
        let n = self
            .conn
            .execute(
                "DELETE FROM records WHERE id = ?1",
                params![self.record_id(kind, id)],
            )
            .map_err(storage)?;
        Ok(n > 0)
    }

    pub fn record_delete_group(&self, kind: &str, group: &str) -> Result<u32, CryptoError> {
        let n = self
            .conn
            .execute(
                "DELETE FROM records WHERE grp = ?1",
                params![self.record_group(kind, group)],
            )
            .map_err(storage)?;
        Ok(n as u32)
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
            .query_row(
                "SELECT (SELECT count(*) FROM vault) + (SELECT count(*) FROM records)",
                [],
                |r| r.get(0),
            )
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
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, x'', value FROM vault UNION ALL SELECT id, grp, value FROM records",
            )
            .unwrap();
        stmt.query_map([], |r| {
            Ok([
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, Vec<u8>>(2)?,
            ]
            .concat())
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
    }
}

fn storage(e: rusqlite::Error) -> CryptoError {
    CryptoError::storage(e.to_string())
}
