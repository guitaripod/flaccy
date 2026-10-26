use flaccy_server_core::ledger::{recompute_second, suppressed_flags, FlagChange, SecondEvent};
use proptest::prelude::*;
use std::collections::BTreeMap;

fn event(id: &str, recorded: bool, title: &str, artist: &str) -> SecondEvent {
    SecondEvent {
        event_id: id.to_owned(),
        recorded,
        title_key: title.to_owned(),
        artist_key: artist.to_owned(),
        suppressed: false,
    }
}

fn flags_by_id(events: &[SecondEvent]) -> BTreeMap<String, bool> {
    events
        .iter()
        .zip(suppressed_flags(events))
        .map(|(event, flag)| (event.event_id.clone(), flag))
        .collect()
}

#[test]
fn a_lone_event_is_kept() {
    assert_eq!(suppressed_flags(&[event("a", false, "t", "x")]), [false]);
}

#[test]
fn the_same_title_in_one_second_keeps_only_the_first_by_priority_then_id() {
    let events = [event("b", true, "song", "x"), event("a", true, "song", "y")];
    assert_eq!(suppressed_flags(&events), [true, false]);
}

#[test]
fn a_recorded_event_beats_an_unrecorded_one_with_the_same_title() {
    let events = [
        event("a", false, "song", "x"),
        event("z", true, "song", "x"),
    ];
    assert_eq!(suppressed_flags(&events), [true, false]);
}

#[test]
fn an_unrecorded_event_by_a_recorded_artist_is_suppressed() {
    let events = [
        event("a", false, "other song", "x"),
        event("z", true, "song", "x"),
    ];
    assert_eq!(suppressed_flags(&events), [true, false]);
}

#[test]
fn a_recorded_event_is_not_suppressed_by_artist_alone() {
    let events = [event("a", true, "one", "x"), event("b", true, "two", "x")];
    assert_eq!(suppressed_flags(&events), [false, false]);
}

#[test]
fn unrecorded_events_of_different_titles_and_artists_all_stay() {
    let events = [event("a", false, "one", "x"), event("b", false, "two", "y")];
    assert_eq!(suppressed_flags(&events), [false, false]);
}

#[test]
fn a_suppressed_recorded_event_does_not_suppress_by_artist() {
    let events = [
        event("a", true, "song", "x"),
        event("b", true, "song", "y"),
        event("c", false, "third", "y"),
    ];
    assert_eq!(suppressed_flags(&events), [false, true, false]);
}

#[test]
fn recompute_reports_only_flags_that_changed_ordered_by_event_id() {
    let mut stored = vec![
        event("z", true, "song", "x"),
        event("a", false, "song", "x"),
    ];
    stored[0].suppressed = true;
    stored[1].suppressed = false;
    assert_eq!(
        recompute_second(&stored),
        [
            FlagChange {
                event_id: "a".into(),
                suppressed: true
            },
            FlagChange {
                event_id: "z".into(),
                suppressed: false
            },
        ]
    );
    stored[0].suppressed = false;
    stored[1].suppressed = true;
    assert!(recompute_second(&stored).is_empty());
}

fn events_strategy() -> impl Strategy<Value = Vec<SecondEvent>> {
    proptest::collection::vec((any::<bool>(), 0u8..4, 0u8..3), 0..12).prop_map(|rows| {
        rows.into_iter()
            .enumerate()
            .map(|(index, (recorded, title, artist))| {
                event(
                    &format!("{:024x}", index * 7919 % 1009),
                    recorded,
                    &format!("t{title}"),
                    &format!("a{artist}"),
                )
            })
            .collect()
    })
}

proptest! {
    #[test]
    fn shuffling_the_events_gives_the_same_verdict_per_event(
        events in events_strategy(),
        keys in proptest::collection::vec(any::<u32>(), 12),
    ) {
        let mut order: Vec<usize> = (0..events.len()).collect();
        order.sort_by_key(|&index| keys[index]);
        let shuffled: Vec<SecondEvent> = order.iter().map(|&index| events[index].clone()).collect();
        prop_assert_eq!(flags_by_id(&events), flags_by_id(&shuffled));
    }

    #[test]
    fn no_title_is_kept_twice(events in events_strategy()) {
        let flags = suppressed_flags(&events);
        let mut kept: BTreeMap<&str, usize> = BTreeMap::new();
        for (event, suppressed) in events.iter().zip(&flags) {
            if !suppressed {
                *kept.entry(event.title_key.as_str()).or_default() += 1;
            }
        }
        prop_assert!(kept.values().all(|&count| count == 1));
    }
}
