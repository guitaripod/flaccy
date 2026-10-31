//! When a scan that started from an empty library shows the songs it has read
//! so far. Mirrors `LiveListingPace.swift`: the first listing once
//! `FIRST_LISTING` has passed, so a small library still arrives whole and the
//! Debut gets its moment, then no more often than every `BETWEEN`, so
//! rebuilding the views stays a small share of the scan.

use std::time::{Duration, Instant};

pub const FIRST_LISTING: Duration = Duration::from_secs(3);
pub const BETWEEN: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LiveListingPace {
    began: Instant,
    last_listed: Option<Instant>,
}

impl LiveListingPace {
    pub fn new(began: Instant) -> Self {
        Self { began, last_listed: None }
    }

    pub fn is_due(&self, now: Instant) -> bool {
        match self.last_listed {
            Some(last) => now.saturating_duration_since(last) >= BETWEEN,
            None => now.saturating_duration_since(self.began) >= FIRST_LISTING,
        }
    }

    pub fn note_listed(&mut self, now: Instant) {
        self.last_listed = Some(now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(value: u64) -> Duration {
        Duration::from_millis(value)
    }

    #[test]
    fn nothing_is_listed_in_the_first_seconds() {
        let start = Instant::now();
        let pace = LiveListingPace::new(start);
        assert!(!pace.is_due(start));
        assert!(!pace.is_due(start + ms(2_999)));
    }

    #[test]
    fn the_first_listing_comes_once_its_delay_has_passed() {
        let start = Instant::now();
        let pace = LiveListingPace::new(start);
        assert!(pace.is_due(start + ms(3_000)));
        assert!(pace.is_due(start + ms(40_000)));
    }

    #[test]
    fn later_listings_wait_their_spacing() {
        let start = Instant::now();
        let mut pace = LiveListingPace::new(start);
        let first = start + ms(4_000);
        pace.note_listed(first);
        assert!(!pace.is_due(first));
        assert!(!pace.is_due(first + ms(4_999)));
        assert!(pace.is_due(first + ms(5_000)));
    }

    #[test]
    fn the_spacing_counts_from_the_latest_listing() {
        let start = Instant::now();
        let mut pace = LiveListingPace::new(start);
        pace.note_listed(start + ms(3_000));
        pace.note_listed(start + ms(9_000));
        assert!(!pace.is_due(start + ms(13_000)));
        assert!(pace.is_due(start + ms(14_000)));
    }
}
