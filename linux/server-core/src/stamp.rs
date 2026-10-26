//! Hybrid stamps: `(wall_ms << 16) | counter`, compared as integers.

use serde::{Deserialize, Serialize};

const COUNTER_BITS: u32 = 16;
const COUNTER_MASK: i64 = 0xFFFF;
const MAX_WALL_MS: i64 = i64::MAX >> COUNTER_BITS;
const CLOCK_BEHIND_LIMIT_MS: i64 = 3_600_000;

/// A point in the total order every last-writer-wins decision uses.
#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
#[serde(transparent)]
pub struct Stamp(pub i64);

impl Stamp {
    /// The stamp older than every real write.
    pub const ZERO: Stamp = Stamp(0);

    /// Packs a wall clock reading and a 16 bit counter into one stamp.
    pub fn pack(wall_ms: i64, counter: u16) -> Stamp {
        Stamp((wall_ms.clamp(0, MAX_WALL_MS) << COUNTER_BITS) | i64::from(counter))
    }

    /// The stamp for a wall clock reading with the counter at zero.
    pub fn from_wall_ms(wall_ms: i64) -> Stamp {
        Stamp::pack(wall_ms, 0)
    }

    /// Splits a stamp back into its wall clock milliseconds and counter.
    pub fn unpack(self) -> (i64, u16) {
        (self.wall_ms(), (self.0 & COUNTER_MASK) as u16)
    }

    /// The wall clock milliseconds a stamp was made at.
    pub fn wall_ms(self) -> i64 {
        self.0 >> COUNTER_BITS
    }

    fn successor(self) -> Stamp {
        Stamp(self.0.saturating_add(1))
    }
}

/// A client's stamp source: monotone on its own, aligned to the server's
/// clock by the offset every response refreshes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientClock {
    last: Stamp,
    offset_ms: i64,
}

impl ClientClock {
    /// Resumes a clock from the last stamp it handed out and the offset it knew.
    pub fn new(last: Stamp, offset_ms: i64) -> Self {
        ClientClock { last, offset_ms }
    }

    /// The last stamp handed out, to persist with the write it stamped.
    pub fn last(&self) -> Stamp {
        self.last
    }

    /// The learned `server_time - local_time` offset in milliseconds.
    pub fn offset_ms(&self) -> i64 {
        self.offset_ms
    }

    /// Learns the offset from a response's `serverTimeMs` and the local time it arrived at.
    pub fn observe_server_time(&mut self, server_time_ms: i64, local_now_ms: i64) {
        self.offset_ms = server_time_ms.saturating_sub(local_now_ms);
    }

    /// The next stamp: `max(last + 1, (now + offset) << 16)`.
    pub fn next(&mut self, now_ms: i64) -> Stamp {
        let aligned = Stamp::from_wall_ms(now_ms.saturating_add(self.offset_ms));
        self.last = self.last.successor().max(aligned);
        self.last
    }
}

/// The server's hybrid logical clock, persisted as `server_hlc`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerClock {
    last: Stamp,
}

impl ServerClock {
    /// Resumes the clock from its persisted value.
    pub fn new(last: Stamp) -> Self {
        ServerClock { last }
    }

    /// The persisted value.
    pub fn last(&self) -> Stamp {
        self.last
    }

    /// A strictly increasing stamp: `max(now << 16, last + 1)`, stored.
    pub fn next(&mut self, now_ms: i64) -> Stamp {
        self.last = self.last.successor().max(Stamp::from_wall_ms(now_ms));
        self.last
    }

    /// The stamp a mutation is stored under: `min(client_stamp, self.next())`.
    pub fn store(&mut self, client_stamp: Stamp, now_ms: i64) -> Stamp {
        client_stamp.min(self.next(now_ms))
    }

    /// True when the wall clock is more than one hour behind the clock, so writes answer `503 clock_behind`.
    pub fn is_behind(&self, now_ms: i64) -> bool {
        self.last.wall_ms().saturating_sub(now_ms) > CLOCK_BEHIND_LIMIT_MS
    }
}
