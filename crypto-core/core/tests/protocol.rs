//! End-to-end tests of the crypto core with real libsignal: two (or three)
//! devices, each with its own encrypted vault, exchanging messages through
//! nothing but the bytes a server would carry.

use ed25519_dalek::{Signature, Verifier as _, VerifyingKey};
use skyline_crypto_core::*;

struct Device {
    crypto: SkylineCrypto,
    user_id: String,
    device_number: u32,
    /// Keys this device "uploaded", as the key directory would hold them.
    signed: Option<SignedPreKeyPublic>,
    last_resort: Option<SignedPreKeyPublic>,
    one_time: Vec<OneTimePreKeyPublic>,
    kyber: Vec<SignedPreKeyPublic>,
}

impl Device {
    fn new(user_id: &str, device_number: u32) -> Device {
        let crypto = SkylineCrypto::open_in_memory().unwrap();
        crypto
            .set_local_address(user_id.into(), device_number)
            .unwrap();
        let mut d = Device {
            crypto,
            user_id: user_id.into(),
            device_number,
            signed: None,
            last_resort: None,
            one_time: vec![],
            kyber: vec![],
        };
        d.signed = Some(d.crypto.new_signed_pre_key().unwrap());
        d.last_resort = Some(d.crypto.new_last_resort_kyber_pre_key().unwrap());
        d.one_time = d.crypto.new_one_time_pre_keys(5).unwrap();
        d.kyber = d.crypto.new_kyber_pre_keys(5).unwrap();
        d
    }

    /// What the key directory would hand out: one-time keys first (claimed),
    /// then the last-resort Kyber key and no EC one-time key.
    fn bundle(&mut self) -> PreKeyBundleInput {
        let id = self.crypto.identity().unwrap();
        let kyber = self
            .kyber
            .pop()
            .unwrap_or_else(|| clone_signed(self.last_resort.as_ref().unwrap()));
        PreKeyBundleInput {
            registration_id: id.registration_id,
            device_number: self.device_number,
            identity_key: id.identity_key,
            signed_pre_key: clone_signed(self.signed.as_ref().unwrap()),
            kyber_pre_key: kyber,
            pre_key: self.one_time.pop(),
        }
    }

    fn send(&self, to: &Device, text: &str) -> Envelope {
        self.crypto
            .encrypt(
                to.user_id.clone(),
                to.device_number,
                text.as_bytes().to_vec(),
            )
            .unwrap()
    }

    /// Receives with the sender's REAL identity key as the directory's answer.
    fn receive(&self, from: &Device, env: &Envelope) -> Result<String, CryptoError> {
        let directory = from.crypto.identity().unwrap().identity_key;
        self.receive_checked(from, env, Some(directory))
    }

    fn receive_checked(
        &self,
        from: &Device,
        env: &Envelope,
        directory: Option<Vec<u8>>,
    ) -> Result<String, CryptoError> {
        self.crypto
            .decrypt(
                from.user_id.clone(),
                from.device_number,
                copy(env),
                directory,
            )
            .map(|b| String::from_utf8(b).unwrap())
    }
}

fn clone_signed(k: &SignedPreKeyPublic) -> SignedPreKeyPublic {
    SignedPreKeyPublic {
        key_id: k.key_id,
        public_key: k.public_key.clone(),
        signature: k.signature.clone(),
    }
}

fn copy(e: &Envelope) -> Envelope {
    Envelope {
        kind: e.kind,
        body: e.body.clone(),
    }
}

const ALICE: &str = "6f0b6a1e-0000-4000-8000-00000000000a";
const BOB: &str = "6f0b6a1e-0000-4000-8000-00000000000b";

fn connected() -> (Device, Device) {
    let alice = Device::new(ALICE, 1);
    let mut bob = Device::new(BOB, 1);
    alice
        .crypto
        .start_session(BOB.into(), bob.bundle())
        .unwrap();
    (alice, bob)
}

#[test]
fn a_conversation_both_ways() {
    let (alice, bob) = connected();
    assert!(alice.crypto.has_session(BOB.into(), 1).unwrap());
    assert!(!bob.crypto.has_session(ALICE.into(), 1).unwrap());

    let first = alice.send(&bob, "hello bob");
    assert_eq!(
        first.kind,
        EnvelopeKind::PreKey,
        "the first message sets up the session"
    );
    assert_eq!(bob.receive(&alice, &first).unwrap(), "hello bob");

    let reply = bob.send(&alice, "hi alice");
    assert_eq!(reply.kind, EnvelopeKind::Whisper);
    assert_eq!(alice.receive(&bob, &reply).unwrap(), "hi alice");

    for i in 0..20 {
        let m = alice.send(&bob, &format!("message {i}"));
        assert_eq!(m.kind, EnvelopeKind::Whisper);
        assert_eq!(bob.receive(&alice, &m).unwrap(), format!("message {i}"));
        let r = bob.send(&alice, &format!("reply {i}"));
        assert_eq!(alice.receive(&bob, &r).unwrap(), format!("reply {i}"));
    }
}

#[test]
fn the_ciphertext_does_not_contain_the_message() {
    let (alice, bob) = connected();
    let secret = "the launch code is 0000";
    let env = alice.send(&bob, secret);
    assert!(!contains(&env.body, secret.as_bytes()));
    // And the same text twice never produces the same bytes.
    let again = alice.send(&bob, secret);
    assert_ne!(env.body, again.body);
}

#[test]
fn messages_arriving_out_of_order_still_decrypt() {
    let (alice, bob) = connected();
    let first = alice.send(&bob, "0");
    bob.receive(&alice, &first).unwrap();
    let a = alice.send(&bob, "a");
    let b = alice.send(&bob, "b");
    let c = alice.send(&bob, "c");
    assert_eq!(bob.receive(&alice, &c).unwrap(), "c");
    assert_eq!(bob.receive(&alice, &a).unwrap(), "a");
    assert_eq!(bob.receive(&alice, &b).unwrap(), "b");
}

#[test]
fn a_replayed_message_is_refused() {
    let (alice, bob) = connected();
    let first = alice.send(&bob, "once");
    bob.receive(&alice, &first).unwrap();
    let m = alice.send(&bob, "only once");
    assert_eq!(bob.receive(&alice, &m).unwrap(), "only once");
    assert!(
        bob.receive(&alice, &m).is_err(),
        "a duplicate must not decrypt twice"
    );
    // ...including the session-starting message, whose one-time prekey is gone.
    assert!(bob.receive(&alice, &first).is_err());
}

#[test]
fn a_tampered_message_is_refused_and_changes_nothing() {
    let (alice, bob) = connected();
    bob.receive(&alice, &alice.send(&bob, "setup")).unwrap();
    // Once Bob replies, Alice's messages are ordinary ratchet messages.
    alice.receive(&bob, &bob.send(&alice, "ack")).unwrap();
    let m = alice.send(&bob, "pay 10");
    assert_eq!(m.kind, EnvelopeKind::Whisper);

    // Flip every bit-0 of every byte. Byte 0 is the version byte, whose low
    // half only advertises the sender's newest supported version (libsignal
    // ignores it); every other byte is covered by the message MAC.
    for i in 1..m.body.len() {
        let mut forged = copy(&m);
        forged.body[i] ^= 0x01;
        assert!(
            bob.receive(&alice, &forged).is_err(),
            "byte {i} was not protected"
        );
    }
    let mut truncated = copy(&m);
    truncated.body.pop();
    assert!(bob.receive(&alice, &truncated).is_err());

    // The genuine message still decrypts: forgeries cannot break the session.
    assert_eq!(bob.receive(&alice, &m).unwrap(), "pay 10");
}

#[test]
fn a_message_from_the_wrong_sender_address_is_refused() {
    let (alice, bob) = connected();
    let carol = Device::new("6f0b6a1e-0000-4000-8000-00000000000c", 1);
    let first = alice.send(&bob, "for bob, from alice");
    assert_eq!(bob.receive(&alice, &first).unwrap(), "for bob, from alice");
    // An ordinary message relabelled as coming from Carol: Bob has no session
    // with Carol, and Alice's session keys are bound to Alice's address.
    let m = alice.send(&bob, "second");
    assert!(bob.receive(&carol, &m).is_err());
}

#[test]
fn a_one_time_prekey_handed_out_twice_works_only_once() {
    // A buggy or malicious server gives the same one-time prekey to two
    // senders. The first message that uses it destroys it, so the second
    // sender's session cannot be completed with it.
    let alice = Device::new(ALICE, 1);
    let carol = Device::new("6f0b6a1e-0000-4000-8000-00000000000c", 1);
    let mut bob = Device::new(BOB, 1);
    let bundle = bob.bundle();
    let reused = PreKeyBundleInput {
        registration_id: bundle.registration_id,
        device_number: bundle.device_number,
        identity_key: bundle.identity_key.clone(),
        signed_pre_key: clone_signed(&bundle.signed_pre_key),
        kyber_pre_key: clone_signed(bob.last_resort.as_ref().unwrap()),
        pre_key: bundle.pre_key.as_ref().map(|k| OneTimePreKeyPublic {
            key_id: k.key_id,
            public_key: k.public_key.clone(),
        }),
    };
    alice.crypto.start_session(BOB.into(), bundle).unwrap();
    carol.crypto.start_session(BOB.into(), reused).unwrap();
    assert_eq!(
        bob.receive(&alice, &alice.send(&bob, "first")).unwrap(),
        "first"
    );
    assert!(bob.receive(&carol, &carol.send(&bob, "second")).is_err());
}

#[test]
fn a_first_message_must_match_the_directory_identity() {
    // A server relabelling Alice's genuine first message as coming from
    // Carol's new device: the key inside is Alice's, the directory's is Carol's.
    let (alice, bob) = connected();
    let carol = Device::new("6f0b6a1e-0000-4000-8000-00000000000c", 1);
    let first = alice.send(&bob, "hello");

    let carols_key = carol.crypto.identity().unwrap().identity_key;
    let err = bob
        .receive_checked(&carol, &first, Some(carols_key))
        .unwrap_err();
    assert_eq!(err.kind, CryptoErrorKind::UntrustedIdentity);
    // Without any directory answer it is refused too.
    assert_eq!(
        bob.receive_checked(&alice, &first, None).unwrap_err().kind,
        CryptoErrorKind::UntrustedIdentity
    );
    // The genuine sender, with the directory's matching key, is accepted, and
    // after that the stored key is what counts.
    assert_eq!(bob.receive(&alice, &first).unwrap(), "hello");
    let m = alice.send(&bob, "again");
    assert_eq!(bob.receive_checked(&alice, &m, None).unwrap(), "again");
}

#[test]
fn a_forged_bundle_is_refused() {
    let alice = Device::new(ALICE, 1);
    let mut bob = Device::new(BOB, 1);
    let mallory = Device::new("6f0b6a1e-0000-4000-8000-0000000000ff", 1);

    // Bob's identity, but a signed prekey the server (or anyone) substituted.
    let mut bundle = bob.bundle();
    bundle.signed_pre_key = clone_signed(mallory.signed.as_ref().unwrap());
    assert!(alice.crypto.start_session(BOB.into(), bundle).is_err());

    // Same for the post-quantum key.
    let mut bundle = bob.bundle();
    bundle.kyber_pre_key = clone_signed(mallory.last_resort.as_ref().unwrap());
    assert!(alice.crypto.start_session(BOB.into(), bundle).is_err());

    assert!(!alice.crypto.has_session(BOB.into(), 1).unwrap());
}

#[test]
fn a_changed_identity_for_a_known_device_is_refused() {
    let (alice, bob) = connected();
    bob.receive(&alice, &alice.send(&bob, "hi")).unwrap();

    // Someone presents a different identity key for Bob's device 1: a server
    // swapping keys, or a cloned address. Skyline identities never change.
    let mut impostor = Device::new(BOB, 1);
    let err = alice
        .crypto
        .start_session(BOB.into(), impostor.bundle())
        .unwrap_err();
    assert_eq!(err.kind, CryptoErrorKind::UntrustedIdentity, "{err:?}");
    // The genuine session still works.
    let m = alice.send(&bob, "still you?");
    assert_eq!(bob.receive(&alice, &m).unwrap(), "still you?");
}

#[test]
fn the_last_resort_key_works_but_cannot_be_replayed() {
    let alice = Device::new(ALICE, 1);
    let mut bob = Device::new(BOB, 1);
    bob.one_time.clear();
    bob.kyber.clear();
    let bundle = bob.bundle();
    assert!(bundle.pre_key.is_none());
    assert_eq!(
        bundle.kyber_pre_key.key_id,
        bob.last_resort.as_ref().unwrap().key_id
    );
    alice.crypto.start_session(BOB.into(), bundle).unwrap();
    let first = alice.send(&bob, "via last resort");
    assert_eq!(bob.receive(&alice, &first).unwrap(), "via last resort");
    // The Kyber key is reused by design, so a replay must be caught by its
    // base key instead of by the key being gone.
    assert!(bob.receive(&alice, &first).is_err());
}

#[test]
fn a_second_device_is_a_separate_session() {
    let alice = Device::new(ALICE, 1);
    let mut bob_phone = Device::new(BOB, 1);
    let mut bob_pc = Device::new(BOB, 2);
    alice
        .crypto
        .start_session(BOB.into(), bob_phone.bundle())
        .unwrap();
    alice
        .crypto
        .start_session(BOB.into(), bob_pc.bundle())
        .unwrap();
    let to_phone = alice.send(&bob_phone, "phone");
    let to_pc = alice.send(&bob_pc, "pc");
    assert_eq!(bob_phone.receive(&alice, &to_phone).unwrap(), "phone");
    assert_eq!(bob_pc.receive(&alice, &to_pc).unwrap(), "pc");
    // One device cannot read what was encrypted for the other.
    assert!(bob_pc.receive(&alice, &to_phone).is_err());
}

#[test]
fn safety_numbers_match_on_both_sides_and_are_per_device() {
    let alice = Device::new(ALICE, 1);
    let bob = Device::new(BOB, 1);
    let bob_pc = Device::new(BOB, 2);
    let a = alice.crypto.identity().unwrap().identity_key;
    let b = bob.crypto.identity().unwrap().identity_key;
    let b2 = bob_pc.crypto.identity().unwrap().identity_key;

    let seen_by_alice = alice
        .crypto
        .safety_number(BOB.into(), 1, b.clone())
        .unwrap();
    let seen_by_bob = bob
        .crypto
        .safety_number(ALICE.into(), 1, a.clone())
        .unwrap();
    assert_eq!(seen_by_alice.displayable, seen_by_bob.displayable);
    assert_eq!(seen_by_alice.displayable.len(), 60);
    assert!(
        seen_by_alice
            .displayable
            .chars()
            .all(|c| c.is_ascii_digit())
    );

    let for_pc = alice.crypto.safety_number(BOB.into(), 2, b2).unwrap();
    assert_ne!(for_pc.displayable, seen_by_alice.displayable);
}

#[test]
fn the_device_credential_signs_verifiably() {
    let d = Device::new(ALICE, 1);
    let id = d.crypto.identity().unwrap();
    let msg = b"skyline-refresh:v1:1700000000:token".to_vec();
    let sig = d.crypto.sign(msg.clone()).unwrap();
    let vk = VerifyingKey::from_bytes(&id.signing_key.try_into().unwrap()).unwrap();
    vk.verify(&msg, &Signature::from_slice(&sig).unwrap())
        .unwrap();
    assert_eq!(id.identity_key.len(), 33);
    assert_eq!(id.identity_key[0], 0x05);
    assert!((1..=16380).contains(&id.registration_id));
}

#[test]
fn nothing_can_be_sent_before_the_device_knows_its_own_address() {
    let crypto = SkylineCrypto::open_in_memory().unwrap();
    let err = crypto.encrypt(BOB.into(), 1, b"x".to_vec()).unwrap_err();
    assert_eq!(err.kind, CryptoErrorKind::NoLocalAddress);
    crypto.set_local_address(ALICE.into(), 3).unwrap();
    crypto.set_local_address(ALICE.into(), 3).unwrap(); // same again is fine
    assert!(
        crypto.set_local_address(ALICE.into(), 4).is_err(),
        "never re-addressed"
    );
}

#[test]
fn key_batches_are_bounded_and_ids_are_24_bit() {
    let d = Device::new(ALICE, 1);
    assert!(d.crypto.new_one_time_pre_keys(0).is_err());
    assert!(d.crypto.new_one_time_pre_keys(101).is_err());
    let keys = d.crypto.new_one_time_pre_keys(100).unwrap();
    let ids: std::collections::HashSet<u32> = keys.iter().map(|k| k.key_id).collect();
    assert_eq!(ids.len(), 100);
    assert!(ids.iter().all(|&id| (1..=0xFF_FFFF).contains(&id)));
    for k in d.crypto.new_kyber_pre_keys(2).unwrap() {
        assert_eq!(k.public_key.len(), 1569, "Kyber1024 public key");
        assert_eq!(k.signature.len(), 64);
    }
}

#[test]
fn the_vault_on_disk_is_encrypted_and_needs_its_key() {
    let dir = std::env::temp_dir().join(format!("skyline-vault-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("vault.db").to_string_lossy().to_string();
    let key = vec![7u8; 32];

    let identity = {
        let alice = SkylineCrypto::open(path.clone(), key.clone()).unwrap();
        alice.set_local_address(ALICE.into(), 1).unwrap();
        let mut bob = Device::new(BOB, 1);
        alice.start_session(BOB.into(), bob.bundle()).unwrap();

        // Nothing readable: not the contact's id, not a public key, not the
        // literal namespace names.
        let raw = alice.raw_vault_for_tests().concat();
        assert!(!contains(&raw, BOB.as_bytes()));
        assert!(!contains(&raw, b"session"));
        let id = alice.identity().unwrap();
        assert!(!contains(&raw, &id.identity_key[1..]));
        id.identity_key
    };

    // Reopening with the right key restores the same identity and session.
    let again = SkylineCrypto::open(path.clone(), key.clone()).unwrap();
    assert_eq!(again.identity().unwrap().identity_key, identity);
    assert!(again.has_session(BOB.into(), 1).unwrap());
    drop(again);

    // The wrong key opens nothing.
    let wrong = SkylineCrypto::open(path.clone(), vec![8u8; 32]);
    assert_eq!(
        wrong.err().map(|e| e.kind),
        Some(CryptoErrorKind::VaultLocked)
    );
    assert!(SkylineCrypto::open(path, vec![7u8; 31]).is_err());
    let _ = std::fs::remove_dir_all(dir);
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn records_are_sealed_ordered_and_deletable() {
    let d = Device::new(ALICE, 1);
    let chat = "chat-with-bob";
    for (i, text) in ["first", "second", "third"].iter().enumerate() {
        d.crypto
            .put_record(
                "message".into(),
                format!("message-id-{i:04}"),
                chat.into(),
                1000 + i as i64,
                format!("{{\"text\":\"{text}\"}}").into_bytes(),
            )
            .unwrap();
    }
    d.crypto
        .put_record(
            "message".into(),
            "other".into(),
            "chat-with-carol".into(),
            5,
            b"x".to_vec(),
        )
        .unwrap();

    let page = d
        .crypto
        .list_records("message".into(), chat.into(), None, 2)
        .unwrap();
    let texts: Vec<String> = page
        .iter()
        .map(|r| String::from_utf8(r.value.clone()).unwrap())
        .collect();
    assert_eq!(texts, vec!["{\"text\":\"third\"}", "{\"text\":\"second\"}"]);
    let older = d
        .crypto
        .list_records("message".into(), chat.into(), Some(page[1].sort), 10)
        .unwrap();
    assert_eq!(older.len(), 1);

    // Nothing readable in the file: not the text, not the chat or message ids.
    let raw = d.crypto.raw_vault_for_tests().concat();
    for needle in ["third", "chat-with-bob", "message-id-0002"] {
        assert!(
            !contains(&raw, needle.as_bytes()),
            "{needle} visible on disk"
        );
    }

    assert!(
        d.crypto
            .delete_record("message".into(), "message-id-0002".into())
            .unwrap()
    );
    assert!(
        d.crypto
            .get_record("message".into(), "message-id-0002".into())
            .unwrap()
            .is_none()
    );
    assert_eq!(
        d.crypto
            .delete_record_group("message".into(), chat.into())
            .unwrap(),
        2
    );
    assert_eq!(
        d.crypto
            .list_records("message".into(), "chat-with-carol".into(), None, 10)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn app_lock_pin_checks_and_backs_off() {
    let d = Device::new(ALICE, 1);
    assert!(!d.crypto.has_app_lock_pin().unwrap());
    assert!(d.crypto.set_app_lock_pin("12345".into()).is_err());
    assert!(d.crypto.set_app_lock_pin("12345a".into()).is_err());
    d.crypto.set_app_lock_pin("482915".into()).unwrap();
    assert!(d.crypto.has_app_lock_pin().unwrap());

    assert!(d.crypto.check_app_lock_pin("482915".into()).unwrap().ok);
    for i in 1..=4 {
        let c = d.crypto.check_app_lock_pin("000000".into()).unwrap();
        assert!(!c.ok);
        assert_eq!(c.wait_seconds, 0, "attempt {i} waits no time");
    }
    let fifth = d.crypto.check_app_lock_pin("000000".into()).unwrap();
    assert_eq!(fifth.wait_seconds, 30);
    // While waiting, even the right PIN is not accepted.
    let blocked = d.crypto.check_app_lock_pin("482915".into()).unwrap();
    assert!(!blocked.ok && blocked.wait_seconds > 0);

    // The PIN is not stored in the clear anywhere in the vault.
    assert!(!contains(
        &d.crypto.raw_vault_for_tests().concat(),
        b"482915"
    ));

    d.crypto.clear_app_lock_pin().unwrap();
    assert!(!d.crypto.has_app_lock_pin().unwrap());
}
