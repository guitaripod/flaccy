//! The move of the single-user server's playlists, stars, ratings, queue and plays into the owner's sync state.

use flaccy_library::db::{Db, NewTrack};
use flaccy_library::server_sync::song_key_of;
use flaccy_server_core::model::Source;
use flaccy_server_core::song::{entry_id, event_id_mig, playlist_id};

use super::rest_sync::owner;
use super::TestServer;
use crate::config::Config;
use crate::security::{Principal, Role};
use crate::store::{QueueRecord, Store};
use crate::sync::migrate_legacy::{self, MigrationReport, MARKER};

const OPENING: &str = "Drill Band/Rough Cuts/01 Opening.flac";
const MIDDLE: &str = "Drill Band/Rough Cuts/02 Middle.flac";
const GLOW: &str = "The Echo/Second Light/01 Glow.flac";
const GONE: &str = "Gone Band/Old Album/03 Missing.flac";

fn track(db: &Db, rel_path: &str, title: &str, artist: &str, album: &str, number: i32) {
    db.insert_track(&NewTrack {
        rel_path: rel_path.to_owned(),
        title: title.to_owned(),
        artist: artist.to_owned(),
        album: album.to_owned(),
        album_artist: None,
        track_number: number,
        duration: 61.0,
        codec: None,
        bit_depth: None,
        sample_rate: None,
        channels: None,
        artwork: None,
        signature: None,
        fingerprint: None,
    })
    .unwrap();
}

fn row_id(db: &Db, title: &str) -> i64 {
    db.fetch_all_tracks().iter().find(|row| row.title == title).unwrap().id
}

fn leave_an_old_server_behind(config: &Config) {
    let path = config.database_path();
    let db = Db::open(&path).unwrap();
    track(&db, OPENING, "Opening", "Drill Band", "Rough Cuts", 1);
    track(&db, MIDDLE, "Middle", "Drill Band", "Rough Cuts", 2);
    track(&db, GLOW, "Glow", "The Echo", "Second Light", 1);

    let mix = db.create_playlist("Mix").unwrap();
    db.add_tracks_to_playlist(mix, &[OPENING.to_owned(), MIDDLE.to_owned(), OPENING.to_owned(), GONE.to_owned()]).unwrap();
    let again = db.create_playlist("mix ").unwrap();
    db.add_tracks_to_playlist(again, &[GLOW.to_owned()]).unwrap();
    db.create_playlist("Empty").unwrap();

    db.set_loved(MIDDLE, true, None).unwrap();
    db.set_loved(GLOW, true, None).unwrap();
    for _ in 0..5 {
        db.increment_play_count(OPENING).unwrap();
    }
    db.insert_scrobble("Opening", "Drill Band", "Rough Cuts", 1_700_000_000, 61, true).unwrap();
    db.insert_scrobble("Opening", "Drill Band", "Rough Cuts", 1_700_000_100, 61, true).unwrap();
    db.insert_scrobble("Glow", "The Echo", "Second Light", 1_700_000_200, 61, true).unwrap();
    db.increment_play_count(GLOW).unwrap();

    let store = Store::open(&path).unwrap();
    store.set_rating(OPENING, Some(5)).unwrap();
    store.set_rating(GLOW, Some(3)).unwrap();
    store
        .save_play_queue(&QueueRecord {
            entries: vec![format!("s{}", row_id(&db, "Opening")), format!("s{}", row_id(&db, "Glow"))],
            current: Some(format!("s{}", row_id(&db, "Glow"))),
            position: 1234,
            changed_by: "old-phone".to_owned(),
            changed_at: "2026-10-25T18:30:00Z".to_owned(),
        })
        .unwrap();
}

async fn migrated_server() -> TestServer {
    TestServer::prepared("ffmpeg", leave_an_old_server_behind).await
}

#[tokio::test]
async fn the_old_playlists_arrive_with_the_derived_ids_and_their_dates() {
    let server = migrated_server().await;
    let user = owner(&server).await;
    let sync = &server.state.0.sync;

    let docs = sync.playlists_for(&user).await.unwrap();
    let names: Vec<&str> = docs.iter().map(|doc| doc.playlist.name.as_str()).collect();
    assert_eq!(docs.len(), 3, "{names:?}");

    let mix = docs.iter().find(|doc| doc.playlist.name == "Mix").unwrap();
    assert_eq!(mix.playlist.id, playlist_id("Mix", 0));
    let second = docs.iter().find(|doc| doc.playlist.name == "mix ").unwrap();
    assert_eq!(second.playlist.id, playlist_id("mix ", 1));

    let legacy = server.state.db().fetch_playlists();
    let created = legacy.iter().find(|row| row.name == "Mix").unwrap().created_at;
    assert_eq!(mix.playlist.created_at, created);

    let opening = song_key_of("Opening", "Drill Band");
    let kept: Vec<&str> = mix.visible().iter().map(|entry| entry.song.title.as_str()).collect();
    assert_eq!(kept, vec!["Opening", "Middle", "Opening", "Missing"]);
    let ids: Vec<String> = mix.visible().iter().map(|entry| entry.id.clone()).collect();
    assert_eq!(ids[0], entry_id(&mix.playlist.id, &opening, 0));
    assert_eq!(ids[2], entry_id(&mix.playlist.id, &opening, 1));
    let ghost = mix.visible()[3];
    assert_eq!(ghost.song.rel_path.as_deref(), Some(GONE));
    assert_eq!(ghost.song.album, "Old Album");
    assert_eq!(ghost.song.artist, "Gone Band");

    let shown = server.json("getPlaylist", &format!("id=pl-{}", mix.playlist.id)).await;
    assert_eq!(shown.raw["playlist"]["songCount"], 3, "the song the library lost is not listed");
}

#[tokio::test]
async fn stars_ratings_the_queue_and_plays_arrive_for_the_owner_only() {
    let server = migrated_server().await;
    let user = owner(&server).await;
    let sync = &server.state.0.sync;
    let state = sync.user_state(&user).await.unwrap();

    assert_eq!(state.loved.len(), 2);
    assert_eq!(state.loved[&song_key_of("Middle", "Drill Band")], 1_577_836_800_000);
    assert_eq!(state.ratings[&song_key_of("Opening", "Drill Band")], 5);
    assert_eq!(state.ratings[&song_key_of("Glow", "The Echo")], 3);
    assert_eq!(state.plays[&song_key_of("Glow", "The Echo")].count, 1);
    assert_eq!(state.plays[&song_key_of("Opening", "Drill Band")].count, 5);

    let sessions = sync.sessions_of(&user).await.unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].device, "legacy");
    assert_eq!(sessions[0].session["positionMs"], 1234);
    assert_eq!(sessions[0].stamp.wall_ms(), 1_792_953_000_000);
    let queue = server.json("getPlayQueue", "").await;
    assert_eq!(queue.raw["playQueue"]["changedBy"], "old-phone");
    assert_eq!(queue.raw["playQueue"]["position"], 1234);
    assert_eq!(queue.raw["playQueue"]["entry"].as_array().unwrap().len(), 2);
    assert_eq!(queue.raw["playQueue"]["current"], format!("s{}", row_id(&server.state.db(), "Glow")));

    let listens = sync.listens_after(&user, 0, 100).await.unwrap().listens;
    assert_eq!(listens.len(), 6);
    assert!(listens.iter().all(|row| row.listen.source == Source::Migrated && !row.listen.recorded));
    let real = event_id_mig(1_700_000_100, &flaccy_library::listen_history::title_key("Opening"), &flaccy_library::listen_history::artist_listen_key("Drill Band"));
    assert!(listens.iter().any(|row| row.listen.event_id == real && row.listen.ts == 1_700_000_100));

    let bob = server.state.0.security.create_user("bob", Role::Member).await.unwrap().id;
    assert_eq!(sync.playlists_for(&bob).await.unwrap().len(), 0);
    assert!(sync.user_state(&bob).await.unwrap().loved.is_empty());
}

#[tokio::test]
async fn the_move_is_marked_leaves_the_old_tables_alone_and_a_second_run_inserts_nothing() {
    let server = migrated_server().await;
    let user = owner(&server).await;
    let sync = &server.state.0.sync;
    assert_eq!(
        sync.meta_value(MARKER).await.unwrap().as_deref(),
        Some("3 playlists with 5 entries (1 named from their path only), 2 stars, 2 ratings, 6 plays (3 approximated from play counts), the saved queue")
    );

    let before = sync.stats().await.unwrap();
    let state_before = sync.user_state(&user).await.unwrap();
    let principal = Principal { user: user.clone(), role: Role::Admin, device: None };
    let head_before = sync.pull(&principal, "", 0, 1000, None).await.unwrap().head;

    let again = migrate_legacy::run(&server.state).await.unwrap();
    assert_eq!(again, MigrationReport::default());
    let after = sync.stats().await.unwrap();
    assert_eq!((after.playlists, after.entries, after.listens), (before.playlists, before.entries, before.listens));
    assert_eq!(sync.user_state(&user).await.unwrap(), state_before);
    let head_after = sync.pull(&principal, "", 0, 1000, None).await.unwrap().head;
    assert_eq!(head_after, head_before, "nothing changed, so nothing was announced");

    assert_eq!(server.state.db().fetch_playlists().len(), 3);
    assert_eq!(server.state.0.store.ratings().len(), 2);
    assert!(server.state.0.store.play_queue().is_some());
    assert_eq!(server.state.db().scrobble_count(), 3);
}

#[tokio::test]
async fn a_server_without_old_data_marks_itself_and_moves_nothing() {
    let server = TestServer::new().await;
    let sync = &server.state.0.sync;
    assert_eq!(sync.meta_value(MARKER).await.unwrap().as_deref(), Some("nothing to move"));
    assert_eq!(sync.stats().await.unwrap().playlists, 0);
}
