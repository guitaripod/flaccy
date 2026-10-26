//! `export`: JSON, M3U8 and ListenBrainz-style JSONL from real stores, with names that need care.

mod common;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

use flaccy_library::listen_history::{artist_listen_key, title_key};
use flaccy_server::export::{self, Format, Subject};
use flaccy_server::export_m3u::Resolver;
use flaccy_server::security::Role;
use flaccy_server_core::song::song_key;
use rusqlite::Connection;
use serde_json::{json, Value};

use common::http::{Device, Harness};
use common::TempDir;

const OWNER: &str = "Zoë Ünï 夜";
const PLAYLIST: &str = "夜に駆ける / Mix: ★?";
const SECRET_SESSION_KEY: &str = "SESSION-KEY-MUST-NOT-LEAVE";

fn reference(artist: &str, title: &str, rel_path: Option<&str>) -> Value {
    json!({
        "songKey": song_key(&artist_listen_key(artist), &title_key(title)),
        "title": title,
        "artist": artist,
        "album": "Álbum ✓",
        "durationMs": 215_600,
        "relPath": rel_path,
    })
}

fn listen(event: char, ts: i64, song: &Value, recorded: bool) -> Value {
    json!({ "eventId": event.to_string().repeat(24), "ts": ts, "ref": song, "playedS": 200, "recorded": recorded })
}

struct Fixture {
    harness: Harness,
    owner: Device,
    subject: Subject,
}

async fn fixture() -> Fixture {
    let harness = Harness::start().await;
    let owner = harness.enroll(OWNER, Role::Member).await;
    let rain = reference("Ólafur Arnalds", "Saman", Some("Ólafur Arnalds/Island Songs/Saman.flac"));
    let known = reference("Björk", "Hyperballad", None);
    let missing = reference("Nobody", "Not Here\nTonight", None);
    let ledger = json!({ "listens": [
        listen('a', 1_700_000_000, &rain, false),
        listen('b', 1_700_000_000, &rain, true),
        listen('c', 1_700_000_100, &known, true),
        listen('d', 1_700_000_200, &missing, true),
    ] });
    let pushed = harness
        .push(
            &owner,
            1,
            vec![
                ("playlist.create", json!({ "id": "p1", "name": PLAYLIST, "entries": [{ "id": "e1", "ref": rain }, { "id": "e2", "ref": known }] })),
                ("entry.insert", json!({ "id": "e3", "playlist": "p1", "ref": missing, "place": { "kind": "after", "id": "e2" } })),
                ("playlist.create", json!({ "id": "p2", "name": PLAYLIST })),
                ("love.set", json!({ "songKey": rain["songKey"], "ref": rain, "loved": true })),
                ("rating.set", json!({ "songKey": known["songKey"], "ref": known, "rating": 5 })),
                ("scalar.set", json!({ "key": "pref/theme", "value": "dark" })),
                ("scalar.set", json!({ "key": "lastfm/session", "value": SECRET_SESSION_KEY })),
                ("session.save", json!({ "session": { "queue": ["Saman"], "positionMs": 1200 } })),
                ("listen.record", ledger),
            ],
        )
        .await;
    assert_eq!(pushed.status, 200, "{}", String::from_utf8_lossy(&pushed.body));
    let subject = Subject { id: owner.user.clone(), name: OWNER.to_owned() };
    Fixture { harness, owner, subject }
}

fn state_file(fixture: &Fixture) -> PathBuf {
    fixture.harness.dir.file("data/state.sqlite")
}

fn run(fixture: &Fixture, format: Format, resolver: &Resolver) -> (PathBuf, export::Exported) {
    let out = fixture.harness.dir.file("out");
    let exported = export::run(&state_file(fixture), &fixture.subject, format, &out, resolver).unwrap();
    (out, exported)
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn json_holds_the_users_data_and_no_secrets() {
    let fixture = fixture().await;
    let (_, exported) = run(&fixture, Format::Json, &Resolver::empty(Path::new("/music")));
    let text = read(&exported.files[0]);
    let document: Value = serde_json::from_str(&text).unwrap();
    assert_eq!((document["format"].clone(), document["version"].clone(), document["user"].clone()), (json!("flaccy-export"), json!(1), json!(OWNER)));
    let playlists = document["playlists"].as_array().unwrap();
    assert_eq!(playlists.len(), 2);
    let entries: Vec<&str> = playlists[0]["entries"].as_array().unwrap().iter().map(|entry| entry["id"].as_str().unwrap()).collect();
    assert_eq!((playlists[0]["name"].clone(), entries), (json!(PLAYLIST), vec!["e1", "e2", "e3"]));
    assert_eq!(playlists[0]["entries"][0]["ref"]["artist"], "Ólafur Arnalds");
    assert_eq!(playlists[1]["entries"].as_array().unwrap().len(), 0);
    assert_eq!(document["loves"].as_array().unwrap().len(), 1);
    assert_eq!(document["ratings"][0]["rating"], 5);
    let scalar_keys: Vec<&str> = document["scalars"].as_array().unwrap().iter().map(|scalar| scalar["key"].as_str().unwrap()).collect();
    assert_eq!(scalar_keys, ["pref/theme"]);
    assert_eq!(document["sessions"][0]["value"]["positionMs"], 1200);
    assert_eq!(exported.items, 2 + 1 + 1 + 1 + 1);
    for secret in [SECRET_SESSION_KEY, fixture.owner.token.as_str()] {
        assert!(!text.contains(secret), "the export leaks {secret}");
    }
    fixture.harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn m3u8_writes_one_safe_file_per_playlist_with_paths_a_player_can_follow() {
    let fixture = fixture().await;
    let music = fixture.harness.dir.file("music");
    let resolver = Resolver::from_tracks(
        &music,
        [
            ("Ólafur Arnalds".to_owned(), "Saman".to_owned(), "Ólafur Arnalds/Island Songs/Saman.flac".to_owned()),
            ("Björk".to_owned(), "Hyperballad".to_owned(), "Björk/Post/04 Hyperballad.flac".to_owned()),
        ],
    );
    let (out, exported) = run(&fixture, Format::M3u8, &resolver);
    let names: Vec<String> = exported.files.iter().map(|file| file.file_name().unwrap().to_string_lossy().into_owned()).collect();
    assert_eq!(names, ["夜に駆ける _ Mix_ ★_.m3u8", "夜に駆ける _ Mix_ ★_ (2).m3u8"]);
    let lines: Vec<String> = read(&exported.files[0]).lines().map(str::to_owned).collect();
    let canonical_out = std::fs::canonicalize(&out).unwrap();
    let canonical_music = std::fs::canonicalize(&music).unwrap();
    let to_music = flaccy_server::export_m3u::relative_path(&canonical_out, &canonical_music);
    assert_eq!(lines[0], "#EXTM3U");
    assert_eq!(lines[1], format!("#PLAYLIST:{PLAYLIST}"));
    assert_eq!(lines[2], "#EXTINF:216,Ólafur Arnalds - Saman");
    assert_eq!(lines[3], to_music.join("Ólafur Arnalds/Island Songs/Saman.flac").to_string_lossy());
    assert_eq!(lines[4], "#EXTINF:216,Björk - Hyperballad");
    assert_eq!(lines[5], to_music.join("Björk/Post/04 Hyperballad.flac").to_string_lossy());
    assert_eq!(lines[6], "# Nobody - Not Here Tonight (not in this library)");
    assert_eq!(lines.len(), 7);
    assert_eq!(read(&exported.files[1]).lines().count(), 2, "an empty playlist is a header only");
    assert!(std::fs::read_dir(&out).unwrap().flatten().all(|entry| !entry.file_name().to_string_lossy().ends_with(".partial")));
    fixture.harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn m3u8_without_a_library_turns_every_entry_into_a_comment() {
    let fixture = fixture().await;
    let (_, exported) = run(&fixture, Format::M3u8, &Resolver::empty(Path::new("/nowhere")));
    let lines: Vec<String> = read(&exported.files[0]).lines().map(str::to_owned).collect();
    assert!(lines[2..].iter().all(|line| line.starts_with("# ") && line.ends_with("(not in this library)")), "{lines:?}");
    fixture.harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn jsonl_lists_unsuppressed_listens_oldest_first_in_listenbrainz_shape() {
    let fixture = fixture().await;
    let (_, exported) = run(&fixture, Format::Jsonl, &Resolver::empty(Path::new("/music")));
    assert_eq!(exported.files[0].file_name().unwrap().to_string_lossy(), "listens-Zoë Ünï 夜.jsonl");
    let lines: Vec<Value> = read(&exported.files[0]).lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(exported.items, 3, "the suppressed duplicate is skipped");
    assert_eq!(lines[0], json!({ "listened_at": 1_700_000_000, "track_metadata": { "artist_name": "Ólafur Arnalds", "track_name": "Saman", "release_name": "Álbum ✓" } }));
    assert_eq!(lines.iter().map(|line| line["listened_at"].as_i64().unwrap()).collect::<Vec<_>>(), [1_700_000_000, 1_700_000_100, 1_700_000_200]);
    assert_eq!(lines[2]["track_metadata"]["track_name"], "Not Here\nTonight");
    fixture.harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn another_users_data_is_not_in_the_export() {
    let fixture = fixture().await;
    let other = fixture.harness.enroll("mallory", Role::Member).await;
    let nobody = Subject { id: other.user.clone(), name: "mallory".to_owned() };
    let out = fixture.harness.dir.file("out");
    let exported = export::run(&state_file(&fixture), &nobody, Format::Jsonl, &out, &Resolver::empty(Path::new("/m"))).unwrap();
    assert_eq!(exported.items, 0);
    assert!(read(&exported.files[0]).is_empty());
    fixture.harness.stop().await;
}

fn peak_memory_kib() -> u64 {
    read(Path::new("/proc/self/status"))
        .lines()
        .find_map(|line| line.strip_prefix("VmHWM:"))
        .and_then(|rest| rest.trim().trim_end_matches("kB").trim().parse().ok())
        .unwrap_or(0)
}

fn fill_listens(path: &Path, user: &str, count: usize) {
    let mut connection = Connection::open(path).unwrap();
    let transaction = connection.transaction().unwrap();
    {
        let mut insert = transaction
            .prepare(
                "INSERT INTO listens(event_id, user_id, ts, song_key, title_key, artist_key, ref_json, played_s, source, recorded, device_id, suppressed, seq)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 200, 'flaccy', 1, 'd', ?8, ?9)",
            )
            .unwrap();
        for index in 0..count {
            let song = json!({ "songKey": format!("{index:032x}"), "title": format!("Título {index} 夜"), "artist": format!("Artista {}", index % 997), "album": "Álbum" });
            insert
                .execute(rusqlite::params![format!("{index:024x}"), user, 1_500_000_000 + index as i64, format!("{index:032x}"), "t", "a", song.to_string(), index % 10 == 0, index as i64])
                .unwrap();
        }
    }
    transaction.commit().unwrap();
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "builds 200,000 listens; run with --release --ignored --nocapture"]
async fn two_hundred_thousand_listens_export_in_seconds_without_holding_them_in_memory() {
    let dir = TempDir::new("big-export");
    let state = dir.file("state.sqlite");
    let store = flaccy_server::sync::Store::open(&state, "incarnation".to_owned()).await.unwrap();
    store.close().await.unwrap();
    fill_listens(&state, "user-1", 200_000);
    let subject = Subject { id: "user-1".to_owned(), name: "big".to_owned() };
    let memory_before = peak_memory_kib();
    let started = Instant::now();
    let exported = export::run(&state, &subject, Format::Jsonl, &dir.file("out"), &Resolver::empty(Path::new("/m"))).unwrap();
    let elapsed = started.elapsed();
    let growth_kib = peak_memory_kib().saturating_sub(memory_before);
    let mut report = std::io::stdout();
    writeln!(report, "exported {} listens in {:.2?}; peak memory grew {} KiB", exported.items, elapsed, growth_kib).unwrap();
    assert_eq!(exported.items, 180_000);
    assert_eq!(read(&exported.files[0]).lines().count(), 180_000);
    assert!(elapsed.as_secs() < 10, "{elapsed:?}");
    assert!(growth_kib < 100 * 1024, "peak memory grew {growth_kib} KiB");
}
