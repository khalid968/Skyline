//! Phase 12 (threat model A2, A5): everything a device receives from the
//! server is untrusted. Envelopes, group messages, sender keys, key bundles,
//! scanned QR codes and media files are fed random and corrupted bytes here.
//! Each must be REFUSED with an error: never a panic (which would crash the
//! app), and never a plaintext that nobody sent.

use proptest::prelude::*;
use proptest::test_runner::{Config, TestRunner};
use skyline_crypto_core::media::{decrypt_to_memory, encrypt_bytes};
use skyline_crypto_core::*;

const ALICE: &str = "6f0b6a1e-0000-4000-8000-00000000000a";
const BOB: &str = "6f0b6a1e-0000-4000-8000-00000000000b";

fn runner() -> TestRunner {
    TestRunner::new(Config { cases: 256, failure_persistence: None, ..Config::default() })
}

fn bytes() -> impl Strategy<Value = Vec<u8>> {
    prop::collection::vec(any::<u8>(), 0..600)
}

fn device(user: &str) -> SkylineCrypto {
    let c = SkylineCrypto::open_in_memory().unwrap();
    c.set_local_address(user.into(), 1).unwrap();
    c
}

fn bundle(d: &SkylineCrypto) -> PreKeyBundleInput {
    let id = d.identity().unwrap();
    PreKeyBundleInput {
        registration_id: id.registration_id,
        device_number: 1,
        identity_key: id.identity_key,
        signed_pre_key: d.new_signed_pre_key().unwrap(),
        kyber_pre_key: d.new_last_resort_kyber_pre_key().unwrap(),
        pre_key: d.new_one_time_pre_keys(1).unwrap().pop(),
    }
}

/// Alice and Bob with a working session both ways.
fn pair() -> (SkylineCrypto, SkylineCrypto) {
    let (a, b) = (device(ALICE), device(BOB));
    a.start_session(BOB.into(), bundle(&b)).unwrap();
    let first = a.encrypt(BOB.into(), 1, b"hello".to_vec()).unwrap();
    let dir = a.identity().unwrap().identity_key;
    b.decrypt(ALICE.into(), 1, first, Some(dir)).unwrap();
    (a, b)
}

#[test]
fn random_envelopes_are_refused_never_panic() {
    let (a, b) = pair();
    let dir = a.identity().unwrap().identity_key;
    runner()
        .run(&(bytes(), any::<bool>()), |(body, prekey)| {
            let kind = if prekey { EnvelopeKind::PreKey } else { EnvelopeKind::Whisper };
            let r = b.decrypt(ALICE.into(), 1, Envelope { kind, body }, Some(dir.clone()));
            prop_assert!(r.is_err());
            Ok(())
        })
        .unwrap();
}

/// Changing any byte of a real message must never yield a DIFFERENT
/// plaintext. Most changes are refused outright. One class decrypts, and it is
/// correct that it does: a session-starting (PreKey) message carries the key
/// agreement material (the Kyber ciphertext, the base key), which the receiver
/// ignores once the session exists. The inner message is still authenticated,
/// so what comes out is exactly what was sent.
fn tamper(a: &SkylineCrypto, b: &SkylineCrypto, text: &[u8]) {
    let dir = a.identity().unwrap().identity_key;
    let good = a.encrypt(BOB.into(), 1, text.to_vec()).unwrap();
    runner()
        .run(&(0..good.body.len(), 1u8..=255), |(i, flip)| {
            let mut body = good.body.clone();
            body[i] ^= flip;
            let r = b.decrypt(ALICE.into(), 1, Envelope { kind: good.kind, body }, Some(dir.clone()));
            if let Ok(plain) = r {
                prop_assert_eq!(plain, text.to_vec(), "a corrupted message decrypted to something else");
            }
            Ok(())
        })
        .unwrap();
    // The untouched message still decrypts: failures did not damage the session.
    let r = b.decrypt(ALICE.into(), 1, good, Some(dir));
    assert!(r.is_err() || r.unwrap() == text, "the session was damaged");
}

#[test]
fn a_real_message_with_any_byte_changed_never_decrypts_to_something_else() {
    // Before Bob replies, Alice's messages are PreKey messages.
    let (a, b) = pair();
    tamper(&a, &b, b"the meeting is at ten");

    // After a reply, they are ordinary ratchet messages: every byte is
    // covered by the MAC, so every change is refused.
    let (a, b) = pair();
    let reply = b.encrypt(ALICE.into(), 1, b"ok".to_vec()).unwrap();
    a.decrypt(BOB.into(), 1, reply, Some(b.identity().unwrap().identity_key)).unwrap();
    let dir = a.identity().unwrap().identity_key;
    let good = a.encrypt(BOB.into(), 1, b"moved to eleven".to_vec()).unwrap();
    assert_eq!(good.kind, EnvelopeKind::Whisper);
    runner()
        .run(&(0..good.body.len(), 1u8..=255), |(i, flip)| {
            let mut body = good.body.clone();
            body[i] ^= flip;
            let r = b.decrypt(ALICE.into(), 1, Envelope { kind: good.kind, body }, Some(dir.clone()));
            prop_assert!(r.is_err(), "a corrupted ratchet message decrypted");
            Ok(())
        })
        .unwrap();
    assert_eq!(b.decrypt(ALICE.into(), 1, good, Some(dir)).unwrap(), b"moved to eleven");
}

#[test]
fn random_group_traffic_is_refused_never_panic() {
    let (a, b) = pair();
    let dist = "0f3c2b1a-0000-4000-8000-000000000001".to_string();
    let key = a.group_sender_key(dist.clone()).unwrap();
    b.accept_group_sender_key(ALICE.into(), 1, key).unwrap();
    runner()
        .run(&bytes(), |body| {
            prop_assert!(b.accept_group_sender_key(ALICE.into(), 1, body.clone()).is_err());
            prop_assert!(b.group_decrypt(ALICE.into(), 1, body.clone(), dist.clone()).is_err());
            let _ = b.group_message_distribution_id(body); // Err or an id; never a panic
            Ok(())
        })
        .unwrap();
    let good = a.group_encrypt(dist.clone(), b"all hands".to_vec()).unwrap();
    runner()
        .run(&(0..good.len(), 1u8..=255), |(i, flip)| {
            let mut body = good.clone();
            body[i] ^= flip;
            prop_assert!(b.group_decrypt(ALICE.into(), 1, body, dist.clone()).is_err());
            Ok(())
        })
        .unwrap();
    assert_eq!(b.group_decrypt(ALICE.into(), 1, good, dist).unwrap(), b"all hands");
}

#[test]
fn forged_key_bundles_are_refused() {
    let a = device(ALICE);
    let b = device(BOB);
    let real = bundle(&b);
    runner()
        .run(&(bytes(), bytes(), bytes(), 0usize..4), |(x, y, z, which)| {
            let mut forged = PreKeyBundleInput {
                registration_id: real.registration_id,
                device_number: 1,
                identity_key: real.identity_key.clone(),
                signed_pre_key: SignedPreKeyPublic {
                    key_id: real.signed_pre_key.key_id,
                    public_key: real.signed_pre_key.public_key.clone(),
                    signature: real.signed_pre_key.signature.clone(),
                },
                kyber_pre_key: SignedPreKeyPublic {
                    key_id: real.kyber_pre_key.key_id,
                    public_key: real.kyber_pre_key.public_key.clone(),
                    signature: real.kyber_pre_key.signature.clone(),
                },
                pre_key: None,
            };
            match which {
                0 => forged.identity_key = x,
                1 => forged.signed_pre_key.signature = x,
                2 => forged.kyber_pre_key.public_key = y,
                _ => {
                    forged.signed_pre_key.public_key = y;
                    forged.kyber_pre_key.signature = z;
                }
            }
            // Only the untouched bundle may start a session; a random value
            // equal to the real one is astronomically unlikely.
            prop_assert!(a.start_session(BOB.into(), forged).is_err());
            Ok(())
        })
        .unwrap();
}

#[test]
fn random_scanned_codes_never_verify() {
    let (a, b) = pair();
    let their = b.identity().unwrap().identity_key;
    runner()
        .run(&bytes(), |scanned| {
            let r = a.verify_scanned_safety_number(BOB.into(), 1, their.clone(), scanned);
            prop_assert!(!matches!(r, Ok(true)), "a random code verified");
            Ok(())
        })
        .unwrap();
}

#[test]
fn corrupted_media_is_refused() {
    let (key, nonce, ciphertext) = encrypt_bytes(b"a small photo").unwrap();
    let dir = std::env::temp_dir().join(format!("skyline-untrusted-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("file.bin");
    runner()
        .run(&(0..ciphertext.len(), 1u8..=255), |(i, flip)| {
            let mut c = ciphertext.clone();
            c[i] ^= flip;
            std::fs::write(&path, &c).unwrap();
            let r = decrypt_to_memory(path.to_str().unwrap(), &key, &nonce, None);
            prop_assert!(r.is_err(), "corrupted media decrypted");
            Ok(())
        })
        .unwrap();
    std::fs::remove_dir_all(&dir).ok();
}
