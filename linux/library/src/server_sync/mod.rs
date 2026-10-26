//! Flaccy Server sync for the Linux client.
//!
//! The wire contract is `docs/server/PROTOCOL.md`; the pure rules (stamps,
//! mutators, rebase, the ledger) come from `flaccy-server-core`. This module is
//! the durable half: the tables that hold the base, the pending queue and the
//! ghosts, the recorder that turns app writes into mutations in one
//! transaction, the sans-IO [`engine::Engine`], the materializer that maps
//! pulled entities onto the app tables, and a blocking [`driver::Driver`].
//!
//! # First connect
//!
//! Playlist ids, entry ids, the love stamp floor and the listen batching come
//! from `flaccy_server_core::song` and PROTOCOL.md section 13; see [`import`].

pub mod credentials;
pub mod driver;
pub mod engine;
pub mod import;
pub mod link;
pub mod recorder;
pub mod sink;
pub mod transport;

mod base;
mod error;
mod ids;
mod listens;
mod materialize;
mod meta;
mod pending;
mod reset;
mod schema;
mod songref;
mod store;

pub use credentials::TokenStore;
pub use driver::{Backoff, Driver, PokeHandle, SyncState, SyncStatus};
pub use engine::{Dirty, Engine, Enrollment, PullOutcome, PullRequest, PushFailure, PushRecovery};
pub use error::{Result, SyncError};
pub use import::ImportReport;
pub use link::ServerLink;
pub use listens::{ListenItem, ListensPage, ListensRequest};
pub use materialize::resolve_ghosts;
pub use recorder::{clear_scalar, record_scalar, Recorder};
pub use sink::ScalarSink;
pub use songref::song_key_of;
pub use transport::{ApiError, Transport};

pub(crate) use schema::migrate;
pub(crate) use store::record;
