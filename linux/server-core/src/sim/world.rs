//! The seeded world: clients, a server and a hostile network, driven until
//! everything is quiet and then held to the protocol's invariants.

use super::client::{ClientModel, Durable, PullContext};
use super::oracle::Oracle;
use super::rng::Rng;
use super::scenario::{pressure_seed, random_mutation};
use super::server::{ServerError, ServerModel, Snapshot};
use crate::digest::arg_hash;
use crate::wire::{PullResponse, PushRequest, PushResponse};

const BASE_TIME_MS: i64 = 1_790_000_000_000;
const SETTLE_ROUNDS: usize = 80;
const PULL_LIMITS: [usize; 6] = [2, 3, 5, 10, 50, 1000];
const USER: &str = "user";

/// What a run exercised, so tests can prove the hazards really happened.
#[derive(Clone, Debug, Default)]
pub struct Stats {
    /// Server restores performed.
    pub restores: u32,
    /// Client resets after a new incarnation or cookie_ahead.
    pub resets: u32,
    /// Client moves to a new instance after an instance conflict.
    pub rotations: u32,
    /// How many position rewrites the server performed.
    pub rebalances: u32,
    /// Messages the network dropped.
    pub lost_messages: u32,
    /// Messages the network delivered twice.
    pub duplicated_messages: u32,
    /// Client installs wiped.
    pub reinstalls: u32,
    /// Clients rolled back to an older backup.
    pub stale_restores: u32,
}

impl Stats {
    /// Adds another run's counters.
    pub fn absorb(&mut self, other: &Stats) {
        self.restores += other.restores;
        self.resets += other.resets;
        self.rotations += other.rotations;
        self.rebalances += other.rebalances;
        self.lost_messages += other.lost_messages;
        self.duplicated_messages += other.duplicated_messages;
        self.reinstalls += other.reinstalls;
        self.stale_restores += other.stale_restores;
    }
}

enum Body {
    PushRequest(PushRequest),
    PullRequest { limit: usize },
    PushAnswer(Result<PushResponse, ServerError>),
    PullAnswer(Result<PullResponse, ServerError>),
}

struct Message {
    client: usize,
    generation: u32,
    instance: String,
    since: i64,
    body: Body,
}

struct Slot {
    client: ClientModel,
    online: bool,
    generation: u32,
    skew_ms: i64,
    backup: Option<Durable>,
}

struct World {
    rng: Rng,
    now_ms: i64,
    server: ServerModel,
    slots: Vec<Slot>,
    net: Vec<Message>,
    oracle: Oracle,
    snapshot: Option<Snapshot>,
    pressure: bool,
    allow_reinstall: bool,
    allow_stale: bool,
    reliable: bool,
    lost_state: bool,
    violation: Option<String>,
    stats: Stats,
}

impl World {
    fn new(seed: u64) -> Self {
        let mut rng = Rng::new(seed);
        let server = ServerModel::new(rng.id());
        let count = 2 + rng.below(3);
        let slots = (0..count)
            .map(|index| {
                let skewed = rng.chance(40);
                let skew_ms = if skewed {
                    rng.between(-7_200_000, 172_800_000)
                } else {
                    rng.between(-2_000, 2_000)
                };
                Slot {
                    client: ClientModel::new(
                        &format!("device{index}"),
                        USER,
                        rng.id(),
                        server.incarnation.clone(),
                    ),
                    online: true,
                    generation: 0,
                    skew_ms,
                    backup: None,
                }
            })
            .collect();
        let pressure = rng.chance(20);
        let allow_reinstall = rng.chance(30);
        let allow_stale = rng.chance(30);
        let mut world = World {
            rng,
            now_ms: BASE_TIME_MS,
            server,
            slots,
            net: Vec::new(),
            oracle: Oracle::default(),
            snapshot: None,
            pressure,
            allow_reinstall,
            allow_stale,
            reliable: false,
            lost_state: false,
            violation: None,
            stats: Stats::default(),
        };
        if pressure {
            world.slots[0]
                .client
                .record("state.reseed", pressure_seed(), BASE_TIME_MS);
        }
        world
    }

    fn local_now(&self, index: usize) -> i64 {
        self.now_ms + self.slots[index].skew_ms
    }

    fn send(&mut self, client: usize, body: Body, instance: String, since: i64) {
        let generation = self.slots[client].generation;
        self.net.push(Message {
            client,
            generation,
            instance,
            since,
            body,
        });
    }

    fn sync(&mut self, index: usize) {
        let client = &self.slots[index].client;
        let instance = client.durable.instance.clone();
        let since = client.durable.cursor;
        let push = client.push_request();
        let limit = *self.rng.pick(&PULL_LIMITS);
        let pull_first = !self.reliable && self.rng.chance(30);
        if pull_first {
            self.send(index, Body::PullRequest { limit }, instance.clone(), since);
        }
        if let Some(request) = push {
            self.send(index, Body::PushRequest(request), instance.clone(), since);
        }
        if !pull_first && (self.reliable || self.rng.chance(80)) {
            self.send(index, Body::PullRequest { limit }, instance, since);
        }
    }

    fn user_action(&mut self, index: usize) {
        let crash_before = self.rng.chance(3);
        if !crash_before {
            let visible = self.slots[index].client.visible();
            let (name, args) = random_mutation(&mut self.rng, &visible, self.pressure);
            let local_now = self.local_now(index);
            self.slots[index].client.record(name, args, local_now);
        }
        if crash_before || self.rng.chance(3) {
            self.crash(index);
        }
    }

    fn crash(&mut self, index: usize) {
        let slot = &mut self.slots[index];
        slot.generation += 1;
        slot.client.crash();
    }

    fn deliver(&mut self, message: Message) {
        match message.body {
            Body::PushRequest(ref request) => {
                let caller = self.slots[message.client].client.caller.clone();
                let answer = self.server.push(&caller, request, self.now_ms);
                self.answer(&message, Body::PushAnswer(answer));
            }
            Body::PullRequest { limit } => {
                let device = self.slots[message.client].client.device.clone();
                let answer = self.server.pull(
                    &device,
                    &message.instance,
                    message.since,
                    limit,
                    self.now_ms,
                );
                self.answer(&message, Body::PullAnswer(answer));
            }
            Body::PushAnswer(ref answer) => self.receive_push(&message, answer),
            Body::PullAnswer(ref answer) => self.receive_pull(&message, answer),
        }
        self.oracle.absorb(&self.server.journal);
        self.audit_retirements();
    }

    fn audit_retirements(&mut self) {
        for slot in &mut self.slots {
            for mutation in slot.client.retired.drain(..) {
                let hash = arg_hash(&mutation.name, &mutation.args);
                if !self.server.seen.contains(&hash) && self.violation.is_none() {
                    let who = &slot.client.device;
                    self.violation = Some(format!(
                        "{who} retired {} (id {}) the server never saw",
                        mutation.name, mutation.id
                    ));
                }
            }
        }
    }

    fn answer(&mut self, request: &Message, body: Body) {
        self.net.push(Message {
            client: request.client,
            generation: request.generation,
            instance: request.instance.clone(),
            since: request.since,
            body,
        });
    }

    fn receive_push(&mut self, message: &Message, answer: &Result<PushResponse, ServerError>) {
        let local_now = self.local_now(message.client);
        let spare = self.rng.id();
        let slot = &mut self.slots[message.client];
        if !slot.online || slot.generation != message.generation {
            return;
        }
        match answer {
            Ok(response) => slot
                .client
                .on_push_response(&message.instance, response, local_now),
            Err(error) => slot.client.on_push_error(&message.instance, error, spare),
        }
    }

    fn receive_pull(&mut self, message: &Message, answer: &Result<PullResponse, ServerError>) {
        let local_now = self.local_now(message.client);
        let spare = self.rng.id();
        let slot = &mut self.slots[message.client];
        if !slot.online || slot.generation != message.generation {
            return;
        }
        let context = PullContext {
            instance: message.instance.clone(),
            since: message.since,
        };
        match answer {
            Ok(response) => slot
                .client
                .on_pull_response(&context, response, local_now, spare),
            Err(error) => slot.client.on_pull_error(&context, error, local_now, spare),
        }
    }

    fn deliver_one(&mut self) {
        if self.net.is_empty() {
            return;
        }
        let index = if self.reliable {
            0
        } else {
            self.rng.below(self.net.len())
        };
        let message = self.net.remove(index);
        if !self.reliable && self.rng.chance(8) {
            self.stats.lost_messages += 1;
            return;
        }
        if !self.reliable && self.rng.chance(6) {
            self.stats.duplicated_messages += 1;
            self.net.push(clone_message(&message));
        }
        self.deliver(message);
    }

    fn disturb_client(&mut self, index: usize, roll: usize) {
        match roll {
            4..=5 => self.crash(index),
            6..=7 => self.slots[index].skew_ms -= self.rng.between(1_000, 3_600_000),
            8..=10 => self.take_backup(index),
            11 if self.allow_reinstall => self.reinstall(index),
            12..=13 if self.allow_stale => self.restore_backup(index),
            _ => self.slots[index].online = !self.slots[index].online,
        }
    }

    fn take_backup(&mut self, index: usize) {
        let slot = &mut self.slots[index];
        slot.backup = Some(slot.client.durable.clone());
    }

    fn reinstall(&mut self, index: usize) {
        let instance = self.rng.id();
        let incarnation = self.server.incarnation.clone();
        self.crash(index);
        self.slots[index].client.reinstall(instance, incarnation);
        self.lost_state = true;
        self.stats.reinstalls += 1;
    }

    fn restore_backup(&mut self, index: usize) {
        let Some(backup) = self.slots[index].backup.clone() else {
            return;
        };
        self.crash(index);
        self.slots[index].client.durable = backup;
        self.lost_state = true;
        self.stats.stale_restores += 1;
    }

    fn step(&mut self, step: usize, steps: usize, restore_run: bool) {
        self.now_ms += if self.rng.chance(5) {
            self.rng.between(1, 30_000)
        } else {
            self.rng.between(1, 1_500)
        };
        if restore_run && step == steps / 3 {
            self.snapshot = Some(self.server.snapshot());
        }
        if restore_run && step == 2 * steps / 3 {
            if let Some(snapshot) = self.snapshot.take() {
                self.server.restore(snapshot, self.rng.id());
                self.stats.restores += 1;
            }
        }
        let index = self.rng.below(self.slots.len());
        match self.rng.below(100) {
            0..=29 => self.user_action(index),
            30..=44 => {
                if self.slots[index].online {
                    self.sync(index);
                }
            }
            45..=81 => self.deliver_one(),
            roll => self.disturb_client(index, roll - 82),
        }
    }

    fn drain(&mut self) {
        while !self.net.is_empty() {
            self.deliver_one();
        }
    }

    fn is_calm(&self) -> bool {
        self.slots.iter().all(|slot| {
            slot.client.durable.pending.is_empty()
                && slot.client.durable.cursor == self.server.head()
        })
    }

    fn settle(&mut self) -> Result<(), String> {
        self.reliable = true;
        for slot in &mut self.slots {
            slot.online = true;
        }
        let mut calm = 0;
        for _ in 0..SETTLE_ROUNDS {
            self.now_ms += 1_000;
            for index in 0..self.slots.len() {
                self.sync(index);
            }
            self.drain();
            calm = if self.is_calm() { calm + 1 } else { 0 };
            if calm >= 2 {
                return Ok(());
            }
        }
        Err(format!(
            "the world never went quiet: {}",
            self.describe_clients()
        ))
    }

    fn describe_clients(&self) -> String {
        let head = self.server.head();
        let parts: Vec<String> = self
            .slots
            .iter()
            .map(|slot| {
                let durable = &slot.client.durable;
                let pending: Vec<String> = durable
                    .pending
                    .iter()
                    .map(|p| format!("{}:{}{}{}", p.mutation.id, p.mutation.name, if p.acked { "+" } else { "-" }, if p.failed { "!" } else { "" }))
                    .collect();
                format!("{} inc {:?} (server {}) resets {} rot {} cursor {}/{head} next {} pending {pending:?}", slot.client.device, durable.incarnation.as_deref().map(|s| &s[..4]), &self.server.incarnation[..4], slot.client.resets, slot.client.rotations, durable.cursor, durable.next_id)
            })
            .collect();
        parts.join("; ")
    }

    fn verify(&self) -> Result<(), String> {
        if let Some(violation) = &self.violation {
            return Err(violation.clone());
        }
        self.server.check_dense_ids()?;
        let server_entities = self.server.store.entities();
        for slot in &self.slots {
            let client = &slot.client;
            if client.cursor_regressions > 0 {
                return Err(format!("{} moved its cursor backwards", client.device));
            }
            let visible = client.visible().entities();
            if visible != server_entities {
                return Err(format!(
                    "{} diverged: {}",
                    client.device,
                    first_difference(&visible, &server_entities)
                ));
            }
        }
        let check_losses = !(self.stats.restores > 0 && self.lost_state);
        self.oracle.check(&self.server.store, check_losses)?;
        if let Some(entry) = self
            .server
            .store
            .entries
            .values()
            .find(|e| e.pos.len() > crate::position::MAX_POS_LEN)
        {
            return Err(format!("entry {} kept an over-long position", entry.id));
        }
        Ok(())
    }
}

fn clone_message(message: &Message) -> Message {
    let body = match &message.body {
        Body::PushRequest(r) => Body::PushRequest(r.clone()),
        Body::PullRequest { limit } => Body::PullRequest { limit: *limit },
        Body::PushAnswer(a) => Body::PushAnswer(a.clone()),
        Body::PullAnswer(a) => Body::PullAnswer(a.clone()),
    };
    Message {
        client: message.client,
        generation: message.generation,
        instance: message.instance.clone(),
        since: message.since,
        body,
    }
}

fn first_difference(visible: &[crate::model::Entity], server: &[crate::model::Entity]) -> String {
    let missing = server.iter().find(|entity| !visible.contains(entity));
    let extra = visible.iter().find(|entity| !server.contains(entity));
    format!("server has {missing:?}, client shows {extra:?}")
}

/// Runs one seeded world to quiescence and checks every invariant.
pub fn run_seed(seed: u64) -> Result<Stats, String> {
    let mut world = World::new(seed);
    let steps = 150 + world.rng.below(250);
    let restore_run = world.rng.chance(25);
    for step in 0..steps {
        world.step(step, steps, restore_run);
    }
    world.settle().map_err(|e| format!("seed {seed}: {e}"))?;
    let mut stats = world.stats.clone();
    stats.rebalances = world.server.rebalances;
    world
        .verify()
        .map_err(|e| format!("seed {seed}: {e} {stats:?}"))?;
    for slot in &world.slots {
        stats.resets += slot.client.resets;
        stats.rotations += slot.client.rotations;
    }
    Ok(stats)
}
