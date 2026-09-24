//! Phase 7 end-to-end check, for development only.
//!
//! Two devices, each a real `SkylineCrypto` (real libsignal keys in an
//! encrypted in-memory vault), use a RUNNING backend exactly as the app will:
//! activate with an admin-issued code, publish prekeys, fetch the other's
//! bundle through the graph-checked key directory, start a PQXDH session and
//! exchange Double Ratchet messages. Message transport is Phase 8, so the
//! ciphertext is handed across here, in memory.
//!
//!   skyline-e2e <base-url> <alice-user-id> <alice-code> <bob-user-id> <bob-code>
//!
//! Codes must be given in canonical form (20 characters, no dashes).
//! Prints one JSON line on success; exits non-zero with a reason otherwise.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::{Value, json};
use skyline_crypto_core::*;

type Res<T> = Result<T, String>;

struct Device {
    crypto: SkylineCrypto,
    user_id: String,
    device_number: u32,
    token: String,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 6 {
        eprintln!("usage: skyline-e2e <base-url> <alice-id> <alice-code> <bob-id> <bob-code>");
        std::process::exit(2);
    }
    match run(&args[1], &args[2], &args[3], &args[4], &args[5]) {
        Ok(summary) => println!("{summary}"),
        Err(e) => {
            eprintln!("e2e failed: {e}");
            std::process::exit(1);
        }
    }
}

fn run(base: &str, alice_id: &str, alice_code: &str, bob_id: &str, bob_code: &str) -> Res<Value> {
    let alice = activate(base, alice_id, alice_code, "Alice's test PC")?;
    let bob = activate(base, bob_id, bob_code, "Bob's test PC")?;
    publish(base, &alice)?;
    let published = publish(base, &bob)?;

    // Alice fetches Bob's bundles from the key directory and starts a session
    // with every device offered.
    let bundles = get(base, &format!("/users/{bob_id}/keys"), &alice.token)?;
    let devices = bundles["devices"].as_array().ok_or("no devices array")?;
    if devices.len() != 1 {
        return Err(format!("expected 1 bundle for Bob, got {}", devices.len()));
    }
    let bundle = to_bundle(&devices[0])?;
    let bob_identity_from_server = bundle.identity_key.clone();
    alice
        .crypto
        .start_session(bob.user_id.clone(), bundle)
        .map_err(err)?;

    let secret = "Meet at the usual place at 7.";
    let first = alice
        .crypto
        .encrypt(
            bob.user_id.clone(),
            bob.device_number,
            secret.as_bytes().to_vec(),
        )
        .map_err(err)?;
    if first.kind != EnvelopeKind::PreKey {
        return Err("first message was not a session-starting message".into());
    }
    if first
        .body
        .windows(secret.len())
        .any(|w| w == secret.as_bytes())
    {
        return Err("plaintext visible in ciphertext".into());
    }
    // Bob checks Alice's first message against the key directory's answer
    // for her device (the Phase 8 sender-identity check).
    let listed = get(base, &format!("/users/{alice_id}/devices"), &bob.token)?;
    let alice_listed = listed
        .as_array()
        .and_then(|a| {
            a.iter()
                .find(|d| d["deviceNumber"].as_u64() == Some(alice.device_number as u64))
        })
        .and_then(|d| d["identityKey"].as_str())
        .ok_or("the directory does not list Alice's device")?;
    let alice_listed = B64.decode(alice_listed).map_err(|e| e.to_string())?;
    let read = bob
        .crypto
        .decrypt(
            alice.user_id.clone(),
            alice.device_number,
            first,
            Some(alice_listed),
        )
        .map_err(err)?;
    if read != secret.as_bytes() {
        return Err("Bob read something else".into());
    }

    let reply = bob
        .crypto
        .encrypt(
            alice.user_id.clone(),
            alice.device_number,
            b"See you there.".to_vec(),
        )
        .map_err(err)?;
    let reply_read = alice
        .crypto
        .decrypt(bob.user_id.clone(), bob.device_number, reply, None)
        .map_err(err)?;
    if reply_read != b"See you there." {
        return Err("Alice read something else".into());
    }

    // The one-time keys Alice's fetch claimed are gone from the directory.
    let after = get(base, "/me/keys", &bob.token)?;
    let claimed = published["oneTimePreKeys"].as_i64().unwrap_or(-1)
        - after["oneTimePreKeys"].as_i64().unwrap_or(-1);

    // Both sides compute the same safety number from what each holds.
    let alice_sees = alice
        .crypto
        .safety_number(
            bob.user_id.clone(),
            bob.device_number,
            bob_identity_from_server,
        )
        .map_err(err)?;
    let bob_sees = bob
        .crypto
        .safety_number(
            alice.user_id.clone(),
            alice.device_number,
            alice.crypto.identity().map_err(err)?.identity_key,
        )
        .map_err(err)?;
    if alice_sees.displayable != bob_sees.displayable {
        return Err("safety numbers differ".into());
    }

    Ok(json!({
        "ok": true,
        "alice": { "userId": alice.user_id, "deviceNumber": alice.device_number,
                   "identityKey": B64.encode(alice.crypto.identity().map_err(err)?.identity_key) },
        "bob": { "userId": bob.user_id, "deviceNumber": bob.device_number,
                 "identityKey": B64.encode(bob.crypto.identity().map_err(err)?.identity_key) },
        "oneTimeKeysClaimed": claimed,
        "safetyNumber": alice_sees.displayable,
    }))
}

fn activate(base: &str, user_id: &str, code: &str, name: &str) -> Res<Device> {
    let crypto = SkylineCrypto::open_in_memory().map_err(err)?;
    let id = crypto.identity().map_err(err)?;
    let identity_b64 = B64.encode(&id.identity_key);
    let message = format!(
        "skyline-activate:v2:{code}:{identity_b64}:{}",
        id.registration_id
    );
    let signature = crypto.sign(message.into_bytes()).map_err(err)?;
    let body = json!({
        "code": code,
        "deviceName": name,
        "platform": "windows",
        "signingKey": B64.encode(&id.signing_key),
        "identityKey": identity_b64,
        "registrationId": id.registration_id,
        "signature": B64.encode(signature),
    });
    let r = post(base, "/auth/activate", None, body)?;
    let got_user = r["userId"].as_str().ok_or("no userId")?;
    if got_user != user_id {
        return Err(format!("activated as {got_user}, expected {user_id}"));
    }
    let device_number = r["deviceNumber"].as_u64().ok_or("no deviceNumber")? as u32;
    crypto
        .set_local_address(user_id.to_string(), device_number)
        .map_err(err)?;
    Ok(Device {
        crypto,
        user_id: user_id.to_string(),
        device_number,
        token: r["accessToken"]
            .as_str()
            .ok_or("no accessToken")?
            .to_string(),
    })
}

fn publish(base: &str, d: &Device) -> Res<Value> {
    let signed = d.crypto.new_signed_pre_key().map_err(err)?;
    let last = d.crypto.new_last_resort_kyber_pre_key().map_err(err)?;
    let one_time = d.crypto.new_one_time_pre_keys(10).map_err(err)?;
    let kyber = d.crypto.new_kyber_pre_keys(10).map_err(err)?;
    let signed_json = |k: &SignedPreKeyPublic| json!({ "keyId": k.key_id, "publicKey": B64.encode(&k.public_key), "signature": B64.encode(&k.signature) });
    let body = json!({
        "signedPreKey": signed_json(&signed),
        "lastResortKyberPreKey": signed_json(&last),
        "oneTimePreKeys": one_time.iter().map(|k| json!({ "keyId": k.key_id, "publicKey": B64.encode(&k.public_key) })).collect::<Vec<_>>(),
        "kyberPreKeys": kyber.iter().map(signed_json).collect::<Vec<_>>(),
    });
    put(base, "/me/keys", &d.token, body)
}

fn to_bundle(v: &Value) -> Res<PreKeyBundleInput> {
    let bytes = |x: &Value| -> Res<Vec<u8>> {
        B64.decode(x.as_str().ok_or("expected base64 string")?)
            .map_err(|e| e.to_string())
    };
    let num = |x: &Value| -> Res<u32> { Ok(x.as_u64().ok_or("expected number")? as u32) };
    let signed = |x: &Value| -> Res<SignedPreKeyPublic> {
        Ok(SignedPreKeyPublic {
            key_id: num(&x["keyId"])?,
            public_key: bytes(&x["publicKey"])?,
            signature: bytes(&x["signature"])?,
        })
    };
    Ok(PreKeyBundleInput {
        registration_id: num(&v["registrationId"])?,
        device_number: num(&v["deviceNumber"])?,
        identity_key: bytes(&v["identityKey"])?,
        signed_pre_key: signed(&v["signedPreKey"])?,
        kyber_pre_key: signed(&v["kyberPreKey"])?,
        pre_key: match &v["preKey"] {
            Value::Null => None,
            k => Some(OneTimePreKeyPublic {
                key_id: num(&k["keyId"])?,
                public_key: bytes(&k["publicKey"])?,
            }),
        },
    })
}

fn err(e: CryptoError) -> String {
    e.to_string()
}

fn call(req: ureq::Request, body: Option<Value>) -> Res<Value> {
    let result = match body {
        Some(b) => req.send_json(b),
        None => req.call(),
    };
    match result {
        Ok(r) => r.into_json::<Value>().map_err(|e| e.to_string()),
        Err(ureq::Error::Status(code, r)) => Err(format!(
            "HTTP {code}: {}",
            r.into_string().unwrap_or_default()
        )),
        Err(e) => Err(e.to_string()),
    }
}

fn post(base: &str, path: &str, token: Option<&str>, body: Value) -> Res<Value> {
    let mut req = ureq::post(&format!("{base}{path}"));
    if let Some(t) = token {
        req = req.set("Authorization", &format!("Bearer {t}"));
    }
    call(req, Some(body))
}

fn put(base: &str, path: &str, token: &str, body: Value) -> Res<Value> {
    call(
        ureq::put(&format!("{base}{path}")).set("Authorization", &format!("Bearer {token}")),
        Some(body),
    )
}

fn get(base: &str, path: &str, token: &str) -> Res<Value> {
    call(
        ureq::get(&format!("{base}{path}")).set("Authorization", &format!("Bearer {token}")),
        None,
    )
}
