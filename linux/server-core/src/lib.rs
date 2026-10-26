#![forbid(unsafe_code)]
#![deny(missing_docs)]
//! Flaccy Server's sync engine as pure logic.
//!
//! No I/O, no database, no async, no threads: the SQLite server, the Linux
//! client and the Apple clients (through the string-in, string-out
//! [`json_api`]) all run the same code, so a mutation means the same thing on
//! every side. The contract is `docs/server/PROTOCOL.md`.

pub mod apply;
pub mod digest;
pub mod json_api;
pub mod ledger;
pub mod model;
pub mod mutation;
pub mod position;
pub mod rebase;
pub mod scalar;
pub mod song;
pub mod stamp;
pub mod wire;

#[cfg(any(test, feature = "sim"))]
pub mod sim;
