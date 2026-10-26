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
pub mod library;
pub mod link;
pub mod live;
pub mod merge;
pub mod recorder;
pub mod sink;
pub mod transport;

mod base;
mod covers;
mod error;
mod ids;
mod listens;
mod lookup;
mod materialize;
mod meta;
mod pending;
mod poke;
mod reset;
mod schema;
mod songref;
mod status;
mod store;

pub use credentials::TokenStore;
pub use driver::{Backoff, Blocker, Driver, ServerIdentity, SyncState, SyncStatus};
pub use engine::{Dirty, Engine, Enrollment, PullOutcome, PullRequest, PushFailure, PushRecovery};
pub use error::{Incompatibility, Result, SyncError};
pub use import::ImportReport;
pub use link::ServerLink;
pub use listens::{ListenItem, ListensPage, ListensRequest};
pub use lookup::files_for_loves;
pub use materialize::resolve_ghosts;
pub use merge::{LocalEntry, MergeReport, MergedPlaylist};
pub use poke::PokeHandle;
pub use recorder::{clear_scalar, record_scalar, Recorder};
pub use sink::ScalarSink;
pub use songref::song_key_of;
pub use transport::{ApiError, DeviceInfo, Transport};

pub(crate) use schema::migrate;
pub(crate) use store::record;
