//! Who is connected to the live channel, and the in-memory state it shares:
//! the latest presence of each device and the per-device command budget.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::sync::{mpsc, watch};

use crate::shutdown::StopSignal;

const OUTBOX_DEPTH: usize = 64;
const OFFLINE_STATE: &str = "offline";

/// The intervals and limits of a connection; the defaults are PROTOCOL.md section 9.
#[derive(Clone, Copy, Debug)]
pub struct LiveTiming {
    /// How often the server pings.
    pub ping: Duration,
    /// How long a connection may stay silent before it is closed.
    pub silence: Duration,
    /// The longest a token is trusted without being checked again.
    pub revalidate: Duration,
    /// The window the command budget is counted over.
    pub command_window: Duration,
    /// Commands a device may send per window.
    pub command_limit: usize,
}

impl Default for LiveTiming {
    fn default() -> Self {
        Self {
            ping: Duration::from_secs(25),
            silence: Duration::from_secs(75),
            revalidate: Duration::from_secs(30),
            command_window: Duration::from_secs(1),
            command_limit: 5,
        }
    }
}

/// Something for a connection's task to write to its socket.
#[derive(Debug)]
pub(super) enum Outbound {
    Text(String),
    Close { code: u16, reason: &'static str },
}

struct Entry {
    id: u64,
    outbox: mpsc::Sender<Outbound>,
}

#[derive(Default)]
struct UserLive {
    devices: BTreeMap<String, Vec<Entry>>,
    presence: BTreeMap<String, String>,
    sent: HashMap<String, VecDeque<Instant>>,
}

struct Inner {
    users: Mutex<HashMap<String, UserLive>>,
    timing: Mutex<LiveTiming>,
    stop: watch::Sender<bool>,
    next_id: AtomicU64,
}

/// The shared registry of live connections. Clones share it.
#[derive(Clone)]
pub struct LiveHub {
    inner: Arc<Inner>,
}

impl Default for LiveHub {
    fn default() -> Self {
        Self::new()
    }
}

/// One connection's place in the hub; dropping it removes the connection.
pub(super) struct Registration {
    hub: LiveHub,
    user: String,
    device: String,
    id: u64,
    /// What the hub wants written to the socket.
    pub outbox: mpsc::Receiver<Outbound>,
    /// The presence frames of the user's other devices, to replay to the new socket.
    pub replay: Vec<String>,
}

impl Drop for Registration {
    fn drop(&mut self) {
        self.hub.unregister(&self.user, &self.device, self.id);
    }
}

fn presence_frame(device: &str, state: &str, at: i64) -> String {
    json!({ "t": "presence", "device": device, "state": state, "ref": Value::Null, "positionMs": 0, "at": at }).to_string()
}

impl LiveHub {
    /// An empty hub with the default timing.
    pub fn new() -> Self {
        let (stop, _) = watch::channel(false);
        Self {
            inner: Arc::new(Inner {
                users: Mutex::new(HashMap::new()),
                timing: Mutex::new(LiveTiming::default()),
                stop,
                next_id: AtomicU64::new(0),
            }),
        }
    }

    fn users(&self) -> MutexGuard<'_, HashMap<String, UserLive>> {
        self.inner.users.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The timing connections opened from now on use.
    pub fn timing(&self) -> LiveTiming {
        *self.inner.timing.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Replaces the timing for connections opened from now on.
    pub fn set_timing(&self, timing: LiveTiming) {
        *self.inner.timing.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = timing;
    }

    /// Receives `true` once the server is stopping.
    pub(super) fn stopping(&self) -> watch::Receiver<bool> {
        self.inner.stop.subscribe()
    }

    /// Tells every connection to close with a going-away code.
    pub fn shutdown(&self) {
        self.inner.stop.send_replace(true);
    }

    /// Closes every socket with a going-away code once `stop` is raised.
    pub fn shutdown_on(&self, stop: StopSignal) -> tokio::task::JoinHandle<()> {
        let hub = self.clone();
        tokio::spawn(async move {
            stop.raised().await;
            hub.shutdown();
        })
    }

    /// How many sockets are open.
    pub fn connection_count(&self) -> usize {
        self.users().values().map(|live| live.devices.values().map(Vec::len).sum::<usize>()).sum()
    }

    pub(super) fn register(&self, user: &str, device: &str) -> Registration {
        let (outbox, receiver) = mpsc::channel(OUTBOX_DEPTH);
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let mut users = self.users();
        let live = users.entry(user.to_owned()).or_default();
        let replay = live
            .presence
            .iter()
            .filter(|(other, _)| other.as_str() != device)
            .map(|(_, frame)| frame.clone())
            .collect();
        live.devices.entry(device.to_owned()).or_default().push(Entry { id, outbox });
        Registration {
            hub: self.clone(),
            user: user.to_owned(),
            device: device.to_owned(),
            id,
            outbox: receiver,
            replay,
        }
    }

    fn unregister(&self, user: &str, device: &str, id: u64) {
        let mut users = self.users();
        let Some(live) = users.get_mut(user) else {
            return;
        };
        if let Some(entries) = live.devices.get_mut(device) {
            entries.retain(|entry| entry.id != id);
            if entries.is_empty() {
                live.devices.remove(device);
            }
        }
        if !live.devices.contains_key(device) {
            live.sent.remove(device);
            if live.presence.remove(device).is_some() {
                let frame = presence_frame(device, OFFLINE_STATE, now_ms());
                Self::fan_out(live, device, &frame);
            }
        }
        if live.devices.is_empty() {
            users.remove(user);
        }
    }

    fn fan_out(live: &UserLive, except: &str, frame: &str) {
        for (device, entries) in &live.devices {
            if device == except {
                continue;
            }
            for entry in entries {
                let _ = entry.outbox.try_send(Outbound::Text(frame.to_owned()));
            }
        }
    }

    /// Stores `frame` as the device's latest presence and relays it to the user's other devices.
    pub(super) fn publish_presence(&self, user: &str, device: &str, frame: String) {
        let mut users = self.users();
        let live = users.entry(user.to_owned()).or_default();
        Self::fan_out(live, device, &frame);
        live.presence.insert(device.to_owned(), frame);
    }

    /// Hands `frame` to the user's device `to`; false when it has no open socket or cannot take it now.
    pub(super) fn relay_command(&self, user: &str, to: &str, frame: String) -> bool {
        let users = self.users();
        let Some(entries) = users.get(user).and_then(|live| live.devices.get(to)) else {
            return false;
        };
        let mut delivered = false;
        for entry in entries {
            delivered |= entry.outbox.try_send(Outbound::Text(frame.clone())).is_ok();
        }
        delivered
    }

    /// Counts a command against the device's budget; false when the budget for the window is spent.
    pub(super) fn allow_command(&self, user: &str, device: &str, now: Instant) -> bool {
        let timing = self.timing();
        let mut users = self.users();
        let Some(live) = users.get_mut(user) else {
            return false;
        };
        let sent = live.sent.entry(device.to_owned()).or_default();
        while sent.front().is_some_and(|at| now.duration_since(*at) >= timing.command_window) {
            sent.pop_front();
        }
        if sent.len() >= timing.command_limit {
            return false;
        }
        sent.push_back(now);
        true
    }

    /// Closes every socket of `device`, as when it is revoked.
    pub fn close_device(&self, device: &str) {
        let users = self.users();
        for entries in users.values().filter_map(|live| live.devices.get(device)) {
            for entry in entries {
                let _ = entry.outbox.try_send(Outbound::Close { code: super::live::CLOSE_POLICY, reason: "revoked" });
            }
        }
    }
}

/// The current time in Unix milliseconds.
pub(super) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(outbound: Outbound) -> String {
        match outbound {
            Outbound::Text(text) => text,
            other => panic!("expected text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn presence_reaches_the_users_other_devices_and_is_replayed() {
        let hub = LiveHub::new();
        let mut phone = hub.register("u", "phone");
        hub.publish_presence("u", "phone", "P1".to_owned());
        hub.publish_presence("u", "phone", "P2".to_owned());
        let mut laptop = hub.register("u", "laptop");
        assert_eq!(laptop.replay, vec!["P2".to_owned()]);
        assert!(phone.outbox.try_recv().is_err());
        hub.publish_presence("u", "laptop", "L1".to_owned());
        assert_eq!(text(phone.outbox.try_recv().unwrap()), "L1");
        assert!(laptop.outbox.try_recv().is_err());
    }

    #[tokio::test]
    async fn another_users_devices_hear_nothing() {
        let hub = LiveHub::new();
        let mut stranger = hub.register("other", "tablet");
        let _phone = hub.register("u", "phone");
        hub.publish_presence("u", "phone", "P".to_owned());
        assert!(stranger.outbox.try_recv().is_err());
        assert!(!hub.relay_command("u", "tablet", "C".to_owned()));
    }

    #[tokio::test]
    async fn a_device_going_offline_is_announced_once_its_last_socket_closes() {
        let hub = LiveHub::new();
        let mut laptop = hub.register("u", "laptop");
        let first = hub.register("u", "phone");
        let second = hub.register("u", "phone");
        hub.publish_presence("u", "phone", "P".to_owned());
        assert_eq!(text(laptop.outbox.try_recv().unwrap()), "P");
        drop(first);
        assert!(laptop.outbox.try_recv().is_err());
        drop(second);
        let frame: Value = serde_json::from_str(&text(laptop.outbox.try_recv().unwrap())).unwrap();
        assert_eq!((frame["device"].as_str(), frame["state"].as_str()), (Some("phone"), Some("offline")));
        assert_eq!(hub.connection_count(), 1);
    }

    #[tokio::test]
    async fn the_command_budget_is_per_device_and_refills() {
        let hub = LiveHub::new();
        let _phone = hub.register("u", "phone");
        let _tablet = hub.register("u", "tablet");
        let start = Instant::now();
        let spent = (0..8).filter(|_| hub.allow_command("u", "phone", start)).count();
        assert_eq!(spent, 5);
        assert!(hub.allow_command("u", "tablet", start));
        assert!(hub.allow_command("u", "phone", start + Duration::from_millis(1001)));
    }
}
