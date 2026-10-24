//! How a page of songs arranges itself in the room it has: when its hero
//! stacks, when it moves into a rail, how many columns the songs flow over and
//! which layouts a page offers. Pure, so every client decides the same way.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Library/TrackPageLayout.swift`.

use std::ops::Range;

/// An album with fewer songs than this per column is never split over several
/// columns: the page would be wider than it is tall for no gain.
pub const SONGS_PER_COLUMN: usize = 6;

/// Below this width the hero stacks over a smaller cover.
pub const COMPACT_MAX: i32 = 560;
/// From this width the hero moves into a rail beside the song list, so Play
/// and Shuffle stay in reach however far the list is scrolled.
pub const WIDE_MIN: i32 = 1100;
/// Pages with at least this many songs get a filter box.
pub const FILTER_THRESHOLD: usize = 8;


/// How a page's songs are drawn. The choice is remembered and shared by the
/// album and playlist pages.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackLayout {
    List,
    Table,
    Columns,
}

/// Which kind of page is asking, because a playlist's order is the listener's
/// own and an album's discs are a fact about the release.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PageKind {
    Album,
    Playlist,
}

impl TrackLayout {
    pub const ALL: [TrackLayout; 3] = [TrackLayout::List, TrackLayout::Table, TrackLayout::Columns];

    pub fn id(self) -> &'static str {
        match self {
            TrackLayout::List => "list",
            TrackLayout::Table => "table",
            TrackLayout::Columns => "columns",
        }
    }

    pub fn from_id(id: &str) -> TrackLayout {
        Self::ALL
            .into_iter()
            .find(|layout| layout.id() == id)
            .unwrap_or(TrackLayout::List)
    }

    /// Columns flow an album's discs side by side; a playlist is one run the
    /// listener orders by hand, which a column break would cut in two.
    pub fn offered_on(self, kind: PageKind) -> bool {
        self != TrackLayout::Columns || kind == PageKind::Album
    }

    /// The layout a page actually draws for a remembered choice.
    pub fn resolved_for(self, kind: PageKind) -> TrackLayout {
        if self.offered_on(kind) {
            self
        } else {
            TrackLayout::List
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PageMode {
    Compact,
    Regular,
    Wide,
}

pub fn page_mode(width: i32) -> PageMode {
    if width <= COMPACT_MAX {
        PageMode::Compact
    } else if width >= WIDE_MIN {
        PageMode::Wide
    } else {
        PageMode::Regular
    }
}

/// How many side-by-side columns a pane of `width` pixels has room for, never
/// more than there are blocks of songs to put in them.
pub fn column_count(width: i32, blocks: usize) -> usize {
    let fit = match width {
        ..=879 => 1,
        880..=1359 => 2,
        _ => 3,
    };
    fit.min(blocks.max(1))
}

/// Splits consecutive blocks (a disc, or the songs of an unmarked album cut
/// into equal parts by the caller) over `columns` runs of the order they
/// already have, so the heights come out as even as the blocks allow.
pub fn balance_columns(sizes: &[usize], columns: usize) -> Vec<Range<usize>> {
    let columns = columns.clamp(1, sizes.len().max(1));
    if sizes.is_empty() {
        return vec![0..0];
    }
    let total: usize = sizes.iter().sum();
    let mut ranges = Vec::with_capacity(columns);
    let mut start = 0;
    let mut taken = 0;
    for column in 0..columns {
        let remaining_columns = columns - column;
        if remaining_columns == 1 {
            ranges.push(start..sizes.len());
            break;
        }
        let target = (total - taken).div_ceil(remaining_columns);
        let latest_end = sizes.len() - (remaining_columns - 1);
        let mut end = start;
        let mut height = 0;
        while end < latest_end && (end == start || height + sizes[end] / 2 < target) {
            height += sizes[end];
            end += 1;
        }
        taken += height;
        ranges.push(start..end);
        start = end;
    }
    ranges
}

/// Cuts `count` songs into `columns` equal consecutive runs, for an album with
/// no discs to follow.
pub fn even_runs(count: usize, columns: usize) -> Vec<Range<usize>> {
    let columns = columns.clamp(1, count.max(1));
    let size = count.div_ceil(columns).max(1);
    (0..columns)
        .map(|column| (column * size).min(count)..((column + 1) * size).min(count))
        .filter(|range| !range.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_ids_round_trip() {
        for layout in TrackLayout::ALL {
            assert_eq!(TrackLayout::from_id(layout.id()), layout);
        }
        assert_eq!(TrackLayout::from_id("nonsense"), TrackLayout::List);
        assert_eq!(TrackLayout::from_id(""), TrackLayout::List);
    }

    #[test]
    fn a_playlist_never_resolves_to_columns() {
        assert_eq!(
            TrackLayout::Columns.resolved_for(PageKind::Playlist),
            TrackLayout::List
        );
        assert_eq!(
            TrackLayout::Columns.resolved_for(PageKind::Album),
            TrackLayout::Columns
        );
        assert_eq!(
            TrackLayout::Table.resolved_for(PageKind::Playlist),
            TrackLayout::Table
        );
    }

    #[test]
    fn page_width_picks_the_arrangement() {
        assert_eq!(page_mode(320), PageMode::Compact);
        assert_eq!(page_mode(COMPACT_MAX), PageMode::Compact);
        assert_eq!(page_mode(COMPACT_MAX + 1), PageMode::Regular);
        assert_eq!(page_mode(WIDE_MIN - 1), PageMode::Regular);
        assert_eq!(page_mode(WIDE_MIN), PageMode::Wide);
        assert_eq!(page_mode(2400), PageMode::Wide);
    }

    #[test]
    fn column_count_follows_the_room_and_the_blocks() {
        assert_eq!(column_count(600, 4), 1);
        assert_eq!(column_count(879, 4), 1);
        assert_eq!(column_count(880, 4), 2);
        assert_eq!(column_count(1360, 4), 3);
        assert_eq!(column_count(1360, 2), 2);
        assert_eq!(column_count(1360, 1), 1);
        assert_eq!(column_count(1360, 0), 1);
    }

    #[test]
    fn two_discs_take_a_column_each() {
        assert_eq!(balance_columns(&[12, 12], 2), vec![0..1, 1..2]);
    }

    #[test]
    fn uneven_discs_keep_their_order_and_stay_whole() {
        assert_eq!(balance_columns(&[10, 6, 8], 2), vec![0..1, 1..3]);
        assert_eq!(balance_columns(&[4, 4, 4, 4], 2), vec![0..2, 2..4]);
    }

    #[test]
    fn more_columns_than_blocks_leaves_none_empty() {
        let ranges = balance_columns(&[5, 5], 3);
        assert_eq!(ranges.len(), 2);
        assert!(ranges.iter().all(|range| !range.is_empty()));
    }

    #[test]
    fn balancing_covers_every_block_exactly_once() {
        for sizes in [vec![9, 1, 1, 1, 9], vec![1, 1, 1, 1, 1, 1, 1], vec![30]] {
            for columns in 1..=3 {
                let ranges = balance_columns(&sizes, columns);
                assert_eq!(ranges.first().map(|r| r.start), Some(0));
                assert_eq!(ranges.last().map(|r| r.end), Some(sizes.len()));
                for pair in ranges.windows(2) {
                    assert_eq!(pair[0].end, pair[1].start);
                }
            }
        }
    }

    #[test]
    fn an_album_without_discs_is_cut_into_even_runs() {
        assert_eq!(even_runs(10, 2), vec![0..5, 5..10]);
        assert_eq!(even_runs(11, 2), vec![0..6, 6..11]);
        assert_eq!(even_runs(7, 3), vec![0..3, 3..6, 6..7]);
        assert_eq!(even_runs(2, 3), vec![0..1, 1..2]);
        assert_eq!(even_runs(0, 2), Vec::<Range<usize>>::new());
    }
}
