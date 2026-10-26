//! The one-time move of what the single-user server kept in `library.sqlite`
//! (playlists, stars, ratings, the saved queue and plays) into the sync state of
//! the server's owner. The old tables stay untouched; the ids are the derived
//! ones of PROTOCOL.md section 13, so running it again inserts nothing.

use std::collections::HashMap;
use std::fmt;

use flaccy_library::listen_history::ListenKeyCache;
use flaccy_library::logger;
use flaccy_server_core::model::SongRef;
use flaccy_server_core::song::{entry_id, event_id_mig, normalize_playlist_name, playlist_id, song_key};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{Mutation, MutationResult, MutationStatus};
use serde_json::{json, Value};

use super::rest::{BatchKind, Stamping};
use super::Store;
use crate::queue_session::{session_value, QueueItem};
use crate::security::{DeviceId, Principal};
use crate::songref::{credits_ref, path_ref, song_ref};
use crate::state::AppState;

/// The `server_meta` key that says the legacy data has been moved.
pub const MARKER: &str = "legacy_migrated";
const LEGACY_DEVICE: &str = "legacy";
const IMPORT_FLOOR_MS: i64 = 1_577_836_800_000;
const LISTEN_BATCH: usize = 500;
const MILLIS_PER_SECOND: i64 = 1000;

/// What a run of the migration inserted.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MigrationReport {
    /// Playlists created.
    pub playlists: usize,
    /// Playlist entries created.
    pub entries: usize,
    /// Of the entries, those whose song the library no longer lists, named from their path.
    pub unresolved_entries: usize,
    /// Starred songs.
    pub loves: usize,
    /// Rated songs.
    pub ratings: usize,
    /// Plays added, counting the approximated ones.
    pub listens: usize,
    /// Of the plays, those rebuilt from a play count with no history behind it, dated back from the last play.
    pub approximated_listens: usize,
    /// True when the saved play queue became the `legacy` device's session.
    pub queue: bool,
}

impl fmt::Display for MigrationReport {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "{} playlists with {} entries ({} named from their path only), {} stars, {} ratings, {} plays ({} approximated from play counts), {}",
            self.playlists,
            self.entries,
            self.unresolved_entries,
            self.loves,
            self.ratings,
            self.listens,
            self.approximated_listens,
            if self.queue { "the saved queue" } else { "no saved queue" }
        )
    }
}

struct LegacyPlaylist {
    name: String,
    created_ms: i64,
    songs: Vec<SongRef>,
}

struct LegacyPlay {
    ts: i64,
    title_key: String,
    artist_key: String,
    song: SongRef,
    played_s: i64,
}

struct LegacyQueue {
    items: Vec<QueueItem>,
    current: Option<String>,
    position_ms: i64,
    changed_by: String,
    changed_ms: i64,
}

#[derive(Default)]
struct Legacy {
    playlists: Vec<LegacyPlaylist>,
    loves: Vec<SongRef>,
    ratings: Vec<(SongRef, u8)>,
    queue: Option<LegacyQueue>,
    plays: Vec<LegacyPlay>,
    approximated: usize,
    unresolved: usize,
}

impl Legacy {
    fn is_empty(&self) -> bool {
        self.playlists.is_empty()
            && self.loves.is_empty()
            && self.ratings.is_empty()
            && self.queue.is_none()
            && self.plays.is_empty()
    }
}

struct Resolver<'a> {
    catalog: &'a crate::catalog::Catalog,
    tracks: HashMap<&'a str, &'a flaccy_library::library::TrackRow>,
    unresolved: usize,
}

impl<'a> Resolver<'a> {
    fn song(&mut self, rel_path: &str) -> SongRef {
        if let Some(song) = self.catalog.song_at_path(rel_path) {
            return song_ref(song);
        }
        if let Some(row) = self.tracks.get(rel_path) {
            let mut found = credits_ref(&row.title, &row.artist, &row.album, Some(rel_path));
            found.duration_ms = (row.duration * 1000.0).round() as i64;
            return found;
        }
        self.unresolved += 1;
        path_ref(rel_path)
    }
}

fn gather(state: &AppState) -> Legacy {
    let (tracks, playlist_rows, scrobbles, playlist_paths) = {
        let db = state.db();
        let rows = db.fetch_playlists();
        let paths: Vec<Vec<String>> = rows
            .iter()
            .map(|row| db.playlist_tracks(row.id).into_iter().map(|track| track.rel_path).collect())
            .collect();
        (db.fetch_all_tracks(), rows, db.fetch_all_scrobble_rows(), paths)
    };
    let catalog = state.catalog();
    let mut resolver = Resolver {
        catalog: &catalog,
        tracks: tracks.iter().map(|row| (row.rel_path.as_str(), row)).collect(),
        unresolved: 0,
    };
    let mut legacy = Legacy::default();
    for (row, paths) in playlist_rows.iter().zip(&playlist_paths) {
        legacy.playlists.push(LegacyPlaylist {
            name: row.name.clone(),
            created_ms: (row.created_at * MILLIS_PER_SECOND).max(IMPORT_FLOOR_MS),
            songs: paths.iter().map(|path| resolver.song(path)).collect(),
        });
    }
    legacy.unresolved = resolver.unresolved;
    for row in tracks.iter().filter(|row| row.loved) {
        legacy.loves.push(resolver.song(&row.rel_path));
    }
    for (path, stars) in state.0.store.ratings() {
        if let Ok(stars) = u8::try_from(stars) {
            legacy.ratings.push((resolver.song(&path), stars));
        }
    }
    legacy.ratings.sort_by(|a, b| a.0.song_key.cmp(&b.0.song_key));
    legacy.queue = state.0.store.play_queue().map(|queue| queue_of_record(&queue, &tracks, &mut resolver));
    legacy.plays = plays_of(&scrobbles, &tracks, &mut legacy.approximated);
    legacy
}

fn queue_of_record(
    queue: &crate::store::QueueRecord,
    tracks: &[flaccy_library::library::TrackRow],
    resolver: &mut Resolver<'_>,
) -> LegacyQueue {
    let path_of = |id: &str| match crate::ids::parse(id) {
        Some(crate::ids::Entity::Song(row_id)) => tracks.iter().find(|row| row.id == row_id).map(|row| row.rel_path.clone()),
        _ => None,
    };
    let songs: Vec<SongRef> = queue.entries.iter().filter_map(|id| path_of(id)).map(|path| resolver.song(&path)).collect();
    let current = queue.current.as_deref().and_then(path_of).map(|path| resolver.song(&path).song_key);
    LegacyQueue {
        items: songs.iter().map(QueueItem::of).collect(),
        current,
        position_ms: queue.position,
        changed_by: queue.changed_by.clone(),
        changed_ms: chrono::DateTime::parse_from_rfc3339(&queue.changed_at)
            .map(|moment| moment.timestamp_millis())
            .unwrap_or(IMPORT_FLOOR_MS)
            .max(IMPORT_FLOOR_MS),
    }
}

fn plays_of(
    scrobbles: &[flaccy_library::db::ScrobbleRow],
    tracks: &[flaccy_library::library::TrackRow],
    approximated: &mut usize,
) -> Vec<LegacyPlay> {
    let mut keys = ListenKeyCache::default();
    let mut counted: HashMap<String, i64> = HashMap::new();
    let mut plays = Vec::new();
    for scrobble in scrobbles.iter().filter(|scrobble| scrobble.timestamp_unix > 0) {
        let title_key = keys.title(&scrobble.title).to_owned();
        let artist_key = keys.artist(&scrobble.artist).to_owned();
        *counted.entry(song_key(&artist_key, &title_key)).or_default() += 1;
        plays.push(LegacyPlay {
            ts: scrobble.timestamp_unix,
            title_key,
            artist_key,
            song: credits_ref(&scrobble.title, &scrobble.artist, &scrobble.album, None),
            played_s: scrobble.duration.max(0),
        });
    }
    let before = plays.len();
    plays.extend(counted_only_plays(tracks, &counted, &mut keys));
    *approximated = plays.len() - before;
    plays
}

/// The old server counted a play by adding one to its track and kept no history. A song with more counted plays than
/// recorded ones gets the difference as plays one second apart, the latest at its last-played time.
fn counted_only_plays(
    tracks: &[flaccy_library::library::TrackRow],
    recorded: &HashMap<String, i64>,
    keys: &mut ListenKeyCache,
) -> Vec<LegacyPlay> {
    let mut totals: HashMap<String, (i64, i64, &flaccy_library::library::TrackRow)> = HashMap::new();
    for row in tracks.iter().filter(|row| row.play_count > 0 && row.last_played.is_some_and(|last| last > 0)) {
        let artist_key = keys.artist(&row.artist).to_owned();
        let key = song_key(&artist_key, keys.title(&row.title));
        let last = row.last_played.unwrap_or_default();
        let entry = totals.entry(key).or_insert((0, 0, row));
        entry.0 += row.play_count;
        entry.1 = entry.1.max(last);
    }
    let mut sorted: Vec<_> = totals.into_iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    let mut plays = Vec::new();
    for (key, (total, last, row)) in sorted {
        let missing = total - recorded.get(&key).copied().unwrap_or(0);
        for offset in 0..missing.max(0) {
            plays.push(LegacyPlay {
                ts: last - offset,
                title_key: keys.title(&row.title).to_owned(),
                artist_key: keys.artist(&row.artist).to_owned(),
                song: credits_ref(&row.title, &row.artist, &row.album, Some(&row.rel_path)),
                played_s: row.duration.round() as i64,
            });
        }
    }
    plays
}

fn mutation_at(name: &str, stamp_ms: i64, args: Value) -> Mutation {
    Mutation {
        id: 0,
        name: name.to_owned(),
        stamp: Stamp::from_wall_ms(stamp_ms),
        args,
    }
}

fn playlist_mutations(playlists: &[LegacyPlaylist]) -> Vec<Mutation> {
    let mut seen: HashMap<String, u32> = HashMap::new();
    playlists
        .iter()
        .map(|playlist| {
            let occurrence = seen.entry(normalize_playlist_name(&playlist.name)).or_default();
            let id = playlist_id(&playlist.name, *occurrence);
            *occurrence += 1;
            let mut repeats: HashMap<&str, u32> = HashMap::new();
            let entries: Vec<Value> = playlist
                .songs
                .iter()
                .map(|song| {
                    let repeat = repeats.entry(song.song_key.as_str()).or_default();
                    let entry = entry_id(&id, &song.song_key, *repeat);
                    *repeat += 1;
                    json!({ "id": entry, "ref": song })
                })
                .collect();
            mutation_at("playlist.create", playlist.created_ms, json!({ "id": id, "name": playlist.name, "entries": entries }))
        })
        .collect()
}

fn state_mutations(legacy: &Legacy) -> Vec<Mutation> {
    let mut mutations = playlist_mutations(&legacy.playlists);
    let mut loved = std::collections::HashSet::new();
    for song in legacy.loves.iter().filter(|song| loved.insert(song.song_key.clone())) {
        let args = json!({ "songKey": song.song_key, "ref": song, "loved": true });
        mutations.push(mutation_at("love.set", IMPORT_FLOOR_MS, args));
    }
    for (song, stars) in &legacy.ratings {
        let args = json!({ "songKey": song.song_key, "ref": song, "rating": stars });
        mutations.push(mutation_at("rating.set", IMPORT_FLOOR_MS, args));
    }
    if let Some(queue) = &legacy.queue {
        let session = session_value(&queue.items, queue.current.clone(), queue.position_ms, &queue.changed_by);
        mutations.push(mutation_at("session.save", queue.changed_ms, json!({ "session": session })));
    }
    mutations
}

fn listen_mutations(plays: &[LegacyPlay]) -> Vec<Mutation> {
    plays
        .chunks(LISTEN_BATCH)
        .map(|chunk| {
            let listens: Vec<Value> = chunk
                .iter()
                .map(|play| {
                    json!({
                        "eventId": event_id_mig(play.ts, &play.title_key, &play.artist_key),
                        "ts": play.ts,
                        "ref": play.song,
                        "playedS": play.played_s,
                        "recorded": false,
                    })
                })
                .collect();
            mutation_at("listen.record", IMPORT_FLOOR_MS, json!({ "listens": listens }))
        })
        .collect()
}

fn applied(names: &[String], results: &[MutationResult], name: &str) -> usize {
    names
        .iter()
        .zip(results)
        .filter(|(sent, result)| *sent == name && result.status == MutationStatus::Applied)
        .count()
}

async fn import(state: &AppState, owner: Principal, legacy: Legacy) -> Result<MigrationReport, String> {
    let sync = &state.0.sync;
    let before = sync.stats().await.map_err(|error| error.to_string())?;
    let kind = BatchKind {
        source: flaccy_server_core::model::Source::Migrated,
        stamping: Stamping::AsGiven,
    };
    let state_batch = state_mutations(&legacy);
    let sent: Vec<String> = state_batch.iter().map(|mutation| mutation.name.clone()).collect();
    let results = sync.apply_batch(&owner, kind, move |_| state_batch).await.map_err(|error| error.to_string())?;
    let plays = listen_mutations(&legacy.plays);
    sync.apply_batch(&owner, kind, move |_| plays).await.map_err(|error| error.to_string())?;
    let after = sync.stats().await.map_err(|error| error.to_string())?;
    let listens = usize::try_from(after.listens - before.listens).unwrap_or_default();
    let playlists = applied(&sent, &results, "playlist.create");
    Ok(MigrationReport {
        playlists,
        entries: usize::try_from(after.entries - before.entries).unwrap_or_default(),
        unresolved_entries: if playlists > 0 { legacy.unresolved } else { 0 },
        loves: applied(&sent, &results, "love.set"),
        ratings: applied(&sent, &results, "rating.set"),
        listens,
        approximated_listens: legacy.approximated.min(listens),
        queue: applied(&sent, &results, "session.save") > 0,
    })
}

async fn owner_principal(state: &AppState) -> Result<Option<Principal>, String> {
    let owner = state.0.security.owner().await.map_err(|error| error.to_string())?;
    Ok(owner.map(|owner| Principal {
        user: owner.id,
        role: owner.role,
        device: Some(DeviceId(LEGACY_DEVICE.to_owned())),
    }))
}

/// Moves the legacy data of `library.sqlite` into the owner's sync state, whether or not it has been moved before.
/// Everything it writes has a derived id, so a second run reports zeros.
pub async fn run(state: &AppState) -> Result<MigrationReport, String> {
    run_gathered(state, gather(state)).await
}

async fn run_gathered(state: &AppState, legacy: Legacy) -> Result<MigrationReport, String> {
    let Some(owner) = owner_principal(state).await? else {
        return Err("The server has no owner yet to take the old playlists, stars and plays. Create one with `flaccy-server password set`, then start the server again.".to_owned());
    };
    import(state, owner, legacy).await
}

/// Runs the migration at start unless `state.sqlite` already says it ran, and logs one line with what it moved. A
/// failure is logged and leaves the marker unset, so the next start tries again.
pub async fn migrate_if_needed(state: &AppState) {
    let sync = &state.0.sync;
    match sync.meta_value(MARKER).await {
        Ok(Some(_)) => return,
        Ok(None) => {}
        Err(error) => {
            logger::warn("server", &format!("could not check whether the old playlists and stars were moved: {error}"));
            return;
        }
    }
    let legacy = gather(state);
    if legacy.is_empty() {
        record_marker(sync, "nothing to move").await;
        return;
    }
    match run_gathered(state, legacy).await {
        Ok(report) => {
            logger::info("server", &format!("moved the old single-user data into the owner's sync state: {report}"));
            record_marker(sync, &report.to_string()).await;
        }
        Err(error) => logger::warn("server", &format!("could not move the old single-user data: {error}; it stays in library.sqlite and the next start tries again")),
    }
}

async fn record_marker(sync: &Store, summary: &str) {
    if let Err(error) = sync.set_meta_value(MARKER, summary).await {
        logger::warn("server", &format!("could not record that the old data was moved: {error}"));
    }
}
