//! The library rules the clients share: a re-export keeps the song, a retag does not revise it.

use flaccy_library::fingerprint::fixtures::{info_tags, tone, wav_bytes};

use super::TestServer;

const REL: &str = "Drill Band/Rough Cuts/01 Opening.wav";

fn overwrite(server: &TestServer, title: &str, samples: usize, step: i16) {
    let tags = info_tags(title, "Drill Band", "Rough Cuts");
    std::thread::sleep(std::time::Duration::from_millis(30));
    std::fs::write(server.music().join(REL), wav_bytes(&tone(samples, step), Some(&tags))).unwrap();
}

#[tokio::test]
async fn a_re_export_keeps_the_song_its_playlists_and_its_plays_and_raises_the_revision() {
    let server = TestServer::new().await;
    server.standard_library();
    let id = server.song_id("Opening").await;
    let before = server.json("getSong", &format!("id={id}")).await;
    let song = before.envelope.song.unwrap();
    assert_eq!(song.flaccy_revision, Some(1));
    assert!(song.flaccy_revised_at.is_none());
    let old_fingerprint = song.flaccy_fingerprint.unwrap();

    server.json("scrobble", &format!("id={id}")).await.ok();
    server.json("createPlaylist", &format!("name=Keep&songId={id}")).await.ok();

    overwrite(&server, "Opening", 12000, 11);
    let summary = server.scan();
    assert_eq!(summary.new_versions, 1, "{summary:?}");

    let after = server.json("getSong", &format!("id={id}")).await;
    let song = after.ok().envelope.song.clone().unwrap();
    assert_eq!(song.id, id);
    assert_eq!(song.flaccy_revision, Some(2));
    assert!(song.flaccy_revised_at.as_deref().unwrap().ends_with('Z'));
    assert_ne!(song.flaccy_fingerprint.unwrap(), old_fingerprint);
    assert_eq!(song.duration, Some(2));
    assert_eq!(after.raw["song"]["playCount"], 1);

    let playlists = server.json("getPlaylists", "").await;
    let listed = playlists.envelope.playlists.unwrap().playlist.unwrap();
    assert_eq!(listed[0].song_count, Some(1));
    let playlist = server.json("getPlaylist", &format!("id={}", listed[0].id.clone().unwrap())).await;
    assert_eq!(playlist.raw["playlist"]["entry"][0]["id"], id);
    assert_eq!(playlist.raw["playlist"]["entry"][0]["flaccyRevision"], 2);

    let stable = server.scan();
    assert_eq!(stable.new_versions, 0, "{stable:?}");
    let again = server.json("getSong", &format!("id={id}")).await;
    assert_eq!(again.envelope.song.unwrap().flaccy_revision, Some(2));
}

#[tokio::test]
async fn a_retag_only_change_updates_the_title_and_keeps_revision_1() {
    let server = TestServer::new().await;
    server.standard_library();
    let id = server.song_id("Opening").await;

    overwrite(&server, "Opening (Remastered)", 8000, 7);
    let summary = server.scan();
    assert_eq!(summary.new_versions, 0, "{summary:?}");
    assert!(summary.retagged, "{summary:?}");

    let after = server.json("getSong", &format!("id={id}")).await;
    let song = after.ok().envelope.song.clone().unwrap();
    assert_eq!(song.title, "Opening (Remastered)");
    assert_eq!(song.flaccy_revision, Some(1));
    assert!(song.flaccy_revised_at.is_none());
}

#[tokio::test]
async fn new_files_join_and_removed_files_leave_on_the_next_scan() {
    let server = TestServer::new().await;
    server.standard_library();
    server.write_song("Zed/Third/02 Duet.wav", "Duet", "Zed", "Third", 8000, 3);
    std::fs::remove_file(server.music().join("The Echo/Second Light/02 Dim.wav")).unwrap();
    let summary = server.scan();
    assert_eq!((summary.added, summary.removed), (1, 1), "{summary:?}");
    let third = server.album_id("Third").await;
    let album = server.json("getAlbum", &format!("id={third}")).await;
    assert_eq!(album.envelope.album.unwrap().song.unwrap().len(), 2);
    let echo = server.album_id("Second Light").await;
    let album = server.json("getAlbum", &format!("id={echo}")).await;
    assert_eq!(album.envelope.album.unwrap().song.unwrap().len(), 1);
    assert_eq!(echo, server.album_id("Second Light").await);
}
