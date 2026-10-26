//! Scalar key validation: the key prefix says what the value may be.

use crate::song::is_song_key;
use crate::wire::ErrorCode;
use serde_json::Value;

const MAX_VALUE_BYTES: usize = 64 * 1024;
const MAX_PREF_BYTES: usize = 4 * 1024;

/// Checks a key's prefix and, for `lyr/` and `meta/`, its song key.
pub fn validate_scalar_key(key: &str) -> Result<(), ErrorCode> {
    let (prefix, rest) = key.split_once('/').ok_or(ErrorCode::BadKey)?;
    let known = match prefix {
        "pref" | "eq" | "want" | "lastfm" | "offline" => true,
        "lyr" | "meta" => is_song_key(rest),
        _ => false,
    };
    if known && !rest.is_empty() {
        Ok(())
    } else {
        Err(ErrorCode::BadKey)
    }
}

/// Checks a key and the value written under it: type per prefix and size limits.
pub fn validate_scalar(key: &str, value: &Value) -> Result<(), ErrorCode> {
    validate_scalar_key(key)?;
    let size = value.to_string().len();
    let prefix = key.split_once('/').map_or("", |(prefix, _)| prefix);
    let shape_ok = match prefix {
        "lyr" => value.as_i64().is_some_and(|ms| ms >= 0),
        "meta" => value.is_object(),
        _ => true,
    };
    if !shape_ok {
        Err(ErrorCode::BadArgs)
    } else if size > MAX_VALUE_BYTES || (prefix == "pref" && size > MAX_PREF_BYTES) {
        Err(ErrorCode::TooLarge)
    } else {
        Ok(())
    }
}
