use super::error::Result;
use super::ids::new_uuid_v7;
use super::meta;
use super::pending::{self, love_key, playlist_key, scalar_key, NewMutation};
use super::songref::{ref_for_play, ref_for_track, song_key_of};
use super::store::record;
use crate::db::Db;
use flaccy_server_core::model::SongRef;
use flaccy_server_core::scalar::validate_scalar;
use flaccy_server_core::song::event_id_rec;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashMap;

const ENTRIES_PER_MUTATION: usize = 500;

/// Turns the app's own writes into queued mutations.
///
/// Every method must run inside the transaction that also makes the app-table
/// change (see [`super::atomically`]), so no visible change exists without its
/// mutation. With no server configured each method returns at once.
pub struct Recorder<'c> {
    conn: &'c Connection,
    enabled: bool,
}

impl<'c> Recorder<'c> {
    /// A recorder over `conn`; it records only once the database has enrolled with a server.
    pub fn new(conn: &'c Connection) -> Self {
        Recorder {
            conn,
            enabled: meta::enabled(conn),
        }
    }

    /// True when writes are being recorded.
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// A playlist row was inserted: gives it its sync id and queues `playlist.create`.
    pub fn playlist_created(&self, local_id: i64, name: &str) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        let id = new_uuid_v7();
        self.conn.execute(
            "UPDATE playlists SET syncId = ?1 WHERE id = ?2",
            params![id, local_id],
        )?;
        self.queue(
            "playlist.create",
            json!({ "id": id, "name": name }),
            vec![playlist_key(&id)],
        )
    }

    /// A playlist is about to be renamed.
    pub fn playlist_renamed(&self, local_id: i64, name: &str) -> Result<()> {
        let Some(id) = self.playlist_sync_id(local_id)? else {
            return Ok(());
        };
        self.queue(
            "playlist.rename",
            json!({ "id": id, "name": name }),
            vec![playlist_key(&id)],
        )
    }

    /// A playlist is about to be deleted.
    pub fn playlist_deleted(&self, local_id: i64) -> Result<()> {
        let Some(id) = self.playlist_sync_id(local_id)? else {
            return Ok(());
        };
        self.queue(
            "playlist.delete",
            json!({ "id": id }),
            vec![playlist_key(&id)],
        )
    }

    /// Rows were appended to a playlist: gives each its sync id and queues the inserts, 500 to a mutation.
    pub fn tracks_added(&self, playlist_id: i64, rows: &[(i64, String)]) -> Result<()> {
        let Some(playlist) = self.playlist_sync_id(playlist_id)? else {
            return Ok(());
        };
        let mut entries = Vec::new();
        for (row_id, file_url) in rows {
            let Some(song) = ref_for_track(self.conn, file_url)? else {
                continue;
            };
            let id = new_uuid_v7();
            self.conn.execute(
                "UPDATE playlistTracks SET syncId = ?1 WHERE id = ?2",
                params![id, row_id],
            )?;
            entries.push(json!({ "id": id, "ref": song }));
        }
        let touches = vec![playlist_key(&playlist)];
        for chunk in entries.chunks(ENTRIES_PER_MUTATION) {
            let (name, args) = match chunk {
                [single] => (
                    "entry.insert",
                    json!({ "id": single["id"], "playlist": playlist, "ref": single["ref"], "place": { "kind": "last" } }),
                ),
                many => (
                    "entry.insertMany",
                    json!({ "playlist": playlist, "entries": many, "place": { "kind": "last" } }),
                ),
            };
            self.queue(name, args, touches.clone())?;
        }
        Ok(())
    }

    /// A playlist row is about to be deleted.
    pub fn track_removed(&self, row_id: i64) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        let found: Option<(Option<String>, Option<String>)> = self
            .conn
            .query_row(
                "SELECT t.syncId, p.syncId FROM playlistTracks t
                 JOIN playlists p ON p.id = t.playlistId WHERE t.id = ?1",
                params![row_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((Some(entry), Some(playlist))) = found else {
            return Ok(());
        };
        self.queue(
            "entry.remove",
            json!({ "id": entry }),
            vec![playlist_key(&playlist)],
        )
    }

    /// A playlist is about to be rewritten in `ordered_row_ids` order: queues the fewest moves that produce it.
    pub fn playlist_reordered(&self, playlist_id: i64, ordered_row_ids: &[i64]) -> Result<()> {
        let Some(playlist) = self.playlist_sync_id(playlist_id)? else {
            return Ok(());
        };
        let current = self.entry_ids_in_order(playlist_id)?;
        let wanted: Vec<String> = ordered_row_ids
            .iter()
            .filter_map(|row| current.by_row.get(row).cloned())
            .collect();
        for (entry, place) in moves_for(&current.order, &wanted) {
            self.queue(
                "entry.move",
                json!({ "id": entry, "place": place }),
                vec![playlist_key(&playlist)],
            )?;
        }
        Ok(())
    }

    /// A song was loved or unloved by the person.
    pub fn loved(&self, file_url: &str, loved: bool) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        let Some(song) = ref_for_track(self.conn, file_url)? else {
            return Ok(());
        };
        let key = song.song_key.clone();
        self.queue(
            "love.set",
            json!({ "songKey": key, "ref": song, "loved": loved }),
            vec![love_key(&key)],
        )
    }

    /// A scrobble row was just inserted for a play: gives it its event id and queues the listen.
    pub fn played(
        &self,
        title: &str,
        artist: &str,
        album: &str,
        ts: i64,
        played_s: i64,
    ) -> Result<()> {
        let Some(link) = self.link()? else {
            return Ok(());
        };
        let row_id = self.conn.last_insert_rowid();
        let counter = meta::take_event_counter(self.conn)?;
        let event_id = event_id_rec(&link.device, &link.instance, counter);
        self.conn.execute(
            "UPDATE scrobbles SET eventId = ?1 WHERE id = ?2",
            params![event_id, row_id],
        )?;
        let song = ref_for_play(title, artist, album);
        pending::append_listen(self.conn, listen_json(&event_id, ts, &song, played_s, true))
    }

    /// The person set a lyrics offset. A negative offset is not a legal `lyr/` value and stays on this device.
    pub fn lyrics_offset(&self, title: &str, artist: &str, offset_ms: i64) -> Result<()> {
        if offset_ms < 0 {
            return Ok(());
        }
        let key = format!("lyr/{}", song_key_of(title, artist));
        self.scalar(&key, json!(offset_ms))
    }

    /// The person changed a synced setting. `key` must satisfy the scalar key schema; others are refused quietly.
    pub fn scalar(&self, key: &str, value: Value) -> Result<()> {
        if !self.enabled || validate_scalar(key, &value).is_err() {
            return Ok(());
        }
        self.queue(
            "scalar.set",
            json!({ "key": key, "value": value }),
            vec![scalar_key(key)],
        )
    }

    /// The person reset a synced setting to its default.
    pub fn scalar_cleared(&self, key: &str) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        self.queue("scalar.clear", json!({ "key": key }), vec![scalar_key(key)])
    }

    fn link(&self) -> Result<Option<meta::Link>> {
        if !self.enabled {
            return Ok(None);
        }
        meta::link(self.conn)
    }

    fn queue(&self, name: &str, args: Value, touches: Vec<String>) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        pending::append(self.conn, NewMutation::new(name, args, touches))?;
        Ok(())
    }

    fn playlist_sync_id(&self, local_id: i64) -> Result<Option<String>> {
        if !self.enabled {
            return Ok(None);
        }
        let found: Option<Option<String>> = self
            .conn
            .query_row(
                "SELECT syncId FROM playlists WHERE id = ?1",
                params![local_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(found.flatten())
    }

    fn entry_ids_in_order(&self, playlist_id: i64) -> Result<EntryOrder> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, syncId FROM playlistTracks WHERE playlistId = ?1 AND syncId IS NOT NULL
             ORDER BY position, id",
        )?;
        let rows = stmt.query_map(params![playlist_id], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut order = EntryOrder::default();
        for row in rows {
            let (row_id, entry) = row?;
            order.order.push(entry.clone());
            order.by_row.insert(row_id, entry);
        }
        Ok(order)
    }
}

#[derive(Default)]
struct EntryOrder {
    order: Vec<String>,
    by_row: HashMap<i64, String>,
}

/// The listen document `listen.record` carries.
pub(crate) fn listen_json(
    event_id: &str,
    ts: i64,
    song: &SongRef,
    played_s: i64,
    recorded: bool,
) -> Value {
    json!({ "eventId": event_id, "ts": ts, "ref": song, "playedS": played_s, "recorded": recorded })
}

/// The moves that turn `current` into `wanted`: entries on a longest increasing run stay, each other entry goes right after its predecessor.
fn moves_for(current: &[String], wanted: &[String]) -> Vec<(String, Value)> {
    let index: HashMap<&String, usize> =
        current.iter().enumerate().map(|(i, id)| (id, i)).collect();
    let positions: Vec<Option<usize>> = wanted.iter().map(|id| index.get(id).copied()).collect();
    let stay = longest_increasing_run(&positions);
    let mut moves = Vec::new();
    for (at, entry) in wanted.iter().enumerate() {
        if stay.contains(&at) || positions[at].is_none() {
            continue;
        }
        let place = match at.checked_sub(1) {
            Some(before) => json!({ "kind": "after", "id": wanted[before] }),
            None => json!({ "kind": "first" }),
        };
        moves.push((entry.clone(), place));
    }
    moves
}

fn longest_increasing_run(positions: &[Option<usize>]) -> std::collections::HashSet<usize> {
    let mut tails: Vec<(usize, usize)> = Vec::new();
    let mut previous: Vec<Option<usize>> = vec![None; positions.len()];
    for (at, position) in positions.iter().enumerate() {
        let Some(value) = *position else { continue };
        let slot = tails.partition_point(|(tail, _)| *tail < value);
        previous[at] = slot.checked_sub(1).map(|before| tails[before].1);
        if slot == tails.len() {
            tails.push((value, at));
        } else {
            tails[slot] = (value, at);
        }
    }
    let mut stay = std::collections::HashSet::new();
    let mut cursor = tails.last().map(|(_, at)| *at);
    while let Some(at) = cursor {
        stay.insert(at);
        cursor = previous[at];
    }
    stay
}

/// Queues a change of a synced setting (`pref/…`, `eq/…`, `want/…`, `lastfm/…`, `offline/…`). Does nothing when no server is configured or the key or value breaks the scalar schema.
pub fn record_scalar(db: &Db, key: &str, value: Value) -> Result<()> {
    record(db.connection(), |recorder| recorder.scalar(key, value))
        .map_err(super::error::SyncError::Db)
}

/// Queues the reset of a synced setting to its default.
pub fn clear_scalar(db: &Db, key: &str) -> Result<()> {
    record(db.connection(), |recorder| recorder.scalar_cleared(key))
        .map_err(super::error::SyncError::Db)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(text: &str) -> Vec<String> {
        text.chars().map(String::from).collect()
    }

    #[test]
    fn a_single_drag_is_a_single_move() {
        let moves = moves_for(&ids("abcde"), &ids("acdbe"));
        assert_eq!(moves.len(), 1);
        assert_eq!(moves[0].0, "b");
        assert_eq!(moves[0].1, json!({ "kind": "after", "id": "d" }));
    }

    #[test]
    fn moving_to_the_top_places_first() {
        let moves = moves_for(&ids("abc"), &ids("cab"));
        assert_eq!(moves, vec![("c".to_owned(), json!({ "kind": "first" }))]);
    }

    #[test]
    fn an_unchanged_order_queues_nothing() {
        assert!(moves_for(&ids("abc"), &ids("abc")).is_empty());
    }
}
