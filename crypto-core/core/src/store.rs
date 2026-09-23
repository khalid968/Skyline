//! libsignal's storage traits, backed by the encrypted vault.
//!
//! Semantics follow libsignal's reference in-memory store, with one deliberate
//! difference: identity trust is STRICT. Skyline identity keys never change
//! (the server refuses to change one; a new key is a new device), so a contact
//! device presenting a different key than the one on record is refused, never
//! silently accepted.

use async_trait::async_trait;
use libsignal_protocol::{
    CiphertextMessageType, Direction, GenericSignedPreKey as _, IdentityChange, IdentityKey,
    IdentityKeyPair, IdentityKeyStore, KyberPreKeyId, KyberPreKeyRecord, KyberPreKeyStore,
    PreKeyId, PreKeyRecord, PreKeyStore, ProtocolAddress, PublicKey, SessionRecord, SessionStore,
    SignalProtocolError, SignedPreKeyId, SignedPreKeyRecord, SignedPreKeyStore,
};

use crate::error::{CryptoError, to_signal};
use crate::vault::Vault;

type Result<T> = std::result::Result<T, SignalProtocolError>;

// Vault namespaces.
pub(crate) const META: &str = "meta";
const SESSION: &str = "session";
const IDENTITY: &str = "identity";
const PREKEY: &str = "prekey";
const SIGNED: &str = "signed-prekey";
const KYBER: &str = "kyber-prekey";
const KYBER_ONE_TIME: &str = "kyber-one-time";
const KYBER_SEEN: &str = "kyber-base-key-seen";

pub(crate) const META_IDENTITY: &[u8] = b"identity-key-pair";
pub(crate) const META_REGISTRATION: &[u8] = b"registration-id";

/// A view of the vault that implements libsignal's store traits. It only
/// borrows the vault (every vault call takes `&self`), so libsignal can be
/// handed several independent views at once, one per trait argument, without
/// ever aliasing a mutable reference.
pub struct VaultStore<'a> {
    pub(crate) vault: &'a Vault,
}

impl VaultStore<'_> {
    fn get(&self, ns: &str, key: &[u8]) -> Result<Option<Vec<u8>>> {
        self.vault.get(ns, key).map_err(to_signal)
    }
    fn put(&self, ns: &str, key: &[u8], value: &[u8]) -> Result<()> {
        self.vault.put(ns, key, value).map_err(to_signal)
    }
    fn delete(&self, ns: &str, key: &[u8]) -> Result<()> {
        self.vault.delete(ns, key).map_err(to_signal)
    }

    pub(crate) fn identity_key_pair(&self) -> std::result::Result<IdentityKeyPair, CryptoError> {
        let bytes = self
            .vault
            .get(META, META_IDENTITY)?
            .ok_or_else(|| CryptoError::storage("this vault has no identity"))?;
        Ok(IdentityKeyPair::try_from(bytes.as_slice())?)
    }

    pub(crate) fn mark_kyber_one_time(
        &self,
        id: KyberPreKeyId,
    ) -> std::result::Result<(), CryptoError> {
        self.vault
            .put(KYBER_ONE_TIME, &u32::from(id).to_le_bytes(), &[1])
    }
}

fn addr_key(address: &ProtocolAddress) -> Vec<u8> {
    address.to_string().into_bytes()
}

#[async_trait(?Send)]
impl IdentityKeyStore for VaultStore<'_> {
    async fn get_identity_key_pair(&self) -> Result<IdentityKeyPair> {
        self.identity_key_pair().map_err(to_signal)
    }

    async fn get_local_registration_id(&self) -> Result<u32> {
        let bytes = self
            .get(META, META_REGISTRATION)?
            .ok_or_else(|| to_signal(CryptoError::storage("no registration id")))?;
        let arr: [u8; 4] = bytes
            .try_into()
            .map_err(|_| to_signal(CryptoError::storage("bad registration id")))?;
        Ok(u32::from_le_bytes(arr))
    }

    async fn save_identity(
        &mut self,
        address: &ProtocolAddress,
        identity: &IdentityKey,
    ) -> Result<IdentityChange> {
        let key = addr_key(address);
        match self.get(IDENTITY, &key)? {
            None => {
                self.put(IDENTITY, &key, &identity.serialize())?;
                Ok(IdentityChange::NewOrUnchanged)
            }
            Some(known) if known.as_slice() == identity.serialize().as_ref() => {
                Ok(IdentityChange::NewOrUnchanged)
            }
            // Never overwrite a known identity. is_trusted_identity refuses the
            // new key before libsignal gets here; refusing again is belt and
            // braces.
            Some(_) => Err(SignalProtocolError::UntrustedIdentity(address.clone())),
        }
    }

    async fn is_trusted_identity(
        &self,
        address: &ProtocolAddress,
        identity: &IdentityKey,
        _direction: Direction,
    ) -> Result<bool> {
        Ok(match self.get(IDENTITY, &addr_key(address))? {
            None => true, // first contact with this device
            Some(known) => known.as_slice() == identity.serialize().as_ref(),
        })
    }

    async fn get_identity(&self, address: &ProtocolAddress) -> Result<Option<IdentityKey>> {
        self.get(IDENTITY, &addr_key(address))?
            .map(|b| IdentityKey::decode(&b))
            .transpose()
    }
}

#[async_trait(?Send)]
impl SessionStore for VaultStore<'_> {
    async fn load_session(&self, address: &ProtocolAddress) -> Result<Option<SessionRecord>> {
        self.get(SESSION, &addr_key(address))?
            .map(|b| SessionRecord::deserialize(&b))
            .transpose()
    }

    async fn store_session(
        &mut self,
        address: &ProtocolAddress,
        record: &SessionRecord,
    ) -> Result<()> {
        self.put(SESSION, &addr_key(address), &record.serialize()?)
    }
}

#[async_trait(?Send)]
impl PreKeyStore for VaultStore<'_> {
    async fn get_pre_key(&self, id: PreKeyId) -> Result<PreKeyRecord> {
        self.get(PREKEY, &u32::from(id).to_le_bytes())?
            .map(|b| PreKeyRecord::deserialize(&b))
            .transpose()?
            .ok_or(SignalProtocolError::InvalidPreKeyId)
    }

    async fn save_pre_key(&mut self, id: PreKeyId, record: &PreKeyRecord) -> Result<()> {
        self.put(PREKEY, &u32::from(id).to_le_bytes(), &record.serialize()?)
    }

    // A one-time prekey is used once and then destroyed: forward secrecy for
    // the first message depends on it being gone.
    async fn remove_pre_key(&mut self, id: PreKeyId) -> Result<()> {
        self.delete(PREKEY, &u32::from(id).to_le_bytes())
    }
}

#[async_trait(?Send)]
impl SignedPreKeyStore for VaultStore<'_> {
    async fn get_signed_pre_key(&self, id: SignedPreKeyId) -> Result<SignedPreKeyRecord> {
        self.get(SIGNED, &u32::from(id).to_le_bytes())?
            .map(|b| SignedPreKeyRecord::deserialize(&b))
            .transpose()?
            .ok_or(SignalProtocolError::InvalidSignedPreKeyId)
    }

    async fn save_signed_pre_key(
        &mut self,
        id: SignedPreKeyId,
        record: &SignedPreKeyRecord,
    ) -> Result<()> {
        self.put(SIGNED, &u32::from(id).to_le_bytes(), &record.serialize()?)
    }
}

#[async_trait(?Send)]
impl KyberPreKeyStore for VaultStore<'_> {
    async fn get_kyber_pre_key(&self, id: KyberPreKeyId) -> Result<KyberPreKeyRecord> {
        self.get(KYBER, &u32::from(id).to_le_bytes())?
            .map(|b| KyberPreKeyRecord::deserialize(&b))
            .transpose()?
            .ok_or(SignalProtocolError::InvalidKyberPreKeyId)
    }

    async fn save_kyber_pre_key(
        &mut self,
        id: KyberPreKeyId,
        record: &KyberPreKeyRecord,
    ) -> Result<()> {
        self.put(KYBER, &u32::from(id).to_le_bytes(), &record.serialize()?)
    }

    // A one-time Kyber key is destroyed after use, like a one-time EC key. The
    // last-resort key is reused by design, so instead we remember every base
    // key seen with it and refuse a repeat: that is a replayed first message.
    async fn mark_kyber_pre_key_used(
        &mut self,
        kyber_id: KyberPreKeyId,
        ec_prekey_id: SignedPreKeyId,
        base_key: &PublicKey,
    ) -> Result<()> {
        let id_bytes = u32::from(kyber_id).to_le_bytes();
        if self.get(KYBER_ONE_TIME, &id_bytes)?.is_some() {
            self.delete(KYBER, &id_bytes)?;
            self.delete(KYBER_ONE_TIME, &id_bytes)?;
            return Ok(());
        }
        let mut seen = id_bytes.to_vec();
        seen.extend_from_slice(&u32::from(ec_prekey_id).to_le_bytes());
        seen.extend_from_slice(&base_key.serialize());
        if self.get(KYBER_SEEN, &seen)?.is_some() {
            return Err(SignalProtocolError::InvalidMessage(
                CiphertextMessageType::PreKey,
                "reused base key".to_owned(),
            ));
        }
        self.put(KYBER_SEEN, &seen, &[1])
    }
}

#[cfg(test)]
mod tests {
    //! Each protection on its own. Several back each other up (trust is
    //! checked, then enforced again on save), so the end-to-end tests alone
    //! would not notice one of them breaking.
    use super::*;
    use futures::executor::block_on;
    use libsignal_protocol::{DeviceId, KeyPair, kem};
    use rand::TryRngCore as _;
    use rand::rngs::OsRng;

    fn vault() -> Vault {
        Vault::open(None, &[3u8; 32]).unwrap()
    }
    fn addr() -> ProtocolAddress {
        ProtocolAddress::new("someone".into(), DeviceId::new(1).unwrap())
    }
    fn identity() -> IdentityKey {
        *IdentityKeyPair::generate(&mut OsRng.unwrap_err()).identity_key()
    }

    #[test]
    fn trust_is_first_use_then_exactly_that_key() {
        let v = vault();
        let mut s = VaultStore { vault: &v };
        let (k1, k2) = (identity(), identity());
        assert!(block_on(s.is_trusted_identity(&addr(), &k1, Direction::Sending)).unwrap());
        block_on(s.save_identity(&addr(), &k1)).unwrap();
        assert!(block_on(s.is_trusted_identity(&addr(), &k1, Direction::Receiving)).unwrap());
        assert!(!block_on(s.is_trusted_identity(&addr(), &k2, Direction::Sending)).unwrap());
    }

    #[test]
    fn a_known_identity_is_never_overwritten() {
        let v = vault();
        let mut s = VaultStore { vault: &v };
        let (k1, k2) = (identity(), identity());
        block_on(s.save_identity(&addr(), &k1)).unwrap();
        assert!(block_on(s.save_identity(&addr(), &k2)).is_err());
        assert_eq!(block_on(s.get_identity(&addr())).unwrap(), Some(k1));
    }

    #[test]
    fn a_used_one_time_prekey_is_destroyed() {
        let v = vault();
        let mut s = VaultStore { vault: &v };
        let pair = KeyPair::generate(&mut OsRng.unwrap_err());
        block_on(s.save_pre_key(9.into(), &PreKeyRecord::new(9.into(), &pair))).unwrap();
        block_on(s.remove_pre_key(9.into())).unwrap();
        assert!(matches!(
            block_on(s.get_pre_key(9.into())),
            Err(SignalProtocolError::InvalidPreKeyId)
        ));
    }

    #[test]
    fn a_one_time_kyber_key_is_destroyed_and_the_last_resort_one_refuses_replays() {
        let v = vault();
        let mut s = VaultStore { vault: &v };
        let signer = IdentityKeyPair::generate(&mut OsRng.unwrap_err());
        let base = KeyPair::generate(&mut OsRng.unwrap_err()).public_key;
        let other_base = KeyPair::generate(&mut OsRng.unwrap_err()).public_key;
        for id in [1u32, 2] {
            let r = KyberPreKeyRecord::generate(
                kem::KeyType::Kyber1024,
                id.into(),
                signer.private_key(),
            )
            .unwrap();
            block_on(s.save_kyber_pre_key(id.into(), &r)).unwrap();
        }
        s.mark_kyber_one_time(1.into()).unwrap();

        block_on(s.mark_kyber_pre_key_used(1.into(), 5.into(), &base)).unwrap();
        assert!(
            block_on(s.get_kyber_pre_key(1.into())).is_err(),
            "one-time key must be gone"
        );

        block_on(s.mark_kyber_pre_key_used(2.into(), 5.into(), &base)).unwrap();
        assert!(
            block_on(s.get_kyber_pre_key(2.into())).is_ok(),
            "last resort stays"
        );
        assert!(
            block_on(s.mark_kyber_pre_key_used(2.into(), 5.into(), &base)).is_err(),
            "the same base key twice is a replay"
        );
        block_on(s.mark_kyber_pre_key_used(2.into(), 5.into(), &other_base)).unwrap();
    }
}
