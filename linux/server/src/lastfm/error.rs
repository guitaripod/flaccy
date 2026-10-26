//! What can go wrong talking to Last.fm or the signer, sorted by what the caller should do next.

use std::fmt;

/// What the caller should do about a failed call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKind {
    /// Try again later: the network, a rate limit or a Last.fm outage.
    Transient,
    /// The session, token or API key will never work again; a person must reconnect.
    Credentials,
    /// Last.fm refused this request for good; repeating it changes nothing.
    Rejected,
    /// The signer did not sign; the cause is on the Worker side.
    Signer,
}

/// A failed call with the sentence a person can act on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApiError {
    /// What to do about it.
    pub kind: ErrorKind,
    /// Last.fm's error code, when it sent one.
    pub code: Option<i64>,
    /// A sentence naming what failed and the next step; never holds a key.
    pub message: String,
}

impl ApiError {
    /// A transient failure.
    pub fn transient(message: impl Into<String>) -> Self {
        Self { kind: ErrorKind::Transient, code: None, message: message.into() }
    }

    /// A failure of the signer.
    pub fn signer(message: impl Into<String>) -> Self {
        Self { kind: ErrorKind::Signer, code: None, message: message.into() }
    }

    /// The error Last.fm answered with `code` and `message`.
    pub fn from_lastfm(code: i64, message: &str) -> Self {
        let (kind, advice) = match code {
            8 | 11 | 16 | 29 => (ErrorKind::Transient, "Last.fm is busy; the server tries again on its own"),
            4 | 9 | 10 | 13 | 14 | 15 | 26 => (
                ErrorKind::Credentials,
                "Last.fm no longer accepts this connection; run `flaccy-server lastfm connect --user <name>` again",
            ),
            17 => (ErrorKind::Rejected, "the listening history is private; make it public in Last.fm's privacy settings"),
            6 => (ErrorKind::Rejected, "Last.fm refused the request as malformed"),
            _ => (ErrorKind::Rejected, "Last.fm refused the request"),
        };
        Self { kind, code: Some(code), message: format!("{advice} (code {code}: {})", message.trim()) }
    }

    /// True when waiting and repeating the call can work.
    pub fn is_transient(&self) -> bool {
        matches!(self.kind, ErrorKind::Transient | ErrorKind::Signer)
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ApiError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_sort_into_what_to_do_next() {
        assert_eq!(ApiError::from_lastfm(29, "rate").kind, ErrorKind::Transient);
        assert_eq!(ApiError::from_lastfm(9, "Invalid session key").kind, ErrorKind::Credentials);
        assert_eq!(ApiError::from_lastfm(6, "bad").kind, ErrorKind::Rejected);
        assert!(ApiError::from_lastfm(9, "x").message.contains("lastfm connect"));
    }
}
