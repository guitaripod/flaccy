//! The rules every client follows when it changes a playlist: what an
//! addition really adds, where a drag leaves the songs it carries, and where
//! songs taken out go back when the person undoes it. Mirrors
//! `Core/FlaccyCore/Sources/FlaccyCore/Library/PlaylistEditing.swift`.

use crate::home::fold;
use std::collections::HashSet;
use std::hash::Hash;

/// What adding songs to a playlist does: the files it appends, in the order
/// given and each once, and the files it leaves out because the playlist
/// already holds them or the same addition named them twice.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Addition {
    pub added: Vec<String>,
    pub already_in: Vec<String>,
}

pub fn addition(existing: &[String], adding: &[String]) -> Addition {
    let present: HashSet<&String> = existing.iter().collect();
    let mut held: HashSet<&String> = present.clone();
    let mut reported: HashSet<&String> = HashSet::new();
    let mut result = Addition::default();
    for file in adding {
        if held.insert(file) {
            result.added.push(file.clone());
        } else if present.contains(file) && reported.insert(file) {
            result.already_in.push(file.clone());
        }
    }
    result
}

/// The order a drag leaves: the `moving` entries, in the order they held,
/// lifted out and set down together at `insertion_index`, an index into
/// `order` as it stood before the drag (0 puts them first, `order.len()`
/// last). Entries `order` does not hold are ignored.
pub fn moved<T: Clone + Eq + Hash>(order: &[T], moving: &HashSet<T>, insertion_index: i64) -> Vec<T> {
    let carried: Vec<T> = order.iter().filter(|id| moving.contains(id)).cloned().collect();
    if carried.is_empty() {
        return order.to_vec();
    }
    let clamped = insertion_index.clamp(0, order.len() as i64) as usize;
    let mut result: Vec<T> = order[..clamped]
        .iter()
        .filter(|id| !moving.contains(id))
        .cloned()
        .collect();
    result.extend(carried);
    result.extend(order[clamped..].iter().filter(|id| !moving.contains(id)).cloned());
    result
}

/// The index a single row dragged from `source` to `destination` in a list
/// that reports where the row ends up is set down at, in `moved`'s terms.
pub fn insertion_index(source: usize, destination: usize) -> i64 {
    if destination > source {
        destination as i64 + 1
    } else {
        destination as i64
    }
}

/// The playlist's order once entries that were taken out go back where they
/// stood: `kept` is the order now and `removed` names each entry with the index
/// it held, so restoring them earliest first rebuilds the playlist as it was.
/// An index past the end, after the playlist got shorter meanwhile, puts the
/// entry last.
pub fn restored<T: Clone>(kept: &[T], removed: &[(T, i64)]) -> Vec<T> {
    let mut order = kept.to_vec();
    let mut sorted: Vec<&(T, i64)> = removed.iter().collect();
    sorted.sort_by_key(|(_, index)| *index);
    for (id, index) in sorted {
        let at = (*index).clamp(0, order.len() as i64) as usize;
        order.insert(at, id.clone());
    }
    order
}

/// A name for a copy of the playlist called `name` that no playlist in `taken`
/// already carries: "Name Copy", then "Name Copy 2" and on.
pub fn copy_name(name: &str, copy_word: &str, taken: &[String]) -> String {
    let names: HashSet<String> = taken.iter().map(|n| fold(n)).collect();
    let base = format!("{name} {copy_word}");
    if !names.contains(&fold(&base)) {
        return base;
    }
    let mut number = 2;
    while names.contains(&fold(&format!("{base} {number}"))) {
        number += 1;
    }
    format!("{base} {number}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn e1_an_addition_skips_songs_the_playlist_holds() {
        let result = addition(&strings(&["a", "b"]), &strings(&["c", "a", "d", "b", "a"]));
        assert_eq!(result.added, strings(&["c", "d"]));
        assert_eq!(result.already_in, strings(&["a", "b"]));
    }

    #[test]
    fn e2_an_addition_naming_a_song_twice_adds_it_once() {
        let result = addition(&[], &strings(&["x", "y", "x"]));
        assert_eq!(result.added, strings(&["x", "y"]));
        assert!(result.already_in.is_empty());
    }

    #[test]
    fn e3_a_moved_row_lands_where_the_list_says_it_ends() {
        let order = strings(&["a", "b", "c", "d", "e"]);
        let one = |id: &str| HashSet::from([id.to_string()]);
        assert_eq!(moved(&order, &one("b"), insertion_index(1, 3)), strings(&["a", "c", "d", "b", "e"]));
        assert_eq!(moved(&order, &one("d"), insertion_index(3, 0)), strings(&["d", "a", "b", "c", "e"]));
        assert_eq!(moved(&order, &one("a"), insertion_index(0, 4)), strings(&["b", "c", "d", "e", "a"]));
    }

    #[test]
    fn e4_several_rows_move_together_in_their_own_order() {
        let order = vec![1, 2, 3, 4, 5, 6];
        assert_eq!(moved(&order, &HashSet::from([5, 2]), 1), vec![1, 2, 5, 3, 4, 6]);
        assert_eq!(moved(&order, &HashSet::from([1, 3]), 6), vec![2, 4, 5, 6, 1, 3]);
        assert_eq!(moved(&order, &HashSet::from([4]), 4), order);
        assert_eq!(moved(&order, &HashSet::from([9]), 0), order);
        assert_eq!(moved(&order, &HashSet::from([6]), -3), vec![6, 1, 2, 3, 4, 5]);
    }

    #[test]
    fn e5_removed_entries_go_back_where_they_stood() {
        let original = strings(&["a", "b", "c", "d", "e"]);
        let removed = vec![("d".to_string(), 3), ("a".to_string(), 0), ("b".to_string(), 1)];
        let kept: Vec<String> = original
            .iter()
            .filter(|id| !removed.iter().any(|(r, _)| r == *id))
            .cloned()
            .collect();
        assert_eq!(restored(&kept, &removed), original);
    }

    #[test]
    fn e6_a_restore_into_a_shorter_playlist_puts_the_rest_last() {
        let removed = vec![("y".to_string(), 5), ("z".to_string(), 0)];
        assert_eq!(restored(&strings(&["x"]), &removed), strings(&["z", "x", "y"]));
    }

    #[test]
    fn e7_a_copy_gets_the_first_free_name() {
        assert_eq!(copy_name("Night Drive", "Copy", &strings(&["Night Drive"])), "Night Drive Copy");
        assert_eq!(
            copy_name("Night Drive", "Copy", &strings(&["night drive copy", "Night Drive Copy 2"])),
            "Night Drive Copy 3"
        );
    }
}
