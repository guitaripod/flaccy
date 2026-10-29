use crate::fixtures::{Catalog, LYRIC_SONGS};
use crate::view::ServerView;
use flaccy_library::db::Db;
use std::collections::{BTreeMap, BTreeSet};

/// The user-visible state both sides must agree on, in a form that compares with `==`.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Canon {
    /// Playlist name to the song keys of its visible entries in order.
    pub playlists: BTreeMap<String, Vec<String>>,
    /// Song keys currently loved.
    pub loves: BTreeSet<String>,
    /// Song key to lyric offset in milliseconds, for the songs that carry lyrics.
    pub lyrics: BTreeMap<String, i64>,
    /// Visible plays as (unix seconds, song key) with multiplicity.
    pub listens: BTreeMap<(i64, String), usize>,
}

impl Canon {
    /// What a client's database shows.
    pub fn of_client(db: &Db, catalog: &Catalog) -> Canon {
        let mut canon = Canon::default();
        for playlist in db.fetch_playlists() {
            let keys = db
                .playlist_tracks(playlist.id)
                .iter()
                .filter_map(|row| catalog.key_of_path(&row.rel_path).map(str::to_owned))
                .collect();
            canon.playlists.insert(playlist.name, keys);
        }
        for track in db.fetch_all_tracks().into_iter().filter(|track| track.loved) {
            if let Some(key) = catalog.key_of_path(&track.rel_path) {
                canon.loves.insert(key.to_owned());
            }
        }
        for song in catalog.songs.iter().take(LYRIC_SONGS) {
            let offset = db.fetch_lyrics(&song.title, &song.artist).map_or(0, |row| row.offset_ms);
            canon.lyrics.insert(song.key.clone(), offset);
        }
        for row in db.fetch_all_scrobble_rows() {
            let key = flaccy_library::server_sync::song_key_of(&row.title, &row.artist);
            *canon.listens.entry((row.timestamp_unix, key)).or_insert(0) += 1;
        }
        canon
    }

    /// What the server's state implies a client should show.
    pub fn of_server(view: &ServerView, catalog: &Catalog) -> Canon {
        let mut canon = Canon::default();
        for playlist in view.playlists.values().filter(|playlist| playlist.alive) {
            let mut entries: Vec<_> = view
                .entries
                .values()
                .filter(|entry| entry.alive && entry.playlist == playlist.id)
                .collect();
            entries.sort_by(|a, b| (&a.pos, &a.id).cmp(&(&b.pos, &b.id)));
            let keys = entries.iter().map(|entry| entry.song.song_key.clone()).collect();
            canon.playlists.insert(playlist.name.clone(), keys);
        }
        canon.loves = view.loves.values().filter(|love| love.loved).map(|love| love.song_key.clone()).collect();
        for song in catalog.songs.iter().take(LYRIC_SONGS) {
            let offset = view
                .scalars
                .get(&format!("lyr/{}", song.key))
                .filter(|scalar| !scalar.deleted)
                .and_then(|scalar| scalar.value.as_i64())
                .unwrap_or(0);
            canon.lyrics.insert(song.key.clone(), offset);
        }
        for item in view.listens.iter().filter(|item| !item.suppressed) {
            *canon.listens.entry((item.ts, item.song.song_key.clone())).or_insert(0) += 1;
        }
        canon
    }

    /// The first thing that differs, named by entity, or `None` when equal.
    pub fn first_difference(&self, other: &Canon, mine: &str, theirs: &str) -> Option<String> {
        if let Some(found) = map_difference("playlist", &self.playlists, &other.playlists, mine, theirs) {
            return Some(found);
        }
        if let Some(key) = self.loves.symmetric_difference(&other.loves).next() {
            let who = if self.loves.contains(key) { mine } else { theirs };
            return Some(format!("love {key}: loved on {who} only"));
        }
        if let Some(found) = map_difference("lyric offset", &self.lyrics, &other.lyrics, mine, theirs) {
            return Some(found);
        }
        map_difference("listen", &self.listens, &other.listens, mine, theirs)
    }
}

fn map_difference<K: Ord + std::fmt::Debug, V: PartialEq + std::fmt::Debug>(
    label: &str,
    left: &BTreeMap<K, V>,
    right: &BTreeMap<K, V>,
    mine: &str,
    theirs: &str,
) -> Option<String> {
    for (key, value) in left {
        match right.get(key) {
            None => return Some(format!("{label} {key:?}: present on {mine} only ({})", clip(value))),
            Some(other) if other != value => {
                return Some(format!("{label} {key:?}: {mine} has {} but {theirs} has {}", clip(value), clip(other)));
            }
            Some(_) => {}
        }
    }
    right
        .keys()
        .find(|key| !left.contains_key(key))
        .map(|key| format!("{label} {key:?}: present on {theirs} only"))
}

fn clip(value: &impl std::fmt::Debug) -> String {
    let text = format!("{value:?}");
    if text.len() > 240 {
        format!("{}...", &text[..240])
    } else {
        text
    }
}
