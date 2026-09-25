//! Media files (photos, videos, voice, documents), up to 2 GB.
//!
//! Each file gets a fresh random 32-byte key and 12-byte nonce and is
//! encrypted with libsignal's own streaming AES-256-GCM (`signal-crypto`), so a
//! 2 GB video never has to fit in memory. The 16-byte tag is appended to the
//! ciphertext. The key and nonce travel only inside the (Signal-encrypted)
//! message; the server stores an opaque blob and its SHA-256.
//!
//! Decryption streams to a TEMPORARY file and renames it into place only after
//! the tag verifies, so a tampered or truncated download never becomes a
//! usable file. No cryptography is implemented here.

use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Read, Write};

use rand::TryRngCore as _;
use rand::rngs::OsRng;
use sha2::{Digest, Sha256};
use signal_crypto::{Aes256GcmDecryption, Aes256GcmEncryption};
use zeroize::Zeroizing;

use crate::error::CryptoError;

const CHUNK: usize = 1 << 20; // 1 MiB of plaintext at a time
const TAG: usize = 16;
/// The owner's limit (decisions.md 2026-09-25).
pub const MAX_MEDIA_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// What the recipient needs to fetch and open one encrypted file.
pub struct MediaKeys {
    pub key: Vec<u8>,
    pub nonce: Vec<u8>,
    /// SHA-256 of the whole ciphertext file (tag included), as uploaded.
    pub ciphertext_sha256: Vec<u8>,
    pub ciphertext_size: u64,
    pub plaintext_size: u64,
}

fn io(e: std::io::Error) -> CryptoError {
    CryptoError::storage(format!("file: {e}"))
}

/// Encrypts `input` into `output` (created or truncated).
pub fn encrypt_file(input: &str, output: &str) -> Result<MediaKeys, CryptoError> {
    let size = fs::metadata(input).map_err(io)?.len();
    if size == 0 {
        return Err(CryptoError::invalid("the file is empty"));
    }
    if size > MAX_MEDIA_BYTES {
        return Err(CryptoError::invalid("the file is larger than 2 GB"));
    }
    let mut key = Zeroizing::new(vec![0u8; 32]);
    let mut nonce = vec![0u8; 12];
    OsRng
        .try_fill_bytes(&mut key)
        .and_then(|_| OsRng.try_fill_bytes(&mut nonce))
        .map_err(|_| CryptoError::storage("no randomness"))?;

    let mut gcm = Aes256GcmEncryption::new(&key, &nonce, &[])
        .map_err(|e| CryptoError::protocol(e.to_string()))?;
    let mut reader = BufReader::new(File::open(input).map_err(io)?);
    let mut writer = BufWriter::new(File::create(output).map_err(io)?);
    let mut hash = Sha256::new();
    let mut buf = vec![0u8; CHUNK];
    let mut total = 0u64;
    loop {
        let n = read_full(&mut reader, &mut buf)?;
        if n == 0 {
            break;
        }
        gcm.encrypt(&mut buf[..n]);
        hash.update(&buf[..n]);
        writer.write_all(&buf[..n]).map_err(io)?;
        total += n as u64;
    }
    let tag = gcm.compute_tag();
    hash.update(tag);
    writer.write_all(&tag).map_err(io)?;
    writer.flush().map_err(io)?;
    Ok(MediaKeys {
        key: key.to_vec(),
        nonce,
        ciphertext_sha256: hash.finalize().to_vec(),
        ciphertext_size: total + TAG as u64,
        plaintext_size: total,
    })
}

/// Decrypts `input` (a downloaded ciphertext) into `output`. Checks the
/// SHA-256 first when given, then the GCM tag; `output` appears only if both
/// pass.
pub fn decrypt_file(
    input: &str,
    output: &str,
    key: &[u8],
    nonce: &[u8],
    expected_sha256: Option<&[u8]>,
) -> Result<(), CryptoError> {
    let size = fs::metadata(input).map_err(io)?.len();
    if size < TAG as u64 + 1 {
        return Err(CryptoError::protocol("the file is damaged"));
    }
    let body_len = size - TAG as u64;
    let mut gcm = Aes256GcmDecryption::new(key, nonce, &[])
        .map_err(|e| CryptoError::protocol(e.to_string()))?;
    let tmp = format!("{output}.part");
    let result = (|| {
        let mut reader = BufReader::new(File::open(input).map_err(io)?);
        let mut writer = BufWriter::new(File::create(&tmp).map_err(io)?);
        let mut hash = Sha256::new();
        let mut buf = vec![0u8; CHUNK];
        let mut left = body_len;
        while left > 0 {
            let want = CHUNK.min(left as usize);
            let n = read_full(&mut reader, &mut buf[..want])?;
            if n != want {
                return Err(CryptoError::protocol("the file is damaged"));
            }
            hash.update(&buf[..n]);
            gcm.decrypt(&mut buf[..n]);
            writer.write_all(&buf[..n]).map_err(io)?;
            left -= n as u64;
        }
        let mut tag = [0u8; TAG];
        if read_full(&mut reader, &mut tag)? != TAG {
            return Err(CryptoError::protocol("the file is damaged"));
        }
        hash.update(tag);
        if let Some(want) = expected_sha256
            && hash.finalize().as_slice() != want
        {
            return Err(CryptoError::protocol(
                "the file does not match what was sent",
            ));
        }
        gcm.verify_tag(&tag)
            .map_err(|_| CryptoError::protocol("the file was tampered with"))?;
        writer.flush().map_err(io)?;
        Ok(())
    })();
    match result {
        Ok(()) => fs::rename(&tmp, output).map_err(io),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// Decrypts a small file (a photo, a voice message) straight into memory for
/// display; nothing touches the disk. Refuses anything over 64 MB.
pub fn decrypt_to_memory(
    input: &str,
    key: &[u8],
    nonce: &[u8],
    expected_sha256: Option<&[u8]>,
) -> Result<Vec<u8>, CryptoError> {
    let mut data = fs::read(input).map_err(io)?;
    if data.len() > 64 * 1024 * 1024 {
        return Err(CryptoError::invalid("too large to open in memory"));
    }
    if data.len() < TAG + 1 {
        return Err(CryptoError::protocol("the file is damaged"));
    }
    if let Some(want) = expected_sha256
        && Sha256::digest(&data).as_slice() != want
    {
        return Err(CryptoError::protocol(
            "the file does not match what was sent",
        ));
    }
    let tag: [u8; TAG] = data[data.len() - TAG..].try_into().unwrap();
    data.truncate(data.len() - TAG);
    let mut gcm = Aes256GcmDecryption::new(key, nonce, &[])
        .map_err(|e| CryptoError::protocol(e.to_string()))?;
    gcm.decrypt(&mut data);
    gcm.verify_tag(&tag)
        .map_err(|_| CryptoError::protocol("the file was tampered with"))?;
    Ok(data)
}

/// (key, nonce, ciphertext-with-tag).
pub type Sealed = (Vec<u8>, Vec<u8>, Vec<u8>);

/// Encrypts a small in-memory buffer (a thumbnail) the same way.
pub fn encrypt_bytes(plain: &[u8]) -> Result<Sealed, CryptoError> {
    let mut key = vec![0u8; 32];
    let mut nonce = vec![0u8; 12];
    OsRng
        .try_fill_bytes(&mut key)
        .and_then(|_| OsRng.try_fill_bytes(&mut nonce))
        .map_err(|_| CryptoError::storage("no randomness"))?;
    let mut buf = plain.to_vec();
    let mut gcm = Aes256GcmEncryption::new(&key, &nonce, &[])
        .map_err(|e| CryptoError::protocol(e.to_string()))?;
    gcm.encrypt(&mut buf);
    buf.extend_from_slice(&gcm.compute_tag());
    Ok((key, nonce, buf))
}

fn read_full(r: &mut impl Read, buf: &mut [u8]) -> Result<usize, CryptoError> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = r.read(&mut buf[filled..]).map_err(io)?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
}
