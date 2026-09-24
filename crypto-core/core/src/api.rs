//! The whole surface the Skyline app sees. `flutter_rust_bridge` generates the
//! Dart side from this file, so it deals only in bytes, numbers and strings.
//!
//! Everything cryptographic is libsignal's: PQXDH to start a session, the
//! Double Ratchet for messages, its safety-number fingerprints. This file only
//! decides WHICH key goes where and keeps each operation atomic.

use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use ed25519_dalek::{Signer as _, SigningKey};
use futures::executor::block_on;
use libsignal_protocol::{
    CiphertextMessage, DeviceId, Fingerprint, GenericSignedPreKey as _, IdentityKey,
    IdentityKeyPair, IdentityKeyStore as _, KeyPair, KyberPreKeyRecord, KyberPreKeyStore as _,
    PreKeyBundle, PreKeyRecord, PreKeySignalMessage, PreKeyStore as _, ProtocolAddress, PublicKey,
    SessionStore as _, SessionUsabilityRequirements, SignalMessage, SignedPreKeyRecord,
    SignedPreKeyStore as _, Timestamp, kem, message_decrypt, message_encrypt,
    process_prekey_bundle,
};
use rand::rngs::OsRng;
use rand::{Rng as _, RngCore as _, TryRngCore as _};
use zeroize::Zeroizing;

use crate::error::{CryptoError, CryptoErrorKind};
use crate::store::{META, META_IDENTITY, META_REGISTRATION, VaultStore};
use crate::vault::Vault;

type Result<T> = std::result::Result<T, CryptoError>;

const META_SIGNING_KEY: &[u8] = b"device-signing-key";
const META_LOCAL_ADDRESS: &[u8] = b"local-address";
const META_NEXT_PREKEY: &[u8] = b"next-prekey-id";
const META_NEXT_SIGNED: &[u8] = b"next-signed-prekey-id";
const META_NEXT_KYBER: &[u8] = b"next-kyber-prekey-id";

/// Key ids are 24-bit, as in Signal and in the server's key directory.
const MAX_KEY_ID: u32 = 0x00FF_FFFF;
/// libsignal's safety-number format: version 2, 5200 hash iterations.
const FINGERPRINT_VERSION: u32 = 2;
const FINGERPRINT_ITERATIONS: u32 = 5200;
/// The Kyber variant Skyline publishes (Kyber1024, as Signal uses).
const KYBER: kem::KeyType = kem::KeyType::Kyber1024;
const MAX_BATCH: u32 = 100;

/// What the server learns about this device at activation. Public only.
pub struct DeviceIdentity {
    /// libsignal's serialized identity public key (33 bytes, 0x05 first).
    pub identity_key: Vec<u8>,
    pub registration_id: u32,
    /// Ed25519 public key: the device credential for sign-in (Phase 5).
    pub signing_key: Vec<u8>,
}

/// A signed prekey or a Kyber prekey (both carry an identity signature).
pub struct SignedPreKeyPublic {
    pub key_id: u32,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

pub struct OneTimePreKeyPublic {
    pub key_id: u32,
    pub public_key: Vec<u8>,
}

/// One device's bundle as the server's key directory returns it.
pub struct PreKeyBundleInput {
    pub registration_id: u32,
    pub device_number: u32,
    pub identity_key: Vec<u8>,
    pub signed_pre_key: SignedPreKeyPublic,
    pub kyber_pre_key: SignedPreKeyPublic,
    pub pre_key: Option<OneTimePreKeyPublic>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnvelopeKind {
    /// Starts a session (carries the PQXDH key agreement).
    PreKey,
    /// An ordinary Double Ratchet message.
    Whisper,
}

#[derive(Debug)]
pub struct Envelope {
    pub kind: EnvelopeKind,
    pub body: Vec<u8>,
}

/// One of the app's records, unsealed.
pub struct StoredRecord {
    pub sort: i64,
    pub value: Vec<u8>,
}

/// The numbers two people compare to verify one device of each other's.
pub struct SafetyNumber {
    /// 60 digits, shown in groups of five.
    pub displayable: String,
    /// The QR-code payload.
    pub scannable: Vec<u8>,
}

/// One device's cryptographic self. Opening it the first time creates the
/// identity; every later open must use the same storage key.
pub struct SkylineCrypto {
    vault: Mutex<Vault>,
}

impl SkylineCrypto {
    /// Opens (creating on first use) the vault at `path`. `storage_key` is 32
    /// random bytes the app keeps in the OS keystore.
    pub fn open(path: String, storage_key: Vec<u8>) -> Result<SkylineCrypto> {
        Self::from_vault(Vault::open(Some(&path), &Zeroizing::new(storage_key))?)
    }

    /// An in-memory device, for tests and tools. Gone when dropped.
    pub fn open_in_memory() -> Result<SkylineCrypto> {
        let mut key = Zeroizing::new(vec![0u8; 32]);
        rng().fill_bytes(&mut key);
        Self::from_vault(Vault::open(None, &key)?)
    }

    fn from_vault(vault: Vault) -> Result<SkylineCrypto> {
        if vault.get(META, META_IDENTITY)?.is_none() {
            // Entries exist but none is visible under this key: the wrong key.
            // Never create a second identity inside someone's existing vault.
            if !vault.is_empty()? {
                return Err(CryptoError::locked());
            }
            let mut r = rng();
            let identity = IdentityKeyPair::generate(&mut r);
            // libsignal registration ids fit in 14 bits and are never 0.
            let registration_id: u32 = r.random_range(1..=16380);
            let mut signing = Zeroizing::new([0u8; 32]);
            r.fill_bytes(signing.as_mut());
            vault.begin()?;
            let written = (|| {
                vault.put(META, META_IDENTITY, &identity.serialize())?;
                vault.put(META, META_REGISTRATION, &registration_id.to_le_bytes())?;
                vault.put(META, META_SIGNING_KEY, signing.as_ref())?;
                for counter in [META_NEXT_PREKEY, META_NEXT_SIGNED, META_NEXT_KYBER] {
                    // Random starting ids, as Signal does.
                    let start: u32 = r.random_range(1..=MAX_KEY_ID);
                    vault.put(META, counter, &start.to_le_bytes())?;
                }
                Ok(())
            })();
            match written {
                Ok(()) => vault.commit()?,
                Err(e) => {
                    vault.rollback();
                    return Err(e);
                }
            }
        }
        let crypto = SkylineCrypto {
            vault: Mutex::new(vault),
        };
        // Proves the storage key is right before anyone relies on this vault.
        crypto.identity()?;
        Ok(crypto)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vault> {
        // An operation that failed rolled its transaction back, so the vault is
        // still consistent; carry on rather than poisoning the device forever.
        self.vault.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Runs `f` as one vault transaction, holding the device lock throughout.
    fn atomic<T>(&self, f: impl FnOnce(&Vault) -> Result<T>) -> Result<T> {
        let vault = self.lock();
        vault.begin()?;
        match f(&vault) {
            Ok(v) => {
                vault.commit()?;
                Ok(v)
            }
            Err(e) => {
                vault.rollback();
                Err(e)
            }
        }
    }

    // ------------------------------------------------------------- identity

    pub fn identity(&self) -> Result<DeviceIdentity> {
        let vault = self.lock();
        let store = VaultStore { vault: &vault };
        let pair = store.identity_key_pair()?;
        let registration_id = block_on(store.get_local_registration_id())?;
        let signing = signing_key(&vault)?;
        Ok(DeviceIdentity {
            identity_key: pair.identity_key().serialize().to_vec(),
            registration_id,
            signing_key: signing.verifying_key().to_bytes().to_vec(),
        })
    }

    /// Ed25519 signature with the device credential key (activation, refresh).
    pub fn sign(&self, message: Vec<u8>) -> Result<Vec<u8>> {
        let vault = self.lock();
        Ok(signing_key(&vault)?.sign(&message).to_bytes().to_vec())
    }

    /// Records who this device is, once the server has activated it. Needed
    /// before any message can be encrypted or decrypted. Set once, for good.
    pub fn set_local_address(&self, user_id: String, device_number: u32) -> Result<()> {
        let address = address(&user_id, device_number)?;
        let vault = self.lock();
        if let Some(existing) = vault.get(META, META_LOCAL_ADDRESS)? {
            if existing != address.to_string().into_bytes() {
                return Err(CryptoError::invalid(
                    "this device already has a different address",
                ));
            }
            return Ok(());
        }
        vault.put(META, META_LOCAL_ADDRESS, address.to_string().as_bytes())
    }

    // -------------------------------------------------------------- prekeys

    /// A new signed prekey. Upload it, then keep rotating (Signal: about
    /// weekly). Old ones stay usable for messages already in flight.
    pub fn new_signed_pre_key(&self) -> Result<SignedPreKeyPublic> {
        self.atomic(|vault| {
            let mut store = VaultStore { vault };
            let id = next_id(vault, META_NEXT_SIGNED, 1)?;
            let identity = store.identity_key_pair()?;
            let mut r = rng();
            let pair = KeyPair::generate(&mut r);
            let signature = identity
                .private_key()
                .calculate_signature(&pair.public_key.serialize(), &mut r)
                .map_err(protocol)?;
            let record = SignedPreKeyRecord::new(id.into(), now(), &pair, &signature);
            block_on(store.save_signed_pre_key(id.into(), &record))?;
            Ok(SignedPreKeyPublic {
                key_id: id,
                public_key: pair.public_key.serialize().to_vec(),
                signature: signature.to_vec(),
            })
        })
    }

    /// The reusable Kyber key for when one-time ones run out.
    pub fn new_last_resort_kyber_pre_key(&self) -> Result<SignedPreKeyPublic> {
        self.atomic(|vault| new_kyber(vault, false))
    }

    /// `count` one-time Kyber keys (each destroyed after its first use).
    pub fn new_kyber_pre_keys(&self, count: u32) -> Result<Vec<SignedPreKeyPublic>> {
        check_batch(count)?;
        self.atomic(|vault| (0..count).map(|_| new_kyber(vault, true)).collect())
    }

    /// `count` one-time EC prekeys (each destroyed after its first use).
    pub fn new_one_time_pre_keys(&self, count: u32) -> Result<Vec<OneTimePreKeyPublic>> {
        check_batch(count)?;
        self.atomic(|vault| {
            let mut store = VaultStore { vault };
            let first = next_id(vault, META_NEXT_PREKEY, count)?;
            let mut r = rng();
            (0..count)
                .map(|i| {
                    let id = wrap(first, i);
                    let pair = KeyPair::generate(&mut r);
                    let record = PreKeyRecord::new(id.into(), &pair);
                    block_on(store.save_pre_key(id.into(), &record))?;
                    Ok(OneTimePreKeyPublic {
                        key_id: id,
                        public_key: pair.public_key.serialize().to_vec(),
                    })
                })
                .collect()
        })
    }

    // ------------------------------------------------------------- sessions

    /// Starts an encrypted session with one of a contact's devices, from the
    /// bundle the key directory returned. libsignal verifies both prekey
    /// signatures against the identity key here; a forged bundle fails.
    pub fn start_session(&self, user_id: String, bundle: PreKeyBundleInput) -> Result<()> {
        let remote = address(&user_id, bundle.device_number)?;
        let identity = IdentityKey::decode(&bundle.identity_key)?;
        let pre_key = match &bundle.pre_key {
            Some(k) => Some((
                k.key_id.into(),
                PublicKey::deserialize(&k.public_key).map_err(protocol)?,
            )),
            None => None,
        };
        let signal_bundle = PreKeyBundle::new(
            bundle.registration_id,
            device_id(bundle.device_number)?,
            pre_key,
            bundle.signed_pre_key.key_id.into(),
            PublicKey::deserialize(&bundle.signed_pre_key.public_key).map_err(protocol)?,
            bundle.signed_pre_key.signature.clone(),
            bundle.kyber_pre_key.key_id.into(),
            kem::PublicKey::deserialize(&bundle.kyber_pre_key.public_key)?,
            bundle.kyber_pre_key.signature.clone(),
            identity,
        )?;
        self.atomic(|vault| {
            let local = local_address(vault)?;
            let (mut sessions, mut identities) = (VaultStore { vault }, VaultStore { vault });
            block_on(process_prekey_bundle(
                &remote,
                &local,
                &mut sessions,
                &mut identities,
                &signal_bundle,
                SystemTime::now(),
                &mut rng(),
            ))?;
            Ok(())
        })
    }

    pub fn has_session(&self, user_id: String, device_number: u32) -> Result<bool> {
        let remote = address(&user_id, device_number)?;
        let vault = self.lock();
        let store = VaultStore { vault: &vault };
        match block_on(store.load_session(&remote))? {
            None => Ok(false),
            Some(s) => s
                .has_usable_sender_chain(SystemTime::now(), SessionUsabilityRequirements::NotStale)
                .map_err(protocol),
        }
    }

    pub fn encrypt(
        &self,
        user_id: String,
        device_number: u32,
        plaintext: Vec<u8>,
    ) -> Result<Envelope> {
        let remote = address(&user_id, device_number)?;
        self.atomic(|vault| {
            let local = local_address(vault)?;
            let (mut sessions, mut identities) = (VaultStore { vault }, VaultStore { vault });
            let message = block_on(message_encrypt(
                &plaintext,
                &remote,
                &local,
                &mut sessions,
                &mut identities,
                SystemTime::now(),
                &mut rng(),
            ))?;
            match message {
                CiphertextMessage::PreKeySignalMessage(m) => Ok(Envelope {
                    kind: EnvelopeKind::PreKey,
                    body: m.serialized().to_vec(),
                }),
                CiphertextMessage::SignalMessage(m) => Ok(Envelope {
                    kind: EnvelopeKind::Whisper,
                    body: m.serialized().to_vec(),
                }),
                _ => Err(CryptoError::protocol("unexpected message type")),
            }
        })
    }

    /// Decrypts one envelope from a contact's device. A tampered, replayed or
    /// misaddressed message is an error and changes nothing.
    ///
    /// `directory_identity_key` is the identity key the server's key directory
    /// lists for that sending device. It is REQUIRED for a session-starting
    /// message from a device this one has never seen: the key inside the
    /// message must match it, or the message is refused as an untrusted
    /// identity. Otherwise a server could present someone's genuine first
    /// message as coming from a different person's new device
    /// (known-risks.md). For devices already known, libsignal's own check
    /// against the stored key applies and this argument is ignored.
    pub fn decrypt(
        &self,
        user_id: String,
        device_number: u32,
        envelope: Envelope,
        directory_identity_key: Option<Vec<u8>>,
    ) -> Result<Vec<u8>> {
        let remote = address(&user_id, device_number)?;
        let message = match envelope.kind {
            EnvelopeKind::PreKey => CiphertextMessage::PreKeySignalMessage(
                PreKeySignalMessage::try_from(envelope.body.as_slice())?,
            ),
            EnvelopeKind::Whisper => {
                CiphertextMessage::SignalMessage(SignalMessage::try_from(envelope.body.as_slice())?)
            }
        };
        self.atomic(|vault| {
            let local = local_address(vault)?;
            // One independent view per store argument; each only borrows the vault.
            let view = || VaultStore { vault };

            if let CiphertextMessage::PreKeySignalMessage(m) = &message {
                let known = block_on(view().get_identity(&remote))?;
                if known.is_none() {
                    let claimed = m.identity_key().serialize();
                    let matches = directory_identity_key
                        .as_deref()
                        .is_some_and(|d| d == claimed.as_ref());
                    if !matches {
                        return Err(CryptoError::new(
                            CryptoErrorKind::UntrustedIdentity,
                            format!(
                                "the first message from {remote} carries an identity key the directory does not list for that device"
                            ),
                        ));
                    }
                }
            }

            let (mut sessions, mut identities, mut prekeys, signed, mut kyber) =
                (view(), view(), view(), view(), view());
            Ok(block_on(message_decrypt(
                &message,
                &remote,
                &local,
                &mut sessions,
                &mut identities,
                &mut prekeys,
                &signed,
                &mut kyber,
                &mut rng(),
            ))?)
        })
    }

    // -------------------------------------------------------- safety numbers

    /// The safety number between this device and one device of a contact. Both
    /// sides compute the same digits. Each side's identifier is its
    /// `user-id.device-number` address, since every device has its own identity.
    pub fn safety_number(
        &self,
        their_user_id: String,
        their_device_number: u32,
        their_identity_key: Vec<u8>,
    ) -> Result<SafetyNumber> {
        let vault = self.lock();
        let local = local_address(&vault)?;
        let mine = VaultStore { vault: &vault }.identity_key_pair()?;
        let theirs = IdentityKey::decode(&their_identity_key)?;
        let remote = address(&their_user_id, their_device_number)?;
        let fp = Fingerprint::new(
            FINGERPRINT_VERSION,
            FINGERPRINT_ITERATIONS,
            local.to_string().as_bytes(),
            mine.identity_key(),
            remote.to_string().as_bytes(),
            &theirs,
        )
        .map_err(protocol)?;
        Ok(SafetyNumber {
            displayable: fp.display_string().map_err(protocol)?,
            scannable: fp.scannable.serialize().map_err(protocol)?,
        })
    }

    // ------------------------------------------------ the app's own records

    /// Stores (or replaces) one of the app's records, sealed in the vault:
    /// a message, a chat summary. `kind` separates record types, `group`
    /// collects records listed together (a chat's messages), and `sort` orders
    /// them (a timestamp). Only `sort` is readable in the file.
    pub fn put_record(
        &self,
        kind: String,
        id: String,
        group: String,
        sort: i64,
        value: Vec<u8>,
    ) -> Result<()> {
        self.lock().record_put(&kind, &id, &group, sort, &value)
    }

    pub fn get_record(&self, kind: String, id: String) -> Result<Option<Vec<u8>>> {
        self.lock().record_get(&kind, &id)
    }

    /// Newest first, `sort` strictly below `before_sort` (all when `None`).
    pub fn list_records(
        &self,
        kind: String,
        group: String,
        before_sort: Option<i64>,
        limit: u32,
    ) -> Result<Vec<StoredRecord>> {
        Ok(self
            .lock()
            .record_list(&kind, &group, before_sort, limit.min(1000))?
            .into_iter()
            .map(|(sort, value)| StoredRecord { sort, value })
            .collect())
    }

    /// Deletes for good (SQLite `secure_delete` overwrites the freed space).
    pub fn delete_record(&self, kind: String, id: String) -> Result<bool> {
        self.lock().record_delete(&kind, &id)
    }

    pub fn delete_record_group(&self, kind: String, group: String) -> Result<u32> {
        self.lock().record_delete_group(&kind, &group)
    }

    #[doc(hidden)]
    pub fn raw_vault_for_tests(&self) -> Vec<Vec<u8>> {
        self.lock().raw_values_for_tests()
    }
}

// ------------------------------------------------------------------ helpers

fn protocol(e: impl std::fmt::Display) -> CryptoError {
    CryptoError::protocol(e.to_string())
}

fn rng() -> impl rand::CryptoRng {
    OsRng.unwrap_err()
}

fn now() -> Timestamp {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    Timestamp::from_epoch_millis(ms)
}

fn device_id(n: u32) -> Result<DeviceId> {
    u8::try_from(n)
        .ok()
        .and_then(|b| DeviceId::new(b).ok())
        .ok_or_else(|| CryptoError::invalid(format!("bad device number {n}")))
}

fn address(user_id: &str, device_number: u32) -> Result<ProtocolAddress> {
    let uuid = uuid::Uuid::parse_str(user_id)
        .map_err(|_| CryptoError::invalid("user id must be a UUID"))?;
    Ok(ProtocolAddress::new(
        uuid.to_string(),
        device_id(device_number)?,
    ))
}

fn local_address(vault: &Vault) -> Result<ProtocolAddress> {
    let bytes = vault.get(META, META_LOCAL_ADDRESS)?.ok_or_else(|| {
        CryptoError::new(
            CryptoErrorKind::NoLocalAddress,
            "activate this device first",
        )
    })?;
    let bad = || CryptoError::storage("bad local address");
    let text = String::from_utf8(bytes).map_err(|_| bad())?;
    let (user, device) = text.rsplit_once('.').ok_or_else(bad)?;
    address(user, device.parse().map_err(|_| bad())?)
}

fn signing_key(vault: &Vault) -> Result<SigningKey> {
    let bytes = Zeroizing::new(
        vault
            .get(META, META_SIGNING_KEY)?
            .ok_or_else(|| CryptoError::storage("no signing key"))?,
    );
    let arr: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| CryptoError::storage("bad signing key"))?;
    Ok(SigningKey::from_bytes(&arr))
}

fn wrap(first: u32, offset: u32) -> u32 {
    ((first - 1 + offset) % MAX_KEY_ID) + 1
}

/// Reserves `count` consecutive key ids (wrapping within 24 bits).
fn next_id(vault: &Vault, counter: &[u8], count: u32) -> Result<u32> {
    let bytes = vault
        .get(META, counter)?
        .ok_or_else(|| CryptoError::storage("missing key counter"))?;
    let first = u32::from_le_bytes(
        bytes
            .try_into()
            .map_err(|_| CryptoError::storage("bad key counter"))?,
    );
    vault.put(META, counter, &wrap(first, count).to_le_bytes())?;
    Ok(first)
}

fn check_batch(count: u32) -> Result<()> {
    if count == 0 || count > MAX_BATCH {
        return Err(CryptoError::invalid(format!(
            "generate between 1 and {MAX_BATCH} keys at a time"
        )));
    }
    Ok(())
}

fn new_kyber(vault: &Vault, one_time: bool) -> Result<SignedPreKeyPublic> {
    let mut store = VaultStore { vault };
    let id = next_id(vault, META_NEXT_KYBER, 1)?;
    let identity = store.identity_key_pair()?;
    let record = KyberPreKeyRecord::generate(KYBER, id.into(), identity.private_key())?;
    block_on(store.save_kyber_pre_key(id.into(), &record))?;
    if one_time {
        store.mark_kyber_one_time(id.into())?;
    }
    Ok(SignedPreKeyPublic {
        key_id: id,
        public_key: record.public_key()?.serialize().to_vec(),
        signature: record.signature()?,
    })
}
