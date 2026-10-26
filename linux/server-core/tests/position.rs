use flaccy_server_core::position::{between, is_valid, needs_rebalance, rebalance, MAX_POS_LEN};
use proptest::prelude::*;

fn insert_at(keys: &mut Vec<String>, index: usize) {
    let prev = index.checked_sub(1).map(|i| keys[i].as_str());
    let next = keys.get(index).map(String::as_str);
    let key = between(prev, next);
    keys.insert(index, key);
}

fn assert_strictly_increasing(keys: &[String]) {
    for pair in keys.windows(2) {
        assert!(pair[0] < pair[1], "{} !< {}", pair[0], pair[1]);
    }
    for key in keys {
        assert!(is_valid(key), "{key}");
    }
}

fn rewrite_when_long(keys: &mut Vec<String>) -> bool {
    if keys.iter().any(|key| needs_rebalance(key)) {
        *keys = rebalance(keys.len());
        return true;
    }
    false
}

#[test]
fn both_ends_open_gives_v() {
    assert_eq!(between(None, None), "V");
}

#[test]
fn midpoint_of_adjacent_digits_descends_a_digit() {
    assert_eq!(between(Some("1"), Some("2")), "1V");
    assert_eq!(between(Some("V"), Some("W")), "VV");
}

#[test]
fn midpoint_of_distant_digits_is_the_middle_digit() {
    assert_eq!(between(Some("0"), Some("4")), "2");
    assert_eq!(between(Some("V"), Some("k")), "d");
}

#[test]
fn open_ends_step_one_digit() {
    assert_eq!(between(Some("V"), None), "W");
    assert_eq!(between(None, Some("V")), "U");
}

#[test]
fn prefix_neighbours_stay_between() {
    let key = between(Some("V"), Some("V1"));
    assert!("V" < key.as_str() && key.as_str() < "V1", "{key}");
}

#[test]
fn equal_neighbours_land_after_them() {
    let key = between(Some("k"), Some("k"));
    assert!(key.as_str() > "k");
}

#[test]
fn appending_a_thousand_times_stays_within_the_limit() {
    let mut keys = Vec::new();
    for _ in 0..1_000 {
        let at = keys.len();
        insert_at(&mut keys, at);
    }
    assert_strictly_increasing(&keys);
    assert!(keys.iter().all(|key| key.len() <= MAX_POS_LEN));
}

#[test]
fn prepending_a_thousand_times_stays_within_the_limit() {
    let mut keys = Vec::new();
    for _ in 0..1_000 {
        insert_at(&mut keys, 0);
    }
    assert_strictly_increasing(&keys);
    assert!(keys.iter().all(|key| key.len() <= MAX_POS_LEN));
}

#[test]
fn repeated_insertion_at_one_spot_is_fixed_by_rebalance() {
    let mut keys = rebalance(3);
    let mut rewrites = 0;
    for _ in 0..3_000 {
        insert_at(&mut keys, 1);
        assert!(keys.iter().all(|key| key.len() <= MAX_POS_LEN + 1));
        if rewrite_when_long(&mut keys) {
            rewrites += 1;
        }
        assert!(keys.iter().all(|key| key.len() <= MAX_POS_LEN));
    }
    assert!(rewrites > 0);
    assert_strictly_increasing(&keys);
}

#[test]
fn ten_thousand_random_insertions_keep_strict_order() {
    let mut state = 0x2545_F491_4F6C_DD1D_u64;
    let mut keys: Vec<String> = Vec::new();
    for _ in 0..10_000 {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let index = (state % (keys.len() as u64 + 1)) as usize;
        insert_at(&mut keys, index);
        rewrite_when_long(&mut keys);
    }
    assert_strictly_increasing(&keys);
}

#[test]
fn rebalance_is_even_and_leaves_room() {
    for count in [0, 1, 2, 61, 62, 63, 1_000, 20_000] {
        let keys = rebalance(count);
        assert_eq!(keys.len(), count);
        assert_strictly_increasing(&keys);
        assert!(keys.iter().all(|key| key.len() <= 4));
    }
}

#[test]
fn rebalanced_keys_leave_a_gap_to_insert_into() {
    let keys = rebalance(1_000);
    for pair in keys.windows(2) {
        let key = between(Some(&pair[0]), Some(&pair[1]));
        assert!(pair[0] < key && key < pair[1]);
        assert!(key.len() <= pair[0].len().max(pair[1].len()) + 1);
    }
}

proptest! {
    #[test]
    fn between_is_strict_and_never_ends_in_zero(spots in proptest::collection::vec(0usize..400, 1..300)) {
        let mut keys: Vec<String> = Vec::new();
        for spot in spots {
            let index = spot % (keys.len() + 1);
            insert_at(&mut keys, index);
            rewrite_when_long(&mut keys);
        }
        assert_strictly_increasing(&keys);
        prop_assert!(keys.iter().all(|key| !key.ends_with('0')));
    }

    #[test]
    fn between_two_open_ends_and_one_bound_is_ordered(seed in 0usize..5_000) {
        let keys = rebalance(seed % 200 + 1);
        let pivot = &keys[seed % keys.len()];
        let before = between(None, Some(pivot));
        let after = between(Some(pivot), None);
        prop_assert!(before.as_str() < pivot.as_str());
        prop_assert!(after.as_str() > pivot.as_str());
        prop_assert!(is_valid(&before) && is_valid(&after));
    }
}
