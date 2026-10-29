use crate::client::Client;
use rand::seq::IndexedRandom;
use rand::Rng;

const SHARED_SECOND_BASE: i64 = 1_790_000_000;
const SHARED_SECOND_SPAN: i64 = 400;
const SPREAD_SECOND_SPAN: i64 = 5_000_000;
const HOT_SONGS: usize = 60;
const MAX_PLAYLISTS: usize = 36;
const MIN_PLAYLISTS: usize = 2;

type Outcome = Result<&'static str, String>;

/// Runs one random user action against the client's database.
pub fn step(client: &mut Client) -> Outcome {
    let playlists = client.db.fetch_playlists().len();
    let roll = client.rng.random_range(0..100);
    let result = match roll {
        0..=11 if playlists < MAX_PLAYLISTS => create_playlist(client),
        0..=11 => delete_playlist(client),
        12..=19 => rename_playlist(client),
        20..=25 if playlists > MIN_PLAYLISTS => delete_playlist(client),
        20..=47 => add_tracks(client),
        48..=55 => remove_entry(client),
        56..=65 => move_entry(client),
        66..=77 => love(client),
        78..=91 => listen(client),
        _ => lyric_offset(client),
    };
    result.map_err(|error| format!("{error}"))
}

type DbResult = Result<&'static str, rusqlite::Error>;

fn create_playlist(client: &mut Client) -> DbResult {
    let name = client.shared.next_playlist_name();
    let id = client.db.create_playlist(&name)?;
    if client.rng.random_bool(0.7) {
        let paths = pick_paths(client, 1, 6);
        client.db.add_tracks_to_playlist(id, &paths)?;
    }
    Ok("create_playlist")
}

fn rename_playlist(client: &mut Client) -> DbResult {
    if let Some(id) = pick_playlist(client) {
        let name = client.shared.next_playlist_name();
        client.db.rename_playlist(id, &name)?;
    }
    Ok("rename_playlist")
}

fn delete_playlist(client: &mut Client) -> DbResult {
    if let Some(id) = pick_playlist(client) {
        client.db.delete_playlist(id)?;
    }
    Ok("delete_playlist")
}

fn add_tracks(client: &mut Client) -> DbResult {
    if let Some(id) = pick_playlist(client) {
        let paths = pick_paths(client, 1, 5);
        match paths.as_slice() {
            [single] => client.db.add_track_to_playlist(id, single)?,
            many => client.db.add_tracks_to_playlist(id, many)?,
        }
    }
    Ok("add_tracks")
}

fn remove_entry(client: &mut Client) -> DbResult {
    if let Some(id) = pick_playlist(client) {
        let rows = client.db.playlist_tracks(id);
        if let Some(row) = rows.choose(&mut client.rng) {
            client.db.remove_playlist_track(row.row_id)?;
        }
    }
    Ok("remove_entry")
}

fn move_entry(client: &mut Client) -> DbResult {
    if let Some(id) = pick_playlist(client) {
        let mut order: Vec<i64> = client.db.playlist_tracks(id).iter().map(|row| row.row_id).collect();
        if order.len() >= 2 {
            let from = client.rng.random_range(0..order.len());
            let moved = order.remove(from);
            let to = client.rng.random_range(0..=order.len());
            order.insert(to, moved);
            client.db.reorder_playlist(id, &order)?;
        }
    }
    Ok("move_entry")
}

fn love(client: &mut Client) -> DbResult {
    let song = client.rng.random_range(0..HOT_SONGS);
    let loved = client.rng.random_bool(0.55);
    let path = client.shared.catalog.songs[song].rel_path.clone();
    client.db.set_loved(&path, loved, None)?;
    Ok("love")
}

fn listen(client: &mut Client) -> DbResult {
    let index = client.rng.random_range(0..client.shared.catalog.songs.len());
    let shared_second = client.rng.random_bool(0.3);
    let ts = if shared_second {
        SHARED_SECOND_BASE + client.rng.random_range(0..SHARED_SECOND_SPAN)
    } else {
        SHARED_SECOND_BASE + SHARED_SECOND_SPAN + client.rng.random_range(0..SPREAD_SECOND_SPAN)
    };
    let song = &client.shared.catalog.songs[index];
    client.db.insert_scrobble(&song.title, &song.artist, &song.album, ts, 180, false)?;
    Ok("listen")
}

fn lyric_offset(client: &mut Client) -> DbResult {
    let index = client.rng.random_range(0..crate::fixtures::LYRIC_SONGS);
    let offset = client.rng.random_range(0..5000);
    let song = &client.shared.catalog.songs[index];
    client.db.save_lyrics_offset(&song.title, &song.artist, offset)?;
    Ok("lyric_offset")
}

fn pick_playlist(client: &mut Client) -> Option<i64> {
    client.db.fetch_playlists().choose(&mut client.rng).map(|playlist| playlist.id)
}

fn pick_paths(client: &mut Client, low: usize, high: usize) -> Vec<String> {
    let count = client.rng.random_range(low..=high);
    (0..count)
        .map(|_| {
            let limit = if client.rng.random_bool(0.5) { HOT_SONGS } else { client.shared.catalog.songs.len() };
            let index = client.rng.random_range(0..limit);
            client.shared.catalog.songs[index].rel_path.clone()
        })
        .collect()
}
