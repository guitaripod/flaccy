//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/ByteRangeSet.swift`.
//!
//! Which bytes of a remote file are already on disk. Ranges are half-open,
//! kept sorted, and merged whenever they touch, so "is the file complete" is
//! one range from zero to the file size. Stored as a list of `[start, end]`
//! pairs, the same shape the Swift side writes.

use serde::{Deserialize, Serialize};
use std::ops::Range;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "Vec<[u64; 2]>", into = "Vec<[u64; 2]>")]
pub struct ByteRangeSet {
    ranges: Vec<Range<u64>>,
}

impl ByteRangeSet {
    pub fn new() -> Self {
        Self::default()
    }

    /// The covered ranges, sorted and with no two touching.
    pub fn ranges(&self) -> &[Range<u64>] {
        &self.ranges
    }

    /// Adds `range` to the covered bytes. An empty range changes nothing.
    pub fn insert(&mut self, range: Range<u64>) {
        let mut ranges = std::mem::take(&mut self.ranges);
        ranges.push(range);
        self.ranges = merged(ranges);
    }

    /// The parts of `range` that are not covered yet, in order.
    pub fn missing(&self, range: Range<u64>) -> Vec<Range<u64>> {
        if range.start >= range.end {
            return Vec::new();
        }
        let mut gaps = Vec::new();
        let mut cursor = range.start;
        for covered in &self.ranges {
            if covered.start >= range.end {
                break;
            }
            if covered.end <= cursor {
                continue;
            }
            if covered.start > cursor {
                gaps.push(cursor..covered.start);
            }
            cursor = covered.end;
        }
        if cursor < range.end {
            gaps.push(cursor..range.end);
        }
        gaps
    }

    /// Whether every byte of `range` is covered.
    pub fn contains(&self, range: Range<u64>) -> bool {
        self.missing(range).is_empty()
    }

    pub fn covered_bytes(&self) -> u64 {
        self.ranges
            .iter()
            .map(|range| range.end - range.start)
            .sum()
    }

    /// Whether the whole file of `file_size` bytes is covered by one range.
    pub fn is_complete(&self, file_size: u64) -> bool {
        self.ranges.len() == 1 && self.ranges[0] == (0..file_size)
    }
}

/// Sorts the ranges, drops empty ones and merges every pair that overlaps or
/// touches.
fn merged(ranges: Vec<Range<u64>>) -> Vec<Range<u64>> {
    let mut sorted: Vec<Range<u64>> = ranges
        .into_iter()
        .filter(|range| range.start < range.end)
        .collect();
    sorted.sort_by_key(|range| range.start);
    let mut merged: Vec<Range<u64>> = Vec::with_capacity(sorted.len());
    for range in sorted {
        match merged.last_mut() {
            Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
            _ => merged.push(range),
        }
    }
    merged
}

impl From<Vec<[u64; 2]>> for ByteRangeSet {
    fn from(pairs: Vec<[u64; 2]>) -> Self {
        Self {
            ranges: merged(pairs.into_iter().map(|[start, end]| start..end).collect()),
        }
    }
}

impl From<ByteRangeSet> for Vec<[u64; 2]> {
    fn from(set: ByteRangeSet) -> Self {
        set.ranges
            .into_iter()
            .map(|range| [range.start, range.end])
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(pairs: &[Range<u64>]) -> ByteRangeSet {
        let mut set = ByteRangeSet::new();
        for pair in pairs {
            set.insert(pair.clone());
        }
        set
    }

    #[test]
    fn missing_reports_the_gaps_inside_the_range() {
        let set = set(&[0..10, 20..30]);
        assert_eq!(set.missing(0..40), vec![10..20, 30..40]);
    }

    #[test]
    fn touching_ranges_merge() {
        assert_eq!(set(&[0..10, 20..30]).ranges(), &[0..10, 20..30]);
        assert_eq!(set(&[0..10, 20..30, 10..20]).ranges(), &[0..30]);
    }

    #[test]
    fn an_overlapping_insert_merges_every_range_it_reaches() {
        assert_eq!(set(&[0..10, 20..30, 5..25]).ranges(), &[0..30]);
    }

    #[test]
    fn an_empty_insert_is_a_no_op() {
        let mut set = set(&[0..10]);
        let (start, end) = (7, 3);
        set.insert(5..5);
        set.insert(start..end);
        assert_eq!(set.ranges(), &[0..10]);
    }

    #[test]
    fn contains_needs_the_whole_range_covered() {
        let set = set(&[0..10, 20..30]);
        assert!(set.contains(2..8));
        assert!(!set.contains(8..12));
        assert!(!set.contains(8..25));
    }

    #[test]
    fn complete_means_one_range_from_zero_to_the_size() {
        let mut set = set(&[0..10, 20..30]);
        assert!(!set.is_complete(30));
        set.insert(10..20);
        assert!(set.is_complete(30));
        assert!(!set.is_complete(31));
    }

    #[test]
    fn covered_bytes_sums_the_merged_ranges() {
        assert_eq!(set(&[0..10, 20..30]).covered_bytes(), 20);
    }

    #[test]
    fn serializes_as_start_and_end_pairs() {
        let set = set(&[0..10, 10..30]);
        let json = serde_json::to_string(&set).unwrap();
        assert_eq!(json, "[[0,30]]");
        let back: ByteRangeSet = serde_json::from_str(&json).unwrap();
        assert_eq!(back, set);
    }

    #[test]
    fn decoding_merges_pairs_it_was_given_unsorted() {
        let set: ByteRangeSet = serde_json::from_str("[[20,30],[0,10],[10,20]]").unwrap();
        assert_eq!(set.ranges(), &[0..30]);
    }
}
