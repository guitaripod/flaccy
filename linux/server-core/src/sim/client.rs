//! The client half of the simulation: durable base state plus pending
//! mutations, whose fold is the visible state. A pull alone retires pending
//! mutations; push results only mark them acknowledged or failed.

use super::server::ServerError;
use super::store::Store;
use crate::apply::Caller;
use crate::model::{Entity, EntityKind, EntityValue};
use crate::mutation::{parse, Op, Target};
use crate::rebase::{
    fold_love, fold_playlist, fold_rating, fold_scalar, fold_session, PendingMutation,
};
use crate::stamp::{ClientClock, Stamp};
use crate::wire::{Mutation, MutationStatus, PullResponse, PushRequest, PushResponse};
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// A pending mutation with the client's bookkeeping.
#[derive(Clone, Debug)]
pub struct Pend {
    /// The mutation.
    pub mutation: Mutation,
    /// True once the server refused the mutation.
    pub failed: bool,
    /// True once a push response answered the mutation.
    pub acked: bool,
}

/// What survives a crash.
#[derive(Clone, Debug)]
pub struct Durable {
    /// The current instance id.
    pub instance: String,
    /// The server incarnation last seen, if any.
    pub incarnation: Option<String>,
    /// The `seq` the base is complete up to.
    pub cursor: i64,
    /// The state as of the last pull.
    pub base: Store,
    /// Mutations written locally and not yet confirmed by a pull.
    pub pending: Vec<Pend>,
    /// The id the next mutation takes.
    pub next_id: i64,
    /// The last stamp the client clock handed out.
    pub clock_last: Stamp,
}

impl Durable {
    /// The state of a fresh install, which learned the server's incarnation when it enrolled.
    pub fn fresh(instance: String, incarnation: String) -> Self {
        Durable {
            instance,
            incarnation: Some(incarnation),
            cursor: 0,
            base: Store::default(),
            pending: Vec::new(),
            next_id: 1,
            clock_last: Stamp::ZERO,
        }
    }
}

/// The request a pull response answers, as the client remembers it.
#[derive(Clone, Debug)]
pub struct PullContext {
    /// The instance the request carried.
    pub instance: String,
    /// The cursor the pull asked from.
    pub since: i64,
}

/// One device's client.
#[derive(Debug)]
pub struct ClientModel {
    /// The device id.
    pub device: String,
    /// Who the client writes as.
    pub caller: Caller,
    /// What survives a crash.
    pub durable: Durable,
    /// Times a pull moved the cursor backwards.
    pub cursor_regressions: u32,
    /// Client resets after a new incarnation or cookie_ahead.
    pub resets: u32,
    /// Client moves to a new instance after an instance conflict.
    pub rotations: u32,
    /// Mutations a pull retired, for the loss audit.
    pub retired: Vec<Mutation>,
    offset_ms: i64,
}

impl ClientModel {
    /// A fresh install of a device.
    pub fn new(device: &str, user: &str, instance: String, incarnation: String) -> Self {
        ClientModel {
            device: device.to_owned(),
            caller: Caller::member(user, device),
            durable: Durable::fresh(instance, incarnation),
            cursor_regressions: 0,
            resets: 0,
            rotations: 0,
            retired: Vec::new(),
            offset_ms: 0,
        }
    }

    /// A process crash: whatever was in memory only is gone.
    pub fn crash(&mut self) {
        self.offset_ms = 0;
    }

    /// Wipes the install and starts a new instance on the same device.
    pub fn reinstall(&mut self, instance: String, incarnation: String) {
        self.durable = Durable::fresh(instance, incarnation);
        self.offset_ms = 0;
    }

    fn clock(&self) -> ClientClock {
        ClientClock::new(self.durable.clock_last, self.offset_ms)
    }

    fn observe(&mut self, server_time_ms: i64, local_now_ms: i64) {
        let mut clock = self.clock();
        clock.observe_server_time(server_time_ms, local_now_ms);
        self.offset_ms = clock.offset_ms();
    }

    fn stamp(&mut self, local_now_ms: i64) -> Stamp {
        let mut clock = self.clock();
        let stamp = clock.next(local_now_ms);
        self.durable.clock_last = clock.last();
        stamp
    }

    /// Writes a mutation to the durable pending list.
    pub fn record(&mut self, name: &str, args: Value, local_now_ms: i64) {
        let stamp = self.stamp(local_now_ms);
        let mutation = Mutation {
            id: self.durable.next_id,
            name: name.to_owned(),
            stamp,
            args,
        };
        self.durable.next_id += 1;
        self.durable.pending.push(Pend {
            mutation,
            failed: false,
            acked: false,
        });
    }

    fn pending_view(&self) -> Vec<PendingMutation> {
        self.durable
            .pending
            .iter()
            .map(|pend| PendingMutation {
                mutation: pend.mutation.clone(),
                failed: pend.failed,
            })
            .collect()
    }

    fn touched_keys(&self, pending: &[PendingMutation]) -> BTreeSet<(EntityKind, String)> {
        let base = &self.durable.base;
        let mut keys = BTreeSet::new();
        keys.extend(
            base.playlists
                .keys()
                .map(|id| (EntityKind::Playlist, id.clone())),
        );
        keys.extend(
            base.entries
                .values()
                .map(|entry| (EntityKind::Playlist, entry.playlist.clone())),
        );
        keys.extend(base.loves.keys().map(|k| (EntityKind::Love, k.clone())));
        keys.extend(base.ratings.keys().map(|k| (EntityKind::Rating, k.clone())));
        keys.extend(base.scalars.keys().map(|k| (EntityKind::Scalar, k.clone())));
        keys.extend(
            base.sessions
                .keys()
                .map(|k| (EntityKind::Session, k.clone())),
        );
        for pend in pending.iter().filter(|p| !p.failed) {
            if let Ok(op) = parse(&pend.mutation) {
                keys.extend(self.keys_of(&op));
            }
        }
        keys
    }

    fn keys_of(&self, op: &Op) -> Vec<(EntityKind, String)> {
        match op.target() {
            Target::Playlist(id) => vec![(EntityKind::Playlist, id.to_owned())],
            Target::Love(id) => vec![(EntityKind::Love, id.to_owned())],
            Target::Rating(id) => vec![(EntityKind::Rating, id.to_owned())],
            Target::Scalar(id) => vec![(EntityKind::Scalar, id.to_owned())],
            Target::Session => vec![(EntityKind::Session, self.device.clone())],
            Target::Reseed => match op {
                Op::Reseed(entities) => entities.iter().map(reseed_key).collect(),
                _ => Vec::new(),
            },
            Target::Entry(_) | Target::Listens | Target::Device => Vec::new(),
        }
    }

    /// What the person sees: the base with every live pending mutation folded in.
    pub fn visible(&self) -> Store {
        let pending = self.pending_view();
        let base = &self.durable.base;
        let caller = &self.caller;
        let mut out = Store::default();
        for (kind, id) in self.touched_keys(&pending) {
            match kind {
                EntityKind::Playlist => {
                    let doc = fold_playlist(&id, base.doc(&id).as_ref(), caller, &pending);
                    if let Some(doc) = doc {
                        out.playlists.insert(id.clone(), doc.playlist);
                        out.entries
                            .extend(doc.entries.into_iter().map(|e| (e.id.clone(), e)));
                    }
                }
                EntityKind::Love => {
                    let love = fold_love(&id, base.loves.get(&id), caller, &pending);
                    out.loves.extend(love.map(|v| (id.clone(), v)));
                }
                EntityKind::Rating => {
                    let rating = fold_rating(&id, base.ratings.get(&id), caller, &pending);
                    out.ratings.extend(rating.map(|v| (id.clone(), v)));
                }
                EntityKind::Scalar => {
                    let scalar = fold_scalar(&id, base.scalars.get(&id), caller, &pending);
                    out.scalars.extend(scalar.map(|v| (id.clone(), v)));
                }
                EntityKind::Session => {
                    let session = fold_session(&id, base.sessions.get(&id), caller, &pending);
                    out.sessions.extend(session.map(|v| (id.clone(), v)));
                }
                EntityKind::PlaylistEntry | EntityKind::Listen => {}
            }
        }
        out
    }

    /// The push request for everything not yet acknowledged, if there is any.
    pub fn push_request(&self) -> Option<PushRequest> {
        let mutations: Vec<Mutation> = self
            .durable
            .pending
            .iter()
            .filter(|pend| !pend.acked)
            .map(|pend| pend.mutation.clone())
            .collect();
        (!mutations.is_empty()).then(|| PushRequest {
            device: self.device.clone(),
            instance: self.durable.instance.clone(),
            mutations,
        })
    }

    /// A push succeeded: acknowledge each result, and mark refused mutations failed.
    pub fn on_push_response(&mut self, instance: &str, response: &PushResponse, local_now_ms: i64) {
        self.observe(response.server_time_ms, local_now_ms);
        if instance != self.durable.instance {
            return;
        }
        for result in &response.results {
            let found = self
                .durable
                .pending
                .iter_mut()
                .find(|pend| pend.mutation.id == result.id);
            if let Some(pend) = found {
                pend.acked = true;
                pend.failed = matches!(
                    result.status,
                    MutationStatus::Invalid | MutationStatus::Unsupported
                );
            }
        }
    }

    /// A push was refused: an instance conflict moves to a new instance, a gap resends later.
    pub fn on_push_error(&mut self, instance: &str, error: &ServerError, spare_instance: String) {
        if instance == self.durable.instance && *error == ServerError::InstanceConflict {
            self.rotations += 1;
            self.rotate_instance(spare_instance);
        }
    }

    fn rotate_instance(&mut self, instance: String) {
        self.durable.instance = instance;
        self.renumber(Vec::new());
    }

    /// Moves every pending mutation to ids from 1 behind `leading`; a refusal is forgotten because a restored server may have refused for lack of state.
    fn renumber(&mut self, leading: Vec<Pend>) {
        let kept: Vec<Pend> = self.durable.pending.drain(..).collect();
        let mut renumbered = Vec::new();
        for (index, mut pend) in leading.into_iter().chain(kept).enumerate() {
            pend.mutation.id = index as i64 + 1;
            pend.acked = false;
            pend.failed = false;
            renumbered.push(pend);
        }
        self.durable.next_id = renumbered.len() as i64 + 1;
        self.durable.pending = renumbered;
    }

    fn reseed_pend(&mut self, local_now_ms: i64) -> Option<Pend> {
        let base = &self.durable.base;
        let user = self.caller.user.clone();
        let owned: BTreeSet<&String> = base
            .playlists
            .values()
            .filter(|p| p.owner == user)
            .map(|p| &p.id)
            .collect();
        let mut values: Vec<EntityValue> = Vec::new();
        values.extend(
            base.playlists
                .values()
                .filter(|p| p.owner == user)
                .cloned()
                .map(EntityValue::Playlist),
        );
        values.extend(
            base.entries
                .values()
                .filter(|e| owned.contains(&e.playlist))
                .cloned()
                .map(EntityValue::Entry),
        );
        values.extend(base.loves.values().cloned().map(EntityValue::Love));
        values.extend(base.ratings.values().cloned().map(EntityValue::Rating));
        values.extend(base.scalars.values().cloned().map(EntityValue::Scalar));
        values.extend(base.sessions.values().cloned().map(EntityValue::Session));
        if values.is_empty() {
            return None;
        }
        let entities: Vec<Entity> = values.iter().map(EntityValue::to_entity).collect();
        let stamp = self.stamp(local_now_ms);
        Some(Pend {
            mutation: Mutation {
                id: 0,
                name: "state.reseed".to_owned(),
                stamp,
                args: json!({ "entities": entities }),
            },
            failed: false,
            acked: false,
        })
    }

    fn reset(&mut self, incarnation: Option<String>, instance: String, local_now_ms: i64) {
        self.resets += 1;
        let reseed = self.reseed_pend(local_now_ms);
        self.durable.base = Store::default();
        self.durable.instance = instance;
        self.durable.incarnation = incarnation;
        self.durable.cursor = 0;
        self.renumber(reseed.into_iter().collect());
    }

    /// A pull succeeded. Stale answers are ignored; a new incarnation resets; otherwise the changes land in the base.
    pub fn on_pull_response(
        &mut self,
        context: &PullContext,
        response: &PullResponse,
        local_now_ms: i64,
        spare_instance: String,
    ) {
        self.observe(response.server_time_ms, local_now_ms);
        let current =
            context.instance == self.durable.instance && context.since == self.durable.cursor;
        if !current {
            return;
        }
        match &self.durable.incarnation {
            Some(known) if *known != response.incarnation => {
                let incarnation = Some(response.incarnation.clone());
                self.reset(incarnation, spare_instance, local_now_ms);
                return;
            }
            _ => self.durable.incarnation = Some(response.incarnation.clone()),
        }
        for change in &response.changes {
            let entity = Entity {
                kind: change.kind,
                id: change.id.clone(),
                value: change.value.clone(),
            };
            if let Ok(value) = entity.decode() {
                self.durable.base.put(value);
            }
        }
        let cursor = match (response.more, response.changes.last()) {
            (true, Some(last)) => last.seq,
            _ => response.head,
        };
        if cursor < self.durable.cursor {
            self.cursor_regressions += 1;
        }
        self.durable.cursor = cursor;
        if !response.more {
            let confirmed = response.last_mutation_id;
            let (done, kept): (Vec<Pend>, Vec<Pend>) = std::mem::take(&mut self.durable.pending)
                .into_iter()
                .partition(|pend| pend.acked && pend.mutation.id <= confirmed);
            self.durable.pending = kept;
            self.retired
                .extend(done.into_iter().map(|pend| pend.mutation));
        }
    }

    /// A pull was refused: a cookie ahead of the server means its state was replaced.
    pub fn on_pull_error(
        &mut self,
        context: &PullContext,
        error: &ServerError,
        local_now_ms: i64,
        spare_instance: String,
    ) {
        let current =
            context.instance == self.durable.instance && context.since == self.durable.cursor;
        if current && *error == ServerError::CookieAhead {
            self.reset(None, spare_instance, local_now_ms);
        }
    }
}

fn reseed_key(entity: &EntityValue) -> (EntityKind, String) {
    match entity {
        EntityValue::Entry(entry) => (EntityKind::Playlist, entry.playlist.clone()),
        other => (other.kind(), other.id().to_owned()),
    }
}
