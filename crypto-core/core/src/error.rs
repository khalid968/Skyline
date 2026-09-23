use libsignal_protocol::SignalProtocolError;

/// What went wrong, as a plain enum so it crosses into Dart as a Dart enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CryptoErrorKind {
    /// The vault could not be opened with this storage key, or an entry was
    /// tampered with. The app must not continue with this vault.
    VaultLocked,
    Storage,
    InvalidInput,
    /// A contact's device presented a different identity key than the one on
    /// record. Skyline identities never change (a new key is a new device), so
    /// this is treated as an attack: nothing is sent or accepted.
    UntrustedIdentity,
    NoSession,
    /// The device has no Skyline address yet (it must be activated first).
    NoLocalAddress,
    /// libsignal refused: a bad signature, a tampered or replayed message, etc.
    Protocol,
}

/// Every failure the crypto core reports to the app. The message is for logs
/// and never contains key material or plaintext.
#[derive(Clone, Debug)]
pub struct CryptoError {
    pub kind: CryptoErrorKind,
    pub message: String,
}

impl CryptoError {
    pub(crate) fn new(kind: CryptoErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
    pub(crate) fn storage(message: impl Into<String>) -> Self {
        Self::new(CryptoErrorKind::Storage, message)
    }
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::new(CryptoErrorKind::InvalidInput, message)
    }
    pub(crate) fn protocol(message: impl Into<String>) -> Self {
        Self::new(CryptoErrorKind::Protocol, message)
    }
    pub(crate) fn locked() -> Self {
        Self::new(
            CryptoErrorKind::VaultLocked,
            "the key vault could not be unlocked",
        )
    }
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}

impl std::error::Error for CryptoError {}

impl From<SignalProtocolError> for CryptoError {
    fn from(e: SignalProtocolError) -> Self {
        match e {
            SignalProtocolError::UntrustedIdentity(addr) => Self::new(
                CryptoErrorKind::UntrustedIdentity,
                format!("the identity key for {addr} has changed"),
            ),
            SignalProtocolError::SessionNotFound(s) => {
                Self::new(CryptoErrorKind::NoSession, s.to_string())
            }
            other => Self::protocol(other.to_string()),
        }
    }
}

/// libsignal's store traits must return its own error type.
pub(crate) fn to_signal(e: CryptoError) -> SignalProtocolError {
    SignalProtocolError::InvalidState("skyline vault", e.to_string())
}
