//! The listen ledger of PROTOCOL.md section 8: which events of one second are
//! suppressed, as a pure function of the set of events in that second.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// One stored listen of the second being recomputed, with the keys the shared normalizer made.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecondEvent {
    /// The 24 hex character listen id.
    pub event_id: String,
    /// True when the player recorded the play itself rather than importing it.
    pub recorded: bool,
    /// The normalized title key.
    pub title_key: String,
    /// The normalized artist key.
    pub artist_key: String,
    /// The flag as stored.
    #[serde(default)]
    pub suppressed: bool,
}

/// An event whose `suppressed` flag must be rewritten, and so emitted as a change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FlagChange {
    /// The event whose flag changed.
    pub event_id: String,
    /// The recomputed flag.
    pub suppressed: bool,
}

fn priority_order(events: &[SecondEvent]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..events.len()).collect();
    order.sort_by(|&a, &b| {
        let (a, b) = (&events[a], &events[b]);
        (!a.recorded, &a.event_id).cmp(&(!b.recorded, &b.event_id))
    });
    order
}

/// The verdict per event, in input order: true when the event is suppressed.
///
/// Walks the events recorded first, then by event id; an event is kept unless
/// a kept event has its title key, or it is not recorded and a kept recorded
/// event has its artist key. The result does not depend on the input order.
pub fn suppressed_flags(events: &[SecondEvent]) -> Vec<bool> {
    let mut suppressed = vec![true; events.len()];
    let mut kept_titles: HashSet<&str> = HashSet::new();
    let mut recorded_artists: HashSet<&str> = HashSet::new();
    for index in priority_order(events) {
        let event = &events[index];
        let same_title = kept_titles.contains(event.title_key.as_str());
        let same_artist = !event.recorded && recorded_artists.contains(event.artist_key.as_str());
        if same_title || same_artist {
            continue;
        }
        suppressed[index] = false;
        kept_titles.insert(&event.title_key);
        if event.recorded {
            recorded_artists.insert(&event.artist_key);
        }
    }
    suppressed
}

/// The events of a second whose stored flag differs from the recomputed one, ordered by event id.
pub fn recompute_second(events: &[SecondEvent]) -> Vec<FlagChange> {
    let mut changes: Vec<FlagChange> = events
        .iter()
        .zip(suppressed_flags(events))
        .filter(|(event, flag)| event.suppressed != *flag)
        .map(|(event, flag)| FlagChange {
            event_id: event.event_id.clone(),
            suppressed: flag,
        })
        .collect();
    changes.sort_by(|a, b| a.event_id.cmp(&b.event_id));
    changes
}
