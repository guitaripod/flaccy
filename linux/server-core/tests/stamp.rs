use flaccy_server_core::stamp::{ClientClock, ServerClock, Stamp};

#[test]
fn pack_and_unpack_round_trip() {
    let stamp = Stamp::pack(1_790_000_000_000, 7);
    assert_eq!(stamp.0, (1_790_000_000_000_i64 << 16) | 7);
    assert_eq!(stamp.unpack(), (1_790_000_000_000, 7));
    assert_eq!(stamp.wall_ms(), 1_790_000_000_000);
}

#[test]
fn stamps_compare_as_integers() {
    assert!(Stamp::pack(5, 65_535) < Stamp::pack(6, 0));
    assert!(Stamp::pack(5, 1) > Stamp::pack(5, 0));
}

#[test]
fn client_clock_follows_the_server_offset() {
    let mut clock = ClientClock::default();
    clock.observe_server_time(1_000_500, 1_000_000);
    assert_eq!(clock.offset_ms(), 500);
    assert_eq!(clock.next(2_000_000), Stamp::from_wall_ms(2_000_500));
}

#[test]
fn client_clock_never_goes_backwards() {
    let mut clock = ClientClock::default();
    let first = clock.next(10_000);
    let same_instant = clock.next(10_000);
    let regressed = clock.next(1_000);
    assert_eq!(same_instant, Stamp(first.0 + 1));
    assert_eq!(regressed, Stamp(first.0 + 2));
}

#[test]
fn client_clock_resumes_from_its_persisted_stamp() {
    let mut clock = ClientClock::new(Stamp::from_wall_ms(50_000), 0);
    assert_eq!(clock.next(1_000), Stamp(Stamp::from_wall_ms(50_000).0 + 1));
}

#[test]
fn server_clock_is_strictly_increasing() {
    let mut clock = ServerClock::default();
    let first = clock.next(5_000);
    assert_eq!(first, Stamp::from_wall_ms(5_000));
    assert_eq!(clock.next(5_000), Stamp(first.0 + 1));
    assert_eq!(clock.next(1_000), Stamp(first.0 + 2));
}

#[test]
fn store_clamps_a_future_stamp_to_the_server_clock() {
    let mut clock = ServerClock::default();
    let future = Stamp::from_wall_ms(9_000_000);
    let stored = clock.store(future, 5_000);
    assert_eq!(stored, Stamp::from_wall_ms(5_000));
    assert!(stored < future);
}

#[test]
fn store_keeps_a_past_stamp() {
    let mut clock = ServerClock::default();
    let past = Stamp::from_wall_ms(1_000);
    assert_eq!(clock.store(past, 5_000), past);
}

#[test]
fn clock_is_behind_after_more_than_an_hour() {
    let mut clock = ServerClock::default();
    clock.next(10_000_000);
    assert!(!clock.is_behind(10_000_000 - 3_600_000));
    assert!(clock.is_behind(10_000_000 - 3_600_001));
    assert!(!clock.is_behind(10_000_000));
}
