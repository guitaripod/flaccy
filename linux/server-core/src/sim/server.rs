//! The server half of the simulation: push and pull exactly as PROTOCOL.md 6.1
//! and 6.2 describe them, over in-memory tables.

use super::store::Store;
use crate::apply::{
    apply_love, apply_playlist, apply_rating, apply_scalar, apply_session, clamp_reseed, reseed_into_doc, upsert,
    Caller, EntityRef, Outcome, Status,
};
use crate::digest::arg_hash;
use crate::model::{EntityKind, EntityValue};
use crate::mutation::{parse, Op, ParseError, PlaylistOp, Target};
use crate::stamp::{ServerClock, Stamp};
use crate::wire::{
    Change, ErrorCode, Mutation, MutationResult, MutationStatus, PullResponse, PushRequest,
    PushResponse,
};
use std::collections::{BTreeMap, BTreeSet};

/// Why the server answered a call with an HTTP error.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServerError {
    /// A retried id carried different arguments.
    InstanceConflict,
    /// An id skipped ahead; `have` is the last one applied.
    MutationGap {
        /// The last mutation id applied for the instance.
        have: i64,
    },
    /// The cursor is ahead of the server's log.
    CookieAhead,
    /// The wall clock is more than an hour behind the server clock.
    ClockBehind,
}

#[derive(Clone, Debug)]
struct StoredResult {
    arg_hash: String,
    status: MutationStatus,
    code: Option<ErrorCode>,
}

#[derive(Clone, Debug, Default)]
struct Progress {
    last: i64,
    results: BTreeMap<i64, StoredResult>,
}

/// A write the server applied, kept outside the restorable state as the test oracle's ground truth.
#[derive(Clone, Debug)]
pub struct JournalEntry {
    /// The operation applied.
    pub op: Op,
    /// The stamp the write was stored under.
    pub stored: Stamp,
}

/// Everything a backup restores: the state, the change log and the push progress.
#[derive(Clone, Debug)]
pub struct Snapshot {
    store: Store,
    seqs: BTreeMap<(EntityKind, String), i64>,
    seq: i64,
    clock: ServerClock,
    progress: BTreeMap<(String, String), Progress>,
}

/// The in-memory server.
#[derive(Debug)]
pub struct ServerModel {
    /// The entity tables.
    pub store: Store,
    /// The current server incarnation.
    pub incarnation: String,
    /// Every write the server applied, kept outside restorable state.
    pub journal: Vec<JournalEntry>,
    /// How many position rewrites the server performed.
    pub rebalances: u32,
    /// Argument hashes of every mutation the server ever processed.
    pub seen: BTreeSet<String>,
    seqs: BTreeMap<(EntityKind, String), i64>,
    seq: i64,
    clock: ServerClock,
    progress: BTreeMap<(String, String), Progress>,
}

fn via<T: Clone>(
    map: &mut BTreeMap<String, T>,
    key: &str,
    apply: impl FnOnce(&mut Option<T>) -> Outcome,
) -> Outcome {
    let mut slot = map.get(key).cloned();
    let outcome = apply(&mut slot);
    if outcome.status == Status::Applied {
        if let Some(value) = slot {
            map.insert(key.to_owned(), value);
        }
    }
    outcome
}

fn playlist_ids(entities: &[EntityValue]) -> BTreeSet<String> {
    entities
        .iter()
        .filter_map(|entity| match entity {
            EntityValue::Playlist(playlist) => Some(playlist.id.clone()),
            EntityValue::Entry(entry) => Some(entry.playlist.clone()),
            _ => None,
        })
        .collect()
}

impl ServerModel {
    /// An empty server with a fresh incarnation.
    pub fn new(incarnation: String) -> Self {
        ServerModel {
            store: Store::default(),
            incarnation,
            journal: Vec::new(),
            rebalances: 0,
            seen: BTreeSet::new(),
            seqs: BTreeMap::new(),
            seq: 0,
            clock: ServerClock::default(),
            progress: BTreeMap::new(),
        }
    }

    /// The highest change sequence number.
    pub fn head(&self) -> i64 {
        self.seq
    }

    /// A backup of the restorable state.
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            store: self.store.clone(),
            seqs: self.seqs.clone(),
            seq: self.seq,
            clock: self.clock,
            progress: self.progress.clone(),
        }
    }

    /// Rolls the state back to a backup and starts a new incarnation.
    pub fn restore(&mut self, snapshot: Snapshot, incarnation: String) {
        self.store = snapshot.store;
        self.seqs = snapshot.seqs;
        self.seq = snapshot.seq;
        self.clock = snapshot.clock;
        self.progress = snapshot.progress;
        self.incarnation = incarnation;
    }

    /// Checks that every instance's recorded mutation ids are exactly `1..=last`.
    pub fn check_dense_ids(&self) -> Result<(), String> {
        for ((device, instance), progress) in &self.progress {
            let dense = progress.results.len() as i64 == progress.last
                && progress.results.keys().copied().eq(1..=progress.last);
            if !dense {
                return Err(format!("ids of {device}/{instance} are not dense"));
            }
        }
        Ok(())
    }

    fn check_sequence(
        &self,
        progress: &Progress,
        mutations: &[Mutation],
    ) -> Result<(), ServerError> {
        let mut next = progress.last + 1;
        for mutation in mutations {
            if mutation.id <= progress.last {
                let hash = arg_hash(&mutation.name, &mutation.args);
                match progress.results.get(&mutation.id) {
                    Some(stored) if stored.arg_hash == hash => {}
                    _ => return Err(ServerError::InstanceConflict),
                }
            } else if mutation.id == next {
                next += 1;
            } else {
                return Err(ServerError::MutationGap {
                    have: progress.last,
                });
            }
        }
        Ok(())
    }

    /// `POST /sync/push`: retries answer the stored status, new ids apply in order.
    pub fn push(
        &mut self,
        caller: &Caller,
        request: &PushRequest,
        now_ms: i64,
    ) -> Result<PushResponse, ServerError> {
        if self.clock.is_behind(now_ms) {
            return Err(ServerError::ClockBehind);
        }
        let key = (request.device.clone(), request.instance.clone());
        let known = self.progress.get(&key).cloned().unwrap_or_default();
        self.check_sequence(&known, &request.mutations)?;
        let mut results = Vec::new();
        for mutation in &request.mutations {
            let stored = self
                .progress
                .get(&key)
                .and_then(|progress| progress.results.get(&mutation.id))
                .cloned();
            let (status, code) = match stored {
                Some(stored) => (stored.status, stored.code),
                None => self.apply_new(&key, caller, mutation, now_ms),
            };
            results.push(MutationResult {
                id: mutation.id,
                status,
                code,
            });
        }
        Ok(PushResponse {
            results,
            server_time_ms: now_ms,
        })
    }

    fn apply_new(
        &mut self,
        key: &(String, String),
        caller: &Caller,
        mutation: &Mutation,
        now_ms: i64,
    ) -> (MutationStatus, Option<ErrorCode>) {
        let stamp = self.clock.store(mutation.stamp, now_ms);
        self.seen.insert(arg_hash(&mutation.name, &mutation.args));
        let status = match parse(mutation) {
            Ok(op) => self.apply_op(&op, caller, stamp),
            Err(ParseError::Unsupported) => Status::Unsupported,
            Err(ParseError::Invalid(code)) => Status::Invalid(code),
        };
        let (wire, code) = status.wire();
        let progress = self.progress.entry(key.clone()).or_default();
        progress.last = mutation.id;
        progress.results.insert(
            mutation.id,
            StoredResult {
                arg_hash: arg_hash(&mutation.name, &mutation.args),
                status: wire,
                code,
            },
        );
        (wire, code)
    }

    fn apply_op(&mut self, op: &Op, caller: &Caller, stamp: Stamp) -> Status {
        let outcome = match op {
            Op::Playlist(playlist_op) => self.apply_playlist_op(playlist_op, caller, stamp),
            Op::Love(args) => via(&mut self.store.loves, &args.song_key, |slot| {
                apply_love(slot, args, caller, stamp)
            }),
            Op::Rating(args) => via(&mut self.store.ratings, &args.song_key, |slot| {
                apply_rating(slot, args, caller, stamp)
            }),
            Op::Scalar(scalar_op) => via(&mut self.store.scalars, scalar_op.key(), |slot| {
                apply_scalar(slot, scalar_op, caller, stamp)
            }),
            Op::Session(session) => via(&mut self.store.sessions, &caller.device, |slot| {
                apply_session(slot, session, caller, stamp)
            }),
            Op::Reseed(entities) => self.apply_reseed(&clamp_reseed(entities, self.clock.last()), caller),
            Op::Listen(_) | Op::DeviceRename(_) => Outcome::noop(),
        };
        if outcome.status == Status::Applied {
            self.commit(&outcome.changed);
            self.journal.push(JournalEntry {
                op: op.clone(),
                stored: stamp,
            });
        }
        outcome.status
    }

    fn apply_playlist_op(&mut self, op: &PlaylistOp, caller: &Caller, stamp: Stamp) -> Outcome {
        let mut doc = match op.target() {
            Target::Playlist(id) => self.store.doc(id),
            Target::Entry(id) => self.store.doc_of_entry(id),
            _ => None,
        };
        let outcome = apply_playlist(&mut doc, op, caller, stamp);
        if outcome.status == Status::Applied {
            if let Some(doc) = &doc {
                self.store.write_doc(doc, &outcome.changed);
            }
            let moved = outcome.changed.len() > 1;
            if moved && matches!(op, PlaylistOp::Insert(_) | PlaylistOp::Move(_)) {
                self.rebalances += 1;
            }
        }
        outcome
    }

    fn apply_reseed(&mut self, entities: &[EntityValue], caller: &Caller) -> Outcome {
        let backup = self.store.clone();
        let mut changed = Vec::new();
        for id in playlist_ids(entities) {
            let mut doc = self.store.doc(&id);
            let outcome = reseed_into_doc(&mut doc, &id, entities, caller);
            if let Status::Invalid(_) = outcome.status {
                self.store = backup;
                return outcome;
            }
            if let Some(doc) = &doc {
                self.store.write_doc(doc, &outcome.changed);
            }
            changed.extend(outcome.changed);
        }
        for entity in entities {
            let outcome = self.reseed_single(entity, caller);
            if let Status::Invalid(_) = outcome.status {
                self.store = backup;
                return outcome;
            }
            changed.extend(outcome.changed);
        }
        Outcome::from_changed(changed)
    }

    fn reseed_single(&mut self, entity: &EntityValue, caller: &Caller) -> Outcome {
        let store = &mut self.store;
        match entity {
            EntityValue::Love(v) => via(&mut store.loves, &v.song_key, |s| {
                upsert(s, v.clone(), caller)
            }),
            EntityValue::Rating(v) => via(&mut store.ratings, &v.song_key, |s| {
                upsert(s, v.clone(), caller)
            }),
            EntityValue::Scalar(v) => {
                via(&mut store.scalars, &v.key, |s| upsert(s, v.clone(), caller))
            }
            EntityValue::Session(v) => via(&mut store.sessions, &v.device, |s| {
                upsert(s, v.clone(), caller)
            }),
            EntityValue::Playlist(_) | EntityValue::Entry(_) => Outcome::noop(),
        }
    }

    fn commit(&mut self, changed: &[EntityRef]) {
        for reference in changed {
            self.seq += 1;
            self.seqs
                .insert((reference.kind, reference.id.clone()), self.seq);
        }
    }

    /// `GET /sync/pull`: the entities changed after `since`, ascending, with the instance's confirmed mutation id.
    pub fn pull(
        &self,
        device: &str,
        instance: &str,
        since: i64,
        limit: usize,
        now_ms: i64,
    ) -> Result<PullResponse, ServerError> {
        if since > self.seq {
            return Err(ServerError::CookieAhead);
        }
        let mut due: Vec<(i64, &(EntityKind, String))> = self
            .seqs
            .iter()
            .filter(|(_, &seq)| seq > since)
            .map(|(key, &seq)| (seq, key))
            .collect();
        due.sort();
        let more = due.len() > limit;
        due.truncate(limit);
        let changes = due
            .into_iter()
            .filter_map(|(seq, (kind, id))| {
                let value = self.store.get(*kind, id)?;
                Some(Change {
                    seq,
                    kind: *kind,
                    id: id.clone(),
                    deleted: value.is_dead(),
                    value: value.to_entity().value,
                })
            })
            .collect();
        let confirmed = self
            .progress
            .get(&(device.to_owned(), instance.to_owned()))
            .map_or(0, |progress| progress.last);
        Ok(PullResponse {
            head: self.seq,
            incarnation: self.incarnation.clone(),
            last_mutation_id: confirmed,
            more,
            server_time_ms: now_ms,
            changes,
        })
    }
}
