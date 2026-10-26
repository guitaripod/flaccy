//! The network layer: which addresses the server listens on, who may connect,
//! and which requests a browser must never be able to make.
//!
//! Easy mode serves [`EasyListener`], which binds the host's tailnet addresses
//! and loopback and drops every connection from anywhere else before reading a
//! byte. Household mode serves [`UnixListenerSecure`]. Both are wrapped by
//! [`connections`] so handlers see the peer address (TCP) or a
//! [`TrustedChannel`] marker (Unix socket), and both sit behind
//! [`guard_router`], which refuses browsers.

pub mod guard;
pub mod hosts;
pub mod listen;
pub mod names;
pub mod tailnet;
#[cfg(unix)]
pub mod unix;

pub use guard::{browser_guard, connections, guard_router, Connections, TrustedChannel};
pub use hosts::AllowedHosts;
pub use listen::{EasyHandle, EasyListener};
pub use tailnet::{addresses, is_loopback, is_tailnet, source_allowed, TailnetAddresses};
#[cfg(unix)]
pub use unix::{TrustedPeer, UnixListenerSecure};
