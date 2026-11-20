//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Home/DayStableOrder.swift`.
//!
//! A weighted order that holds for a whole night's listening: the same
//! candidates and weights give the same order on every build that day, on
//! every client, and a fresh order the next. Home's suggestions are ordered
//! through it so what Home offers stays put while the page rebuilds around it.

/// The hour a listening day turns over, local time: an evening that runs past
/// midnight keeps the evening's suggestion.
pub const DAY_STARTS_AT_HOUR: i64 = 5;

/// The listening day `unix` falls in, counted from 1970-01-01 on the person's
/// own clock.
pub fn day_of(unix: i64, seconds_from_gmt: i64) -> i64 {
    (unix + seconds_from_gmt - DAY_STARTS_AT_HOUR * 3_600).div_euclid(86_400)
}

/// A draw strictly between 0 and 1, fixed by the day and a candidate's name.
pub fn draw(day: i64, name: &str) -> f64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in format!("{day}\u{0}{name}").bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    ((finalized(hash) >> 11) as f64 + 0.5) / 9_007_199_254_740_992.0
}

/// Efraimidis–Spirakis with the day's draws instead of random ones: each
/// candidate's key is `draw^(1/weight)`, highest first, so heavier candidates
/// tend to lead while every one keeps a chance. Equal keys keep the order they
/// were given in.
pub fn ordered<T>(
    items: Vec<T>,
    day: i64,
    name: impl Fn(&T) -> String,
    weight: impl Fn(&T) -> f64,
) -> Vec<T> {
    let mut keyed: Vec<(usize, f64, T)> = items
        .into_iter()
        .enumerate()
        .map(|(position, item)| {
            let key = draw(day, &name(&item)).powf(1.0 / weight(&item).max(0.0001));
            (position, key, item)
        })
        .collect();
    keyed.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.0.cmp(&b.0))
    });
    keyed.into_iter().map(|(_, _, item)| item).collect()
}

/// MurmurHash3's 64-bit finalizer, so names that differ only in their last
/// letters still land far apart.
fn finalized(value: u64) -> u64 {
    let mut hash = value;
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xff51_afd7_ed55_8ccd);
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xc4ce_b3fe_1a85_ec53);
    hash ^= hash >> 33;
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidates() -> Vec<(&'static str, f64)> {
        vec![
            ("alpha", 1.0),
            ("beta", 3.0),
            ("gamma", 2.0),
            ("delta", 5.0),
            ("epsilon", 0.5),
        ]
    }

    fn order(items: Vec<(&'static str, f64)>, day: i64) -> Vec<&'static str> {
        ordered(items, day, |item| item.0.to_string(), |item| item.1)
            .into_iter()
            .map(|item| item.0)
            .collect()
    }

    #[test]
    fn d1_the_listening_day_turns_over_at_five_in_the_morning_local_time() {
        assert_eq!(day_of(1_795_217_400, 0), 20_777);
        assert_eq!(day_of(1_795_217_400, 7_200), 20_777);
        assert_eq!(day_of(1_795_217_400, -28_800), 20_777);
        assert_eq!(day_of(1_795_233_540, 0), 20_777);
        assert_eq!(day_of(1_795_233_540, 3_600), 20_777);
        assert_eq!(day_of(1_795_237_199, 0), 20_777);
        assert_eq!(day_of(1_795_237_200, 0), 20_778);
    }

    #[test]
    fn d2_draws_match_the_shared_vectors() {
        assert_eq!(draw(20_412, "kind of blue\u{0}miles davis"), 0.20503830680303542);
        assert_eq!(draw(20_413, "kind of blue\u{0}miles davis"), 0.8589927958451198);
    }

    #[test]
    fn d3_the_order_matches_the_shared_vectors_and_moves_with_the_day() {
        assert_eq!(order(candidates(), 20_412), ["gamma", "delta", "beta", "epsilon", "alpha"]);
        assert_eq!(order(candidates(), 20_413), ["beta", "delta", "alpha", "gamma", "epsilon"]);
        assert_eq!(order(candidates(), 20_414), ["beta", "alpha", "gamma", "delta", "epsilon"]);
    }

    #[test]
    fn d4_rebuilding_the_same_day_gives_the_same_order_whatever_order_the_candidates_arrive() {
        let mut reversed = candidates();
        reversed.reverse();
        assert_eq!(order(reversed, 20_412), order(candidates(), 20_412));
    }

    #[test]
    fn d5_heavier_candidates_lead_about_as_often_as_their_weight_says() {
        let heavy_leads = (20_000..21_000)
            .filter(|day| order(vec![("light", 1.0), ("heavy", 10.0)], *day)[0] == "heavy")
            .count();
        assert_eq!(heavy_leads, 909);
    }

    #[test]
    fn d6_equal_names_keep_the_order_they_came_in() {
        let twins = vec![("same", 1.0, 1), ("same", 1.0, 2)];
        let tags: Vec<i32> = ordered(twins, 1, |item| item.0.to_string(), |item| item.1)
            .into_iter()
            .map(|item| item.2)
            .collect();
        assert_eq!(tags, [1, 2]);
    }
}
