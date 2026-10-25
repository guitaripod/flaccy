//! The failures a Subsonic client can be told about.

use std::fmt;

/// A Subsonic error: the numeric code the protocol defines and a message that
/// names what failed, the cause and what to do next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApiError {
    pub code: i64,
    pub message: String,
}

impl ApiError {
    /// An error with an explicit protocol code.
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// Code 0: a failure that fits no other code.
    pub fn generic(message: impl Into<String>) -> Self {
        Self::new(0, message)
    }

    /// Code 10: `parameter` was left out of a call to `method`.
    pub fn missing_parameter(method: &str, parameter: &str) -> Self {
        Self::new(
            10,
            format!(
                "{method} needs the parameter '{parameter}' and the request did not carry it; add {parameter}=<value> and send it again"
            ),
        )
    }

    /// Code 70: the thing the request named does not exist.
    pub fn not_found(what: &str, id: &str) -> Self {
        Self::new(
            70,
            format!(
                "{what} '{id}' was not found; it may have been removed by a library scan, so refresh the client's library and pick it again"
            ),
        )
    }

    /// Code 0 for a parameter that is present but unusable.
    pub fn bad_parameter(method: &str, parameter: &str, value: &str, expected: &str) -> Self {
        Self::generic(format!(
            "{method} cannot use {parameter}='{value}'; {expected}"
        ))
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "error {}: {}", self.code, self.message)
    }
}

impl std::error::Error for ApiError {}
