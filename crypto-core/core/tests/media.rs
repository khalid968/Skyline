//! Media file encryption: round trip, streaming sizes, tamper and truncation.

use skyline_crypto_core::media::*;
use std::fs;

fn tmp(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("skyline-media-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    dir.join(name).to_string_lossy().to_string()
}

fn sample(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i * 31 % 251) as u8).collect()
}

#[test]
fn round_trips_across_chunk_boundaries() {
    for len in [
        1usize,
        1000,
        (1 << 20) - 1,
        1 << 20,
        (1 << 20) + 1,
        3 * (1 << 20) + 17,
    ] {
        let (inp, enc, out) = (
            tmp(&format!("p{len}")),
            tmp(&format!("c{len}")),
            tmp(&format!("o{len}")),
        );
        let data = sample(len);
        fs::write(&inp, &data).unwrap();
        let k = encrypt_file(&inp, &enc).unwrap();
        assert_eq!(k.plaintext_size, len as u64);
        assert_eq!(k.ciphertext_size, len as u64 + 16);
        assert_eq!(fs::metadata(&enc).unwrap().len(), k.ciphertext_size);
        let ct = fs::read(&enc).unwrap();
        assert!(
            len < 64 || !ct.windows(64).any(|w| w == &data[..64]),
            "plaintext visible"
        );
        decrypt_file(&enc, &out, &k.key, &k.nonce, Some(&k.ciphertext_sha256)).unwrap();
        assert_eq!(fs::read(&out).unwrap(), data, "len {len}");
        assert_eq!(
            decrypt_to_memory(&enc, &k.key, &k.nonce, Some(&k.ciphertext_sha256)).unwrap(),
            data
        );
    }
}

#[test]
fn every_file_gets_its_own_key() {
    let inp = tmp("same");
    fs::write(&inp, sample(5000)).unwrap();
    let a = encrypt_file(&inp, &tmp("same-a")).unwrap();
    let b = encrypt_file(&inp, &tmp("same-b")).unwrap();
    assert_ne!(a.key, b.key);
    assert_ne!(a.ciphertext_sha256, b.ciphertext_sha256);
}

#[test]
fn tampering_truncation_and_wrong_keys_never_produce_a_file() {
    let (inp, enc, out) = (tmp("t-in"), tmp("t-enc"), tmp("t-out"));
    fs::write(&inp, sample(2 * (1 << 20) + 5)).unwrap();
    let k = encrypt_file(&inp, &enc).unwrap();
    let good = fs::read(&enc).unwrap();

    // A flipped byte in the middle, and in the tag.
    for pos in [good.len() / 2, good.len() - 3] {
        let mut bad = good.clone();
        bad[pos] ^= 1;
        fs::write(&enc, &bad).unwrap();
        assert!(
            decrypt_file(&enc, &out, &k.key, &k.nonce, None).is_err(),
            "pos {pos}"
        );
        assert!(
            !std::path::Path::new(&out).exists(),
            "no output from a tampered file"
        );
        assert!(decrypt_file(&enc, &out, &k.key, &k.nonce, Some(&k.ciphertext_sha256)).is_err());
    }
    // Truncated download.
    fs::write(&enc, &good[..good.len() - 100]).unwrap();
    assert!(decrypt_file(&enc, &out, &k.key, &k.nonce, None).is_err());
    assert!(!std::path::Path::new(&out).exists());
    // Wrong key.
    fs::write(&enc, &good).unwrap();
    let mut wrong = k.key.clone();
    wrong[0] ^= 1;
    assert!(decrypt_file(&enc, &out, &wrong, &k.nonce, None).is_err());
    assert!(decrypt_to_memory(&enc, &wrong, &k.nonce, None).is_err());
    // And the genuine one still works.
    decrypt_file(&enc, &out, &k.key, &k.nonce, Some(&k.ciphertext_sha256)).unwrap();
}

#[test]
fn empty_files_are_refused() {
    let inp = tmp("empty");
    fs::write(&inp, b"").unwrap();
    assert!(encrypt_file(&inp, &tmp("empty-out")).is_err());
}
