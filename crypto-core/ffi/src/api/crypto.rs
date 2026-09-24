//! What the Skyline app can call. Mirrors skyline_crypto_core's API one to one;
//! see that crate for what each operation guarantees.
//!
//! Every call is asynchronous on the Dart side (flutter_rust_bridge runs it on
//! a worker thread): key generation and session setup are too slow for the UI
//! thread.

use flutter_rust_bridge::frb;
use skyline_crypto_core as core;

pub use core::CryptoErrorKind;

#[frb(mirror(CryptoErrorKind))]
pub enum _CryptoErrorKind {
    VaultLocked,
    Storage,
    InvalidInput,
    UntrustedIdentity,
    NoSession,
    NoLocalAddress,
    Protocol,
}

/// Thrown on the Dart side for every failure. `message` never contains key
/// material or plaintext.
#[derive(Debug)]
pub struct CryptoException {
    pub kind: CryptoErrorKind,
    pub message: String,
}

impl From<core::CryptoError> for CryptoException {
    fn from(e: core::CryptoError) -> Self {
        Self {
            kind: e.kind,
            message: e.message,
        }
    }
}

type Result<T> = std::result::Result<T, CryptoException>;

pub struct DeviceIdentity {
    pub identity_key: Vec<u8>,
    pub registration_id: u32,
    pub signing_key: Vec<u8>,
}

pub struct SignedPreKey {
    pub key_id: u32,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

pub struct OneTimePreKey {
    pub key_id: u32,
    pub public_key: Vec<u8>,
}

pub struct PreKeyBundle {
    pub registration_id: u32,
    pub device_number: u32,
    pub identity_key: Vec<u8>,
    pub signed_pre_key: SignedPreKey,
    pub kyber_pre_key: SignedPreKey,
    pub pre_key: Option<OneTimePreKey>,
}

pub enum EnvelopeKind {
    PreKey,
    Whisper,
}

pub struct Envelope {
    pub kind: EnvelopeKind,
    pub body: Vec<u8>,
}

pub struct StoredRecord {
    pub sort: i64,
    pub value: Vec<u8>,
}

pub struct SafetyNumber {
    pub displayable: String,
    pub scannable: Vec<u8>,
}

/// One device's keys and sessions, backed by its encrypted vault. Opaque to
/// Dart: nothing inside it can be read from the app, only used.
#[frb(opaque)]
pub struct CryptoDevice(core::SkylineCrypto);

impl CryptoDevice {
    /// Opens (or on first use creates) the vault file. `storage_key` is 32
    /// bytes the app keeps in the OS keystore.
    pub fn open(path: String, storage_key: Vec<u8>) -> Result<CryptoDevice> {
        Ok(CryptoDevice(core::SkylineCrypto::open(path, storage_key)?))
    }

    /// A throwaway in-memory device (tests and diagnostics only).
    pub fn open_in_memory() -> Result<CryptoDevice> {
        Ok(CryptoDevice(core::SkylineCrypto::open_in_memory()?))
    }

    pub fn identity(&self) -> Result<DeviceIdentity> {
        let i = self.0.identity()?;
        Ok(DeviceIdentity {
            identity_key: i.identity_key,
            registration_id: i.registration_id,
            signing_key: i.signing_key,
        })
    }

    pub fn sign(&self, message: Vec<u8>) -> Result<Vec<u8>> {
        Ok(self.0.sign(message)?)
    }

    pub fn set_local_address(&self, user_id: String, device_number: u32) -> Result<()> {
        Ok(self.0.set_local_address(user_id, device_number)?)
    }

    pub fn new_signed_pre_key(&self) -> Result<SignedPreKey> {
        Ok(signed(self.0.new_signed_pre_key()?))
    }

    pub fn new_last_resort_kyber_pre_key(&self) -> Result<SignedPreKey> {
        Ok(signed(self.0.new_last_resort_kyber_pre_key()?))
    }

    pub fn new_kyber_pre_keys(&self, count: u32) -> Result<Vec<SignedPreKey>> {
        Ok(self
            .0
            .new_kyber_pre_keys(count)?
            .into_iter()
            .map(signed)
            .collect())
    }

    pub fn new_one_time_pre_keys(&self, count: u32) -> Result<Vec<OneTimePreKey>> {
        Ok(self
            .0
            .new_one_time_pre_keys(count)?
            .into_iter()
            .map(|k| OneTimePreKey {
                key_id: k.key_id,
                public_key: k.public_key,
            })
            .collect())
    }

    pub fn start_session(&self, user_id: String, bundle: PreKeyBundle) -> Result<()> {
        let unsigned = |k: SignedPreKey| core::SignedPreKeyPublic {
            key_id: k.key_id,
            public_key: k.public_key,
            signature: k.signature,
        };
        Ok(self.0.start_session(
            user_id,
            core::PreKeyBundleInput {
                registration_id: bundle.registration_id,
                device_number: bundle.device_number,
                identity_key: bundle.identity_key,
                signed_pre_key: unsigned(bundle.signed_pre_key),
                kyber_pre_key: unsigned(bundle.kyber_pre_key),
                pre_key: bundle.pre_key.map(|k| core::OneTimePreKeyPublic {
                    key_id: k.key_id,
                    public_key: k.public_key,
                }),
            },
        )?)
    }

    pub fn has_session(&self, user_id: String, device_number: u32) -> Result<bool> {
        Ok(self.0.has_session(user_id, device_number)?)
    }

    pub fn encrypt(
        &self,
        user_id: String,
        device_number: u32,
        plaintext: Vec<u8>,
    ) -> Result<Envelope> {
        let e = self.0.encrypt(user_id, device_number, plaintext)?;
        Ok(Envelope {
            kind: match e.kind {
                core::EnvelopeKind::PreKey => EnvelopeKind::PreKey,
                core::EnvelopeKind::Whisper => EnvelopeKind::Whisper,
            },
            body: e.body,
        })
    }

    /// `directory_identity_key`: the key directory's identity key for the
    /// sending device. Required for a first message from an unseen device.
    pub fn decrypt(
        &self,
        user_id: String,
        device_number: u32,
        envelope: Envelope,
        directory_identity_key: Option<Vec<u8>>,
    ) -> Result<Vec<u8>> {
        Ok(self.0.decrypt(
            user_id,
            device_number,
            core::Envelope {
                kind: match envelope.kind {
                    EnvelopeKind::PreKey => core::EnvelopeKind::PreKey,
                    EnvelopeKind::Whisper => core::EnvelopeKind::Whisper,
                },
                body: envelope.body,
            },
            directory_identity_key,
        )?)
    }

    pub fn safety_number(
        &self,
        their_user_id: String,
        their_device_number: u32,
        their_identity_key: Vec<u8>,
    ) -> Result<SafetyNumber> {
        let s = self
            .0
            .safety_number(their_user_id, their_device_number, their_identity_key)?;
        Ok(SafetyNumber {
            displayable: s.displayable,
            scannable: s.scannable,
        })
    }

    // The app's own encrypted records (messages, chat summaries).

    pub fn put_record(
        &self,
        kind: String,
        id: String,
        group: String,
        sort: i64,
        value: Vec<u8>,
    ) -> Result<()> {
        Ok(self.0.put_record(kind, id, group, sort, value)?)
    }

    pub fn get_record(&self, kind: String, id: String) -> Result<Option<Vec<u8>>> {
        Ok(self.0.get_record(kind, id)?)
    }

    pub fn list_records(
        &self,
        kind: String,
        group: String,
        before_sort: Option<i64>,
        limit: u32,
    ) -> Result<Vec<StoredRecord>> {
        Ok(self
            .0
            .list_records(kind, group, before_sort, limit)?
            .into_iter()
            .map(|r| StoredRecord {
                sort: r.sort,
                value: r.value,
            })
            .collect())
    }

    pub fn delete_record(&self, kind: String, id: String) -> Result<bool> {
        Ok(self.0.delete_record(kind, id)?)
    }

    pub fn delete_record_group(&self, kind: String, group: String) -> Result<u32> {
        Ok(self.0.delete_record_group(kind, group)?)
    }
}

fn signed(k: core::SignedPreKeyPublic) -> SignedPreKey {
    SignedPreKey {
        key_id: k.key_id,
        public_key: k.public_key,
        signature: k.signature,
    }
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
