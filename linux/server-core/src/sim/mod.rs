//! A deterministic in-memory simulation of the protocol: a server model, client
//! models and a seeded world that breaks the network, the clocks and the
//! processes, then checks that everyone converged without losing a write.

pub mod client;
pub mod oracle;
pub mod rng;
pub mod scenario;
pub mod server;
pub mod store;
pub mod world;

#[cfg(test)]
mod tests;
