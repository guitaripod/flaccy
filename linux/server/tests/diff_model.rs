//! The SQLite store against the in-memory reference server: the same scripted
//! pushes and pulls must give the same answers, change for change.

mod common;

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use flaccy_server::dbthread::Durability;
use flaccy_server::security::{Clock, DeviceId, Principal, Role, UserId};
use flaccy_server::sync::{PullError, PushError, Store};
use flaccy_server_core::apply::Caller;
use flaccy_server_core::digest::canonical_json;
use flaccy_server_core::sim::rng::Rng;
use flaccy_server_core::sim::scenario::{pressure_seed, random_mutation};
use flaccy_server_core::sim::server::{ServerError, ServerModel};
use flaccy_server_core::stamp::ClientClock;
use flaccy_server_core::wire::{Mutation, MutationStatus, PullResponse, PushRequest, PushResponse};
use serde_json::json;

use common::TempDir;

const SCENARIOS: u64 = 300;
const STEPS: usize = 60;
const BASE_TIME_MS: i64 = 1_790_000_000_000;
const USER: &str = "user";
const PULL_LIMITS: [usize; 6] = [1, 2, 3, 5, 10, 1000];

struct Device {
    id: String,
    instance: String,
    next_id: i64,
    clock: ClientClock,
    sent: Vec<Mutation>,
    cursor: i64,
    skew_ms: i64,
}

impl Device {
    fn new(index: usize, rng: &mut Rng) -> Self {
        Device {
            id: format!("device{index}"),
            instance: rng.id(),
            next_id: 1,
            clock: ClientClock::default(),
            sent: Vec::new(),
            cursor: 0,
            skew_ms: rng.between(-3_000, 7_200_000),
        }
    }

    fn principal(&self) -> Principal {
        Principal {
            user: UserId(USER.to_owned()),
            role: Role::Member,
            device: Some(DeviceId(self.id.clone())),
        }
    }

    fn caller(&self) -> Caller {
        Caller::member(USER, &self.id)
    }

    fn request(&self, mutations: Vec<Mutation>) -> PushRequest {
        PushRequest {
            device: self.id.clone(),
            instance: self.instance.clone(),
            mutations,
        }
    }

    fn rotate(&mut self, rng: &mut Rng) {
        self.instance = rng.id();
        self.next_id = 1;
        self.sent.clear();
    }
}

#[derive(Default)]
struct Coverage {
    pushed: u32,
    conflicts: u32,
    gaps: u32,
    behind: u32,
    cookie_ahead: u32,
    pages_with_more: u32,
    rebalances: u32,
    applied: u32,
}

impl Coverage {
    fn absorb(&mut self, other: &Coverage) {
        self.pushed += other.pushed;
        self.conflicts += other.conflicts;
        self.gaps += other.gaps;
        self.behind += other.behind;
        self.cookie_ahead += other.cookie_ahead;
        self.pages_with_more += other.pages_with_more;
        self.rebalances += other.rebalances;
        self.applied += other.applied;
    }
}

struct Scenario {
    seed: u64,
    seen: Coverage,
    rng: Rng,
    now: Arc<AtomicI64>,
    model: ServerModel,
    store: Store,
    devices: Vec<Device>,
    pressure: bool,
    step: usize,
}

fn canonical<T: serde::Serialize>(value: &T) -> String {
    canonical_json(&serde_json::to_value(value).unwrap())
}

fn same_push_error(model: &ServerError, mine: &PushError) -> bool {
    matches!(
        (model, mine),
        (ServerError::InstanceConflict, PushError::InstanceConflict)
            | (ServerError::ClockBehind, PushError::ClockBehind)
    ) || matches!((model, mine), (ServerError::MutationGap { have: a }, PushError::MutationGap { have: b }) if a == b)
}

impl Scenario {
    async fn new(seed: u64, dir: &TempDir) -> Self {
        let mut rng = Rng::new(seed);
        let now = Arc::new(AtomicI64::new(BASE_TIME_MS));
        let clock: Clock = {
            let now = now.clone();
            Arc::new(move || now.load(Ordering::SeqCst))
        };
        let incarnation = rng.id();
        let store = Store::open_with(&dir.file(&format!("s{seed}.sqlite")), incarnation.clone(), clock, Durability::Normal)
            .await
            .unwrap();
        let count = 2 + rng.below(3);
        let devices = (0..count).map(|index| Device::new(index, &mut rng)).collect();
        let pressure = rng.chance(20);
        Scenario {
            seed,
            seen: Coverage::default(),
            now,
            model: ServerModel::new(incarnation),
            store,
            devices,
            pressure,
            rng,
            step: 0,
        }
    }

    fn now(&self) -> i64 {
        self.now.load(Ordering::SeqCst)
    }

    fn fail(&self, what: &str, model: &str, mine: &str) -> ! {
        panic!("seed {} step {}: {what}\nmodel: {model}\nstore: {mine}", self.seed, self.step);
    }

    fn make_mutation(&mut self, device: usize) -> Mutation {
        let local_now = self.now() + self.devices[device].skew_ms;
        let (mut name, mut args) = random_mutation(&mut self.rng, &self.model.store, self.pressure);
        if name == "playlist.setVisibility" {
            args["visibility"] = json!("private");
        }
        if name == "playlist.setCover" {
            name = "playlist.clearCover";
            args = json!({ "id": args["id"] });
        }
        let target = &mut self.devices[device];
        let mutation = Mutation {
            id: target.next_id,
            name: name.to_owned(),
            stamp: target.clock.next(local_now),
            args,
        };
        target.next_id += 1;
        target.sent.push(mutation.clone());
        mutation
    }

    fn pressure_seed_mutation(&mut self, device: usize) -> Mutation {
        let local_now = self.now() + self.devices[device].skew_ms;
        let target = &mut self.devices[device];
        let mutation = Mutation {
            id: target.next_id,
            name: "state.reseed".to_owned(),
            stamp: target.clock.next(local_now),
            args: pressure_seed(),
        };
        target.next_id += 1;
        target.sent.push(mutation.clone());
        mutation
    }

    async fn push_both(&mut self, device: usize, mutations: Vec<Mutation>) {
        let request = self.devices[device].request(mutations);
        let now = self.now();
        let caller = self.devices[device].caller();
        let model = self.model.push(&caller, &request, now);
        let principal = self.devices[device].principal();
        let mine = self.store.push(&principal, request.clone(), None).await;
        match (&model, &mine) {
            (Ok(expected), Ok(actual)) => {
                self.same_push(expected, actual, &request);
                self.seen.pushed += 1;
                self.seen.applied += expected.results.iter().filter(|result| result.status == MutationStatus::Applied).count() as u32;
            }
            (Err(expected), Err(actual)) if same_push_error(expected, actual) => self.count_refusal(expected),
            _ => self.fail("push outcomes differ", &format!("{model:?}"), &format!("{mine:?}")),
        }
    }

    fn count_refusal(&mut self, refusal: &ServerError) {
        match refusal {
            ServerError::InstanceConflict => self.seen.conflicts += 1,
            ServerError::MutationGap { .. } => self.seen.gaps += 1,
            ServerError::ClockBehind => self.seen.behind += 1,
            ServerError::CookieAhead => self.seen.cookie_ahead += 1,
        }
    }

    fn same_push(&self, expected: &PushResponse, actual: &PushResponse, request: &PushRequest) {
        if canonical(expected) != canonical(actual) {
            let sent = canonical(request);
            self.fail(&format!("push results differ for {sent}"), &canonical(expected), &canonical(actual));
        }
    }

    async fn new_mutations(&mut self, device: usize, count: usize) {
        let mut mutations = Vec::new();
        if self.pressure && self.devices[device].next_id == 1 && device == 0 {
            mutations.push(self.pressure_seed_mutation(device));
        }
        for _ in 0..count {
            mutations.push(self.make_mutation(device));
        }
        self.push_both(device, mutations).await;
    }

    async fn retry(&mut self, device: usize) {
        let sent = &self.devices[device].sent;
        let from = sent.len().saturating_sub(1 + self.rng.below(6));
        let replay = sent[from..].to_vec();
        if replay.is_empty() {
            return;
        }
        let mut mutations = replay;
        if self.rng.chance(50) {
            let extra = self.make_mutation(device);
            mutations.push(extra);
        }
        self.push_both(device, mutations).await;
    }

    async fn gap(&mut self, device: usize) {
        let mut mutation = self.make_mutation(device);
        mutation.id += 1;
        self.devices[device].next_id -= 1;
        self.devices[device].sent.pop();
        self.push_both(device, vec![mutation]).await;
    }

    async fn conflict(&mut self, device: usize) {
        let Some(old) = self.devices[device].sent.first().cloned() else {
            return;
        };
        let mut changed = old;
        changed.args = json!({ "altered": self.rng.id() });
        changed.name = "scalar.set".to_owned();
        self.push_both(device, vec![changed]).await;
    }

    async fn behind(&mut self, device: usize) {
        let real = self.now();
        self.now.store(real - 2 * 3_600_000, Ordering::SeqCst);
        let mutation = self.make_mutation(device);
        self.devices[device].next_id -= 1;
        self.devices[device].sent.pop();
        self.push_both(device, vec![mutation]).await;
        self.now.store(real, Ordering::SeqCst);
    }

    async fn pull_both(&mut self, device: usize) {
        let head = self.model.head();
        let since = match self.rng.below(10) {
            0 => 0,
            1 => head + 1 + self.rng.below(5) as i64,
            _ => self.devices[device].cursor,
        };
        let limit = *self.rng.pick(&PULL_LIMITS);
        let instance = if self.rng.chance(10) { "unknown-instance".to_owned() } else { self.devices[device].instance.clone() };
        let now = self.now();
        let model = self.model.pull(&self.devices[device].id, &instance, since, limit, now);
        let principal = self.devices[device].principal();
        let mine = self.store.pull(&principal, &instance, since, limit, None).await;
        match (&model, &mine) {
            (Ok(expected), Ok(actual)) => self.same_pull(device, since, expected, actual),
            (Err(ServerError::CookieAhead), Err(PullError::CookieAhead { .. })) => self.seen.cookie_ahead += 1,
            _ => self.fail(&format!("pull outcomes differ at since {since}"), &format!("{model:?}"), &format!("{mine:?}")),
        }
    }

    fn same_pull(&mut self, device: usize, since: i64, expected: &PullResponse, actual: &PullResponse) {
        if canonical(expected) != canonical(actual) {
            self.fail(&format!("pull differs at since {since}"), &canonical(expected), &canonical(actual));
        }
        if expected.more {
            self.seen.pages_with_more += 1;
        }
        let cursor = if expected.more {
            expected.changes.last().map_or(since, |change| change.seq)
        } else {
            expected.head
        };
        self.devices[device].cursor = cursor;
    }

    async fn step(&mut self) {
        self.step += 1;
        let advance = self.rng.between(1, 800);
        self.now.fetch_add(advance, Ordering::SeqCst);
        let device = self.rng.below(self.devices.len());
        match self.rng.below(100) {
            0..=49 => {
                let count = 1 + self.rng.below(6);
                self.new_mutations(device, count).await;
            }
            50..=59 => self.retry(device).await,
            60..=64 => self.gap(device).await,
            65..=68 => self.conflict(device).await,
            69..=70 => self.behind(device).await,
            71..=74 => {
                let mut rng = self.rng.clone();
                self.devices[device].rotate(&mut rng);
                self.rng = rng;
            }
            _ => self.pull_both(device).await,
        }
    }

    async fn drain(&mut self) {
        for device in 0..self.devices.len() {
            self.devices[device].cursor = 0;
            for _ in 0..12 {
                self.pull_both(device).await;
            }
        }
    }
}

fn remove_database(dir: &TempDir, seed: u64) {
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(dir.file(&format!("s{seed}.sqlite{suffix}")));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_sqlite_store_answers_exactly_like_the_reference_server() {
    let dir = TempDir::new("diff");
    let mut total = Coverage::default();
    for seed in 0..SCENARIOS {
        let mut scenario = Scenario::new(seed, &dir).await;
        for _ in 0..STEPS {
            scenario.step().await;
        }
        scenario.drain().await;
        scenario.seen.rebalances = scenario.model.rebalances;
        total.absorb(&scenario.seen);
        scenario.store.close().await.unwrap();
        remove_database(&dir, seed);
    }
    assert!(total.pushed > 3000 && total.applied > 3000, "pushes {} applied {}", total.pushed, total.applied);
    assert!(total.conflicts > 50 && total.gaps > 50 && total.behind > 10, "refusals did not happen enough");
    assert!(total.cookie_ahead > 20 && total.pages_with_more > 200, "pull edge cases did not happen enough");
    assert!(total.rebalances > 0, "no position rewrite happened");
}
