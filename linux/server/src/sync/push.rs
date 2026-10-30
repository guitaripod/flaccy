//! `POST /sync/push`: PROTOCOL.md section 6.1.

use std::fmt;

use flaccy_server_core::apply::{Caller, Status};
use flaccy_server_core::digest::arg_hash;
use flaccy_server_core::mutation::{parse, ParseError};
use flaccy_server_core::wire::{ErrorCode, Mutation, MutationResult, MutationStatus, PushRequest, PushResponse, Role};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior};
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::Value;
use tokio::sync::broadcast;

use super::apply::{apply_op, Ctx};
use super::meta::Counters;
use super::{DeviceRenamer, Poke, Store, SyncError};
use crate::ids;
use crate::security::{self, Principal};

/// The most mutations one push may carry.
pub const MAX_BATCH: usize = 500;

/// Why a push was refused as a whole; nothing was applied.
#[derive(Debug)]
pub enum PushError {
    /// The client's incarnation is not the server's.
    IncarnationChanged {
        /// The server's incarnation.
        current: String,
    },
    /// A retried id carried different arguments.
    InstanceConflict,
    /// An id skipped ahead; `have` is the last one applied.
    MutationGap {
        /// The last mutation id applied for the instance.
        have: i64,
    },
    /// The wall clock is more than an hour behind the server clock.
    ClockBehind,
    /// The request names a device other than the one the token belongs to.
    DeviceMismatch,
    /// More than [`MAX_BATCH`] mutations.
    TooLarge,
    /// The database failed.
    Storage(SyncError),
}

impl fmt::Display for PushError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PushError::IncarnationChanged { .. } => write!(
                formatter,
                "The server's state was replaced since this device last synced, so nothing was applied. Run the reset of the protocol: reseed from your base, start a new instance and push again."
            ),
            PushError::InstanceConflict => write!(
                formatter,
                "A mutation id was reused with different arguments, so nothing was applied. Move the pending mutations to a new instance and push again."
            ),
            PushError::MutationGap { have } => write!(
                formatter,
                "Mutation ids must follow on without gaps and the server has {have}, so nothing was applied. Push again starting at id {}.",
                have + 1
            ),
            PushError::ClockBehind => write!(
                formatter,
                "The server's clock is more than an hour behind the changes it holds, so it refuses writes until the clock is corrected. Fix the host's time, then push again."
            ),
            PushError::DeviceMismatch => write!(
                formatter,
                "The device in the request is not the device this token belongs to. Send the device id returned when the device enrolled."
            ),
            PushError::TooLarge => write!(
                formatter,
                "A push carries at most {MAX_BATCH} mutations. Split the pending mutations into several pushes."
            ),
            PushError::Storage(source) => write!(formatter, "{source}"),
        }
    }
}

impl std::error::Error for PushError {}

impl From<SyncError> for PushError {
    fn from(source: SyncError) -> Self {
        PushError::Storage(source)
    }
}

impl From<rusqlite::Error> for PushError {
    fn from(source: rusqlite::Error) -> Self {
        PushError::Storage(source.into())
    }
}

fn wire_role(role: security::Role) -> Role {
    match role {
        security::Role::Admin => Role::Admin,
        security::Role::Member => Role::Member,
        security::Role::Guest => Role::Guest,
        security::Role::Pending => Role::Pending,
    }
}

/// The identity a core apply sees for a request from `principal`'s device.
pub(super) fn caller_of(principal: &Principal, device: &str) -> Caller {
    Caller {
        user: principal.user.to_string(),
        role: wire_role(principal.role),
        device: device.to_owned(),
    }
}

fn word_of<T: Serialize>(value: &T) -> String {
    match serde_json::to_value(value) {
        Ok(Value::String(word)) => word,
        _ => String::new(),
    }
}

fn from_word<T: DeserializeOwned>(word: &str) -> Result<T, SyncError> {
    serde_json::from_value(Value::String(word.to_owned()))
        .map_err(|_| SyncError::Corrupt(format!("mutation_results holds the word '{word}'")))
}

pub(super) struct Effects {
    pokes: broadcast::Sender<Poke>,
    renamer: Option<DeviceRenamer>,
}

impl Effects {
    pub(super) fn deliver(&self, counters: &mut Counters) {
        let (pokes, renames) = counters.take_effects();
        for poke in pokes {
            let _ = self.pokes.send(poke);
        }
        if let Some(renamer) = &self.renamer {
            for (device, name) in renames {
                renamer(&device, &name);
            }
        }
    }
}

fn last_mutation_id(connection: &Connection, request: &PushRequest) -> Result<i64, SyncError> {
    Ok(connection
        .prepare_cached("SELECT last_mutation_id FROM device_progress WHERE device_id = ?1 AND instance = ?2")?
        .query_row((&request.device, &request.instance), |row| row.get(0))
        .optional()?
        .unwrap_or(0))
}

fn stored_hash(connection: &Connection, request: &PushRequest, id: i64) -> Result<Option<Vec<u8>>, SyncError> {
    Ok(connection
        .prepare_cached("SELECT arg_hash FROM mutation_results WHERE device_id = ?1 AND instance = ?2 AND id = ?3")?
        .query_row((&request.device, &request.instance, id), |row| row.get(0))
        .optional()?)
}

fn check_sequence(connection: &Connection, request: &PushRequest, last: i64) -> Result<(), PushError> {
    let mut next = last + 1;
    for mutation in &request.mutations {
        if mutation.id <= last {
            let expected = ids::unhex(&arg_hash(&mutation.name, &mutation.args));
            match (stored_hash(connection, request, mutation.id)?, expected) {
                (Some(stored), Some(expected)) if stored == expected => {}
                _ => return Err(PushError::InstanceConflict),
            }
        } else if mutation.id == next {
            next += 1;
        } else {
            return Err(PushError::MutationGap { have: last });
        }
    }
    Ok(())
}

fn stored_result(connection: &Connection, request: &PushRequest, id: i64) -> Result<MutationResult, SyncError> {
    let (status, code): (String, Option<String>) = connection
        .prepare_cached("SELECT status, code FROM mutation_results WHERE device_id = ?1 AND instance = ?2 AND id = ?3")?
        .query_row((&request.device, &request.instance, id), |row| Ok((row.get(0)?, row.get(1)?)))?;
    Ok(MutationResult {
        id,
        status: from_word::<MutationStatus>(&status)?,
        code: code.as_deref().map(from_word::<ErrorCode>).transpose()?,
    })
}

fn status_of(connection: &Connection, mutation: &Mutation, ctx: &mut Ctx<'_>) -> Result<Status, SyncError> {
    Ok(match parse(mutation) {
        Ok(op) => apply_op(connection, &op, ctx)?.status,
        Err(ParseError::Unsupported) => Status::Unsupported,
        Err(ParseError::Invalid(code)) => Status::Invalid(code),
    })
}

fn record_result(
    connection: &Connection,
    request: &PushRequest,
    mutation: &Mutation,
    status: Status,
    now_ms: i64,
) -> Result<(MutationStatus, Option<ErrorCode>), SyncError> {
    let (wire, code) = status.wire();
    let hash = ids::unhex(&arg_hash(&mutation.name, &mutation.args)).unwrap_or_default();
    connection
        .prepare_cached(
            "INSERT INTO mutation_results(device_id, instance, id, arg_hash, status, code, at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )?
        .execute((
            &request.device,
            &request.instance,
            mutation.id,
            hash.as_slice(),
            word_of(&wire),
            code.as_ref().map(word_of),
            now_ms,
        ))?;
    connection
        .prepare_cached(
            "INSERT INTO device_progress(device_id, instance, last_mutation_id) VALUES (?1, ?2, ?3)
             ON CONFLICT(device_id, instance) DO UPDATE SET last_mutation_id = excluded.last_mutation_id",
        )?
        .execute((&request.device, &request.instance, mutation.id))?;
    Ok((wire, code))
}

fn apply_new(
    transaction: &mut rusqlite::Transaction<'_>,
    caller: &Caller,
    request: &PushRequest,
    mutation: &Mutation,
    now_ms: i64,
    counters: &mut Counters,
) -> Result<MutationResult, SyncError> {
    let stamp = counters.clock.store(mutation.stamp, now_ms);
    let savepoint = transaction.savepoint()?;
    let mut ctx = Ctx { caller, stamp, counters };
    let status = status_of(&savepoint, mutation, &mut ctx)?;
    let (wire, code) = record_result(&savepoint, request, mutation, status, now_ms)?;
    counters.save(&savepoint)?;
    savepoint.commit()?;
    Ok(MutationResult {
        id: mutation.id,
        status: wire,
        code,
    })
}

fn run_push(
    connection: &mut Connection,
    caller: &Caller,
    request: &PushRequest,
    now_ms: i64,
    effects: &Effects,
) -> Result<PushResponse, PushError> {
    let mut counters = Counters::load(connection)?;
    if counters.clock.is_behind(now_ms) {
        return Err(PushError::ClockBehind);
    }
    let last = last_mutation_id(connection, request)?;
    check_sequence(connection, request, last)?;
    let mut results = Vec::with_capacity(request.mutations.len());
    let mut transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    for mutation in &request.mutations {
        let result = if mutation.id <= last {
            stored_result(&transaction, request, mutation.id)?
        } else {
            apply_new(&mut transaction, caller, request, mutation, now_ms, &mut counters)?
        };
        results.push(result);
    }
    transaction.commit()?;
    effects.deliver(&mut counters);
    Ok(PushResponse {
        results,
        server_time_ms: now_ms,
    })
}

impl Store {
    pub(super) fn check_incarnation(&self, claimed: Option<&str>) -> Option<String> {
        let current = self.incarnation();
        claimed.filter(|claimed| *claimed != current).map(|_| current)
    }

    pub(super) fn effects(&self) -> Effects {
        Effects {
            pokes: self.inner.pokes.clone(),
            renamer: self.inner.renamer.read().unwrap_or_else(|poisoned| poisoned.into_inner()).clone(),
        }
    }

    /// Applies a push as PROTOCOL.md section 6.1 describes.
    ///
    /// `claimed_incarnation` is the `Flaccy-Incarnation` header when the client sent one. The retry, gap and
    /// conflict checks cover the whole request before the first mutation applies; the mutations then apply in
    /// order inside one transaction, each in a savepoint together with its progress record, so a push costs one
    /// fsync however many mutations it carries and a storage failure applies none of them.
    pub async fn push(
        &self,
        principal: &Principal,
        request: PushRequest,
        claimed_incarnation: Option<&str>,
    ) -> Result<PushResponse, PushError> {
        if let Some(current) = self.check_incarnation(claimed_incarnation) {
            return Err(PushError::IncarnationChanged { current });
        }
        if principal.device.as_ref().map(|device| device.as_str()) != Some(request.device.as_str()) {
            return Err(PushError::DeviceMismatch);
        }
        if request.mutations.len() > MAX_BATCH {
            return Err(PushError::TooLarge);
        }
        let caller = caller_of(principal, &request.device);
        let now_ms = self.now_ms();
        let effects = self.effects();
        self.write(move |connection| run_push(connection, &caller, &request, now_ms, &effects)).await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    use flaccy_library::fingerprint::fixtures::TempDir;
    use flaccy_server_core::stamp::Stamp;
    use serde_json::json;

    use super::*;
    use crate::security::{DeviceId, UserId};

    fn principal() -> Principal {
        Principal {
            user: UserId("alice".to_owned()),
            role: security::Role::Member,
            device: Some(DeviceId("phone".to_owned())),
        }
    }

    fn love(id: i64) -> Mutation {
        let key = format!("{id:032x}");
        Mutation {
            id,
            name: "love.set".to_owned(),
            stamp: Stamp((1_790_000_000_000 << 16) + id),
            args: json!({ "songKey": key, "ref": { "songKey": key, "title": "Title", "artist": "Artist" }, "loved": true }),
        }
    }

    fn push_of(mutations: Vec<Mutation>) -> PushRequest {
        PushRequest { device: "phone".to_owned(), instance: "i1".to_owned(), mutations }
    }

    async fn open_counting_commits(dir: &TempDir) -> (Store, Arc<AtomicUsize>) {
        let store = Store::open(&dir.path().join("state.sqlite"), "inc".to_owned()).await.unwrap();
        let commits = Arc::new(AtomicUsize::new(0));
        let counted = commits.clone();
        store
            .write(move |connection| {
                connection.commit_hook(Some(move || {
                    counted.fetch_add(1, Ordering::SeqCst);
                    false
                }));
                Ok::<_, SyncError>(())
            })
            .await
            .unwrap();
        (store, commits)
    }

    #[tokio::test]
    async fn a_push_commits_once_however_many_mutations_it_carries() {
        let dir = TempDir::new("push-commits");
        let (store, commits) = open_counting_commits(&dir).await;
        let response = store.push(&principal(), push_of((1..=50).map(love).collect()), None).await.unwrap();
        assert_eq!(response.results.len(), 50);
        assert!(response.results.iter().all(|result| result.status == MutationStatus::Applied));
        assert_eq!(commits.load(Ordering::SeqCst), 1);
        store.close().await.unwrap();
    }

    #[tokio::test]
    async fn a_refused_mutation_in_the_middle_leaves_its_neighbours_applied_and_all_recorded() {
        let dir = TempDir::new("push-savepoints");
        let (store, commits) = open_counting_commits(&dir).await;
        let mut mutations = vec![love(1), love(2), love(3)];
        mutations[1].name = "not.a.mutation".to_owned();
        let response = store.push(&principal(), push_of(mutations.clone()), None).await.unwrap();
        let statuses: Vec<_> = response.results.iter().map(|result| result.status).collect();
        assert_eq!(statuses, vec![MutationStatus::Applied, MutationStatus::Unsupported, MutationStatus::Applied]);
        assert_eq!(commits.load(Ordering::SeqCst), 1);
        let retry = store.push(&principal(), push_of(mutations), None).await.unwrap();
        let again: Vec<_> = retry.results.iter().map(|result| result.status).collect();
        assert_eq!(again, statuses);
        let pulled = store.pull(&principal(), "i1", 0, 100, None).await.unwrap();
        assert_eq!(pulled.last_mutation_id, 3);
        assert_eq!(pulled.changes.len(), 2);
        store.close().await.unwrap();
    }
}
