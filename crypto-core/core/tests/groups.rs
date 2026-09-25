//! Groups (Phase 8b) with real libsignal Sender Keys: three devices, each with
//! its own encrypted vault, and only the bytes a server would carry between
//! them.

use skyline_crypto_core::*;

const ALICE: &str = "6f0b6a1e-0000-4000-8000-0000000000a1";
const BOB: &str = "6f0b6a1e-0000-4000-8000-0000000000b2";
const CAROL: &str = "6f0b6a1e-0000-4000-8000-0000000000c3";
const EPOCH_1: &str = "0b5c1d8e-1111-4000-8000-000000000001";
const EPOCH_2: &str = "0b5c1d8e-2222-4000-8000-000000000002";
const OTHER_GROUP: &str = "0b5c1d8e-3333-4000-8000-000000000003";

fn device(user: &str) -> SkylineCrypto {
    let c = SkylineCrypto::open_in_memory().unwrap();
    c.set_local_address(user.into(), 1).unwrap();
    c
}

/// Alice hands her sender key for `epoch` to each of `to`, as the app does over
/// the pairwise sessions.
fn share(alice: &SkylineCrypto, epoch: &str, to: &[&SkylineCrypto]) {
    let skdm = alice.group_sender_key(epoch.into()).unwrap();
    for d in to {
        assert_eq!(
            d.accept_group_sender_key(ALICE.into(), 1, skdm.clone()).unwrap(),
            epoch
        );
    }
}

fn read(d: &SkylineCrypto, from: &str, body: &[u8], epoch: &str) -> Result<String, CryptoError> {
    d.group_decrypt(from.into(), 1, body.to_vec(), epoch.into())
        .map(|b| String::from_utf8(b).unwrap())
}

#[test]
fn one_ciphertext_every_member_reads() {
    let (alice, bob, carol) = (device(ALICE), device(BOB), device(CAROL));
    share(&alice, EPOCH_1, &[&bob, &carol]);
    for i in 0..10 {
        let text = format!("message {i} to the group");
        let body = alice.group_encrypt(EPOCH_1.into(), text.clone().into_bytes()).unwrap();
        assert!(!body.windows(9).any(|w| w == b"to the gr"), "no plaintext in the ciphertext");
        assert_eq!(alice.group_message_distribution_id(body.clone()).unwrap(), EPOCH_1);
        assert_eq!(read(&bob, ALICE, &body, EPOCH_1).unwrap(), text);
        assert_eq!(read(&carol, ALICE, &body, EPOCH_1).unwrap(), text);
    }
}

#[test]
fn messages_out_of_order_still_decrypt_and_a_replay_is_refused() {
    let (alice, bob) = (device(ALICE), device(BOB));
    share(&alice, EPOCH_1, &[&bob]);
    let m: Vec<Vec<u8>> = (0..5)
        .map(|i| alice.group_encrypt(EPOCH_1.into(), format!("m{i}").into_bytes()).unwrap())
        .collect();
    assert_eq!(read(&bob, ALICE, &m[3], EPOCH_1).unwrap(), "m3");
    assert_eq!(read(&bob, ALICE, &m[0], EPOCH_1).unwrap(), "m0");
    assert_eq!(read(&bob, ALICE, &m[4], EPOCH_1).unwrap(), "m4");
    assert!(read(&bob, ALICE, &m[4], EPOCH_1).is_err(), "the same message twice");
}

#[test]
fn a_message_credited_to_another_member_is_refused() {
    let (alice, bob, carol) = (device(ALICE), device(BOB), device(CAROL));
    share(&alice, EPOCH_1, &[&bob, &carol]);
    // Carol has a sender key of her own, handed to Bob as well.
    let carol_skdm = carol.group_sender_key(EPOCH_1.into()).unwrap();
    bob.accept_group_sender_key(CAROL.into(), 1, carol_skdm).unwrap();
    // A server (or Carol) presenting Carol's message as Alice's: refused.
    let by_carol = carol.group_encrypt(EPOCH_1.into(), b"I am Alice".to_vec()).unwrap();
    assert!(read(&bob, ALICE, &by_carol, EPOCH_1).is_err());
    assert_eq!(read(&bob, CAROL, &by_carol, EPOCH_1).unwrap(), "I am Alice");
}

#[test]
fn a_sender_key_from_one_group_cannot_post_into_another() {
    let (alice, bob) = (device(ALICE), device(BOB));
    share(&alice, OTHER_GROUP, &[&bob]);
    share(&alice, EPOCH_1, &[&bob]);
    let elsewhere = alice.group_encrypt(OTHER_GROUP.into(), b"meant for the other group".to_vec()).unwrap();
    let err = read(&bob, ALICE, &elsewhere, EPOCH_1).unwrap_err();
    assert!(err.to_string().contains("somewhere else"), "{err}");
}

#[test]
fn after_a_rotation_a_removed_member_reads_nothing_new() {
    let (alice, bob, carol) = (device(ALICE), device(BOB), device(CAROL));
    share(&alice, EPOCH_1, &[&bob, &carol]);
    let before = alice.group_encrypt(EPOCH_1.into(), b"before".to_vec()).unwrap();
    assert_eq!(read(&carol, ALICE, &before, EPOCH_1).unwrap(), "before");

    // Carol is removed: Alice starts a new epoch and shares it with Bob only.
    share(&alice, EPOCH_2, &[&bob]);
    let after = alice.group_encrypt(EPOCH_2.into(), b"after carol left".to_vec()).unwrap();
    assert_eq!(read(&bob, ALICE, &after, EPOCH_2).unwrap(), "after carol left");
    assert!(read(&carol, ALICE, &after, EPOCH_2).is_err(), "carol has no key for the new epoch");
    assert!(read(&carol, ALICE, &after, EPOCH_1).is_err(), "and her old key does not fit");
}

#[test]
fn a_tampered_group_message_is_refused_and_changes_nothing() {
    let (alice, bob) = (device(ALICE), device(BOB));
    share(&alice, EPOCH_1, &[&bob]);
    let body = alice.group_encrypt(EPOCH_1.into(), b"hello".to_vec()).unwrap();
    for i in [body.len() / 2, body.len() - 1] {
        let mut bad = body.clone();
        bad[i] ^= 0x01;
        assert!(read(&bob, ALICE, &bad, EPOCH_1).is_err(), "byte {i}");
    }
    assert_eq!(read(&bob, ALICE, &body, EPOCH_1).unwrap(), "hello");
}

#[test]
fn a_distribution_message_is_bound_to_the_address_it_is_filed_under() {
    // Carol's key filed as Alice's (what a forged pairwise sender would try):
    // messages from the real Alice then fail, and Carol's pass as "Alice" only
    // because the app filed them so. That is why the app files a distribution
    // message ONLY under the sender its pairwise envelope decrypted from.
    let (alice, bob, carol) = (device(ALICE), device(BOB), device(CAROL));
    let carol_skdm = carol.group_sender_key(EPOCH_1.into()).unwrap();
    bob.accept_group_sender_key(ALICE.into(), 1, carol_skdm).unwrap();
    let _ = alice.group_sender_key(EPOCH_1.into()).unwrap();
    let real = alice.group_encrypt(EPOCH_1.into(), b"real alice".to_vec()).unwrap();
    assert!(read(&bob, ALICE, &real, EPOCH_1).is_err());
}
