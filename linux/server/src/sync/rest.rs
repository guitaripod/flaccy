//! Writes made for an API key instead of an enrolled device: the OpenSubsonic
//! calls and the legacy migration apply the same mutations a push carries, one
//! transaction each, numbered by a counter of their own (`rest_progress`).

use std::fmt;

use flaccy_server_core::apply::{Caller, Status};
use flaccy_server_core::model::Source;
use flaccy_server_core::mutation::{parse, Op, ParseError};
use flaccy_server_core::wire::{Mutation, MutationResult};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior};

use super::apply::{apply_op, Ctx};
use super::listens::record_as;
use super::meta::Counters;
use super::push::{caller_of, Effects};
use super::{Store, SyncError};
use crate::security::Principal;

/// Where a batch's stamps come from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Stamping {
    /// The server's clock at the moment of the write.
    Now,
    /// The stamp each mutation carries, capped by the server's clock; for imports of older state.
    AsGiven,
}

/// How a batch is applied.
#[derive(Clone, Copy, Debug)]
pub(super) struct BatchKind {
    /// What a `listen.record` in the batch is stored as.
    pub source: Source,
    /// Where the stamps come from.
    pub stamping: Stamping,
}

impl BatchKind {
    /// A batch from an OpenSubsonic call.
    pub const REST: BatchKind = BatchKind {
        source: Source::Opensubsonic,
        stamping: Stamping::Now,
    };
}

/// Why a write made for an API key was refused as a whole; nothing was applied.
#[derive(Debug)]
pub enum RestWriteError {
    /// The wall clock is more than an hour behind the server clock.
    ClockBehind,
    /// The principal has no device, so its writes have no counter to be numbered by.
    NoDevice,
    /// The database failed.
    Storage(SyncError),
}

impl fmt::Display for RestWriteError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RestWriteError::ClockBehind => write!(
                formatter,
                "The server's clock is more than an hour behind the changes it holds, so it refuses writes until the clock is corrected. Fix the host's time, then try again."
            ),
            RestWriteError::NoDevice => write!(
                formatter,
                "This login has no device to record the change under. This is a bug in flaccy-server; report it with this message."
            ),
            RestWriteError::Storage(source) => write!(formatter, "{source}"),
        }
    }
}

impl std::error::Error for RestWriteError {}

impl From<SyncError> for RestWriteError {
    fn from(source: SyncError) -> Self {
        RestWriteError::Storage(source)
    }
}

impl From<rusqlite::Error> for RestWriteError {
    fn from(source: rusqlite::Error) -> Self {
        RestWriteError::Storage(source.into())
    }
}

fn last_id(connection: &Connection, key: &str) -> Result<i64, SyncError> {
    Ok(connection
        .prepare_cached("SELECT last_mutation_id FROM rest_progress WHERE key_id = ?1")?
        .query_row([key], |row| row.get(0))
        .optional()?
        .unwrap_or(0))
}

fn save_id(connection: &Connection, key: &str, id: i64) -> Result<(), SyncError> {
    connection
        .prepare_cached(
            "INSERT INTO rest_progress(key_id, last_mutation_id) VALUES (?1, ?2)
             ON CONFLICT(key_id) DO UPDATE SET last_mutation_id = excluded.last_mutation_id",
        )?
        .execute((key, id))?;
    Ok(())
}

fn status_of(connection: &Connection, mutation: &Mutation, source: Source, ctx: &mut Ctx<'_>) -> Result<Status, SyncError> {
    Ok(match parse(mutation) {
        Ok(Op::Listen(inputs)) => record_as(connection, &inputs, source, ctx)?.status,
        Ok(op) => apply_op(connection, &op, ctx)?.status,
        Err(ParseError::Unsupported) => Status::Unsupported,
        Err(ParseError::Invalid(code)) => Status::Invalid(code),
    })
}

struct Run<'a> {
    caller: &'a Caller,
    kind: BatchKind,
    now_ms: i64,
    effects: &'a Effects,
}

fn apply_one(
    connection: &mut Connection,
    run: &Run<'_>,
    id: i64,
    mutation: &Mutation,
    counters: &mut Counters,
) -> Result<MutationResult, SyncError> {
    let stamp = match run.kind.stamping {
        Stamping::Now => counters.clock.next(run.now_ms),
        Stamping::AsGiven => counters.clock.store(mutation.stamp, run.now_ms),
    };
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut ctx = Ctx {
        caller: run.caller,
        stamp,
        counters,
    };
    let status = status_of(&transaction, mutation, run.kind.source, &mut ctx)?;
    save_id(&transaction, &run.caller.device, id)?;
    counters.save(&transaction)?;
    transaction.commit()?;
    run.effects.deliver(counters);
    let (wire, code) = status.wire();
    Ok(MutationResult {
        id,
        status: wire,
        code,
    })
}

fn run_batch(
    connection: &mut Connection,
    run: &Run<'_>,
    build: impl FnOnce(i64) -> Vec<Mutation>,
) -> Result<Vec<MutationResult>, RestWriteError> {
    let mut counters = Counters::load(connection)?;
    if counters.clock.is_behind(run.now_ms) {
        return Err(RestWriteError::ClockBehind);
    }
    let first = last_id(connection, &run.caller.device)? + 1;
    let mutations = build(first);
    let mut results = Vec::with_capacity(mutations.len());
    for (offset, mutation) in mutations.iter().enumerate() {
        results.push(apply_one(connection, run, first + offset as i64, mutation, &mut counters)?);
    }
    Ok(results)
}

impl Store {
    /// Applies `mutations` for the API key behind `principal`, whose `device` names the key's counter.
    ///
    /// The ids and stamps in the mutations are ignored: each gets the key's next mutation id and a stamp from the
    /// server's clock. Every mutation commits on its own, like a push, and the results come back in order.
    pub async fn apply_as(&self, principal: &Principal, mutations: Vec<Mutation>) -> Result<Vec<MutationResult>, RestWriteError> {
        self.apply_numbered(principal, move |_| mutations).await
    }

    /// Like [`Store::apply_as`] for mutations that must know their own id: `build` receives the id the first one
    /// will get, and mutation `n` gets that id plus `n`.
    pub async fn apply_numbered<F>(&self, principal: &Principal, build: F) -> Result<Vec<MutationResult>, RestWriteError>
    where
        F: FnOnce(i64) -> Vec<Mutation> + Send + 'static,
    {
        self.apply_batch(principal, BatchKind::REST, build).await
    }

    pub(super) async fn apply_batch<F>(&self, principal: &Principal, kind: BatchKind, build: F) -> Result<Vec<MutationResult>, RestWriteError>
    where
        F: FnOnce(i64) -> Vec<Mutation> + Send + 'static,
    {
        let Some(device) = principal.device.as_ref() else {
            return Err(RestWriteError::NoDevice);
        };
        let caller = caller_of(principal, device.as_str());
        let now_ms = self.now_ms();
        let effects = self.effects();
        self.write(move |connection| {
            let run = Run {
                caller: &caller,
                kind,
                now_ms,
                effects: &effects,
            };
            run_batch(connection, &run, build)
        })
        .await
    }
}
