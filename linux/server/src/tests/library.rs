//! Browsing, lists, annotations, playlists, covers, lyrics and the play queue.

use flaccy_library::db::{Db, LyricsContent};

use super::TestServer;

#[tokio::test]
async fn album_lists_page_and_sort_by_every_type() {
    let server = TestServer::new();
    server.standard_library();

    let first = server.json("getAlbumList2", "type=alphabeticalByName&size=2&offset=0").await;
    let names: Vec<String> = first.envelope.album_list2.unwrap().album.unwrap().into_iter().map(|a| a.name).collect();
    assert_eq!(names, vec!["Rough Cuts", "Second Light"]);

    let rest = server.json("getAlbumList2", "type=alphabeticalByName&size=2&offset=2").await;
    let names: Vec<String> = rest.envelope.album_list2.unwrap().album.unwrap().into_iter().map(|a| a.name).collect();
    assert_eq!(names, vec!["Third"]);

    let beyond = server.json("getAlbumList2", "type=alphabeticalByName&size=2&offset=9").await;
    assert!(beyond.ok().envelope.album_list2.as_ref().unwrap().album.is_none());

    let by_artist = server.json("getAlbumList2", "type=alphabeticalByArtist&size=500").await;
    let artists: Vec<String> = by_artist
        .envelope
        .album_list2
        .unwrap()
        .album
        .unwrap()
        .into_iter()
        .map(|a| a.artist.unwrap())
        .collect();
    assert_eq!(artists, vec!["Drill Band", "The Echo", "Zed"]);

    for kind in ["random", "newest"] {
        let answer = server.json("getAlbumList2", &format!("type={kind}&size=9999")).await;
        assert_eq!(answer.envelope.album_list2.unwrap().album.unwrap().len(), 3, "{kind}");
    }
    for kind in ["frequent", "recent", "starred"] {
        let answer = server.json("getAlbumList2", &format!("type={kind}")).await;
        assert!(answer.ok().envelope.album_list2.as_ref().unwrap().album.is_none(), "{kind}");
    }
    assert_eq!(server.json("getAlbumList2", "type=sideways").await.error_code(), 0);
    assert_eq!(server.json("getAlbumList2", "").await.error_code(), 10);
    assert_eq!(server.json("getAlbumList2", "type=byYear&fromYear=2000").await.error_code(), 10);
    let empty_year = server.json("getAlbumList2", "type=byYear&fromYear=2000&toYear=2001").await;
    assert!(empty_year.ok().envelope.album_list2.as_ref().unwrap().album.is_none());
    let empty_genre = server.json("getAlbumList2", "type=byGenre&genre=Jazz").await;
    assert!(empty_genre.ok().envelope.album_list2.as_ref().unwrap().album.is_none());
}

#[tokio::test]
async fn an_album_lists_its_songs_in_track_order_with_every_field() {
    let server = TestServer::new();
    server.standard_library();
    let album_id = server.album_id("Rough Cuts").await;
    let answer = server.json("getAlbum", &format!("id={album_id}")).await;
    let album = answer.ok().envelope.album.clone().unwrap();
    assert_eq!(album.info.song_count, Some(3));
    assert_eq!(album.info.artist.as_deref(), Some("Drill Band"));
    assert!(album.info.id.starts_with("al-") && album.info.id.len() == 19);
    let songs = album.song.unwrap();
    let titles: Vec<&str> = songs.iter().map(|song| song.title.as_str()).collect();
    assert_eq!(titles, vec!["Opening", "Middle", "Closing"]);
    let tracks: Vec<Option<i64>> = songs.iter().map(|song| song.track).collect();
    assert_eq!(tracks, vec![Some(1), Some(2), Some(3)]);

    let first = &songs[0];
    assert!(first.id.starts_with('s'));
    assert_eq!(first.parent.as_deref(), Some(album_id.as_str()));
    assert_eq!(first.album_id.as_deref(), Some(album_id.as_str()));
    assert_eq!(first.cover_art.as_deref(), Some(album_id.as_str()));
    assert_eq!(first.suffix.as_deref(), Some("wav"));
    assert_eq!(first.content_type.as_deref(), Some("audio/x-wav"));
    assert_eq!(first.kind.as_deref(), Some("music"));
    assert_eq!(first.bit_depth, Some(16));
    assert_eq!(first.sampling_rate, Some(8000));
    assert_eq!(first.channel_count, Some(1));
    assert_eq!(first.duration, Some(1));
    assert!((128..=130).contains(&first.bit_rate.unwrap()), "{:?}", first.bit_rate);
    assert_eq!(first.path.as_deref(), Some("Drill Band/Rough Cuts/01 Opening.wav"));
    assert_eq!(first.flaccy_revision, Some(1));
    assert!(first.flaccy_revised_at.is_none());
    assert!(first.flaccy_fingerprint.as_deref().unwrap().starts_with("sha256:"));
    assert!(first.created.as_deref().unwrap().ends_with('Z'));
    assert_eq!(answer.raw["album"]["song"][0]["isDir"], false);
    assert_eq!(answer.raw["album"]["song"][0]["mediaType"], "song");
    assert_eq!(answer.raw["album"]["song"][0]["playCount"], 0);

    assert_eq!(server.json("getAlbum", "id=al-0000000000000000").await.error_code(), 70);
    assert_eq!(server.json("getAlbum", "").await.error_code(), 10);
}

#[tokio::test]
async fn artists_are_indexed_by_letter_ignoring_the_and_each_lists_its_albums() {
    let server = TestServer::new();
    server.standard_library();
    let artists = server.json("getArtists", "").await;
    let indexes = artists.envelope.artists.unwrap().index.unwrap();
    let letters: Vec<&str> = indexes.iter().map(|index| index.name.as_deref().unwrap()).collect();
    assert_eq!(letters, vec!["D", "E", "Z"]);
    let echo = &indexes[1].artist.as_ref().unwrap()[0];
    assert_eq!(echo.name.as_deref(), Some("The Echo"));
    assert_eq!(echo.album_count, Some(1));

    let via_indexes = server.json("getIndexes", "").await;
    assert_eq!(via_indexes.raw["indexes"]["index"].as_array().unwrap().len(), 3);

    let artist = server.json("getArtist", &format!("id={}", echo.id.as_ref().unwrap())).await;
    assert_eq!(artist.raw["artist"]["name"], "The Echo");
    assert_eq!(artist.raw["artist"]["album"][0]["name"], "Second Light");
    assert_eq!(server.json("getArtist", "id=ar-0000000000000000").await.error_code(), 70);
}

#[tokio::test]
async fn search_with_an_empty_query_returns_everything_paged_by_count_and_offset() {
    let server = TestServer::new();
    server.standard_library();
    let everything = server.json("search3", "query=&songCount=100").await;
    let result = everything.envelope.search_result3.unwrap();
    assert_eq!(result.song.unwrap().len(), 6);
    assert_eq!(result.album.unwrap().len(), 3);
    assert_eq!(result.artist.unwrap().len(), 3);

    let quoted = server.json("search3", "query=%22%22&songCount=100").await;
    assert_eq!(quoted.envelope.search_result3.unwrap().song.unwrap().len(), 6);

    let second_page = server.json("search3", "query=&songCount=2&songOffset=2&albumCount=1&albumOffset=1&artistCount=0").await;
    let result = second_page.envelope.search_result3.unwrap();
    let titles: Vec<String> = result.song.unwrap().into_iter().map(|song| song.title).collect();
    assert_eq!(titles, vec!["Closing", "Glow"]);
    assert_eq!(result.album.unwrap()[0].name, "Second Light");
    assert!(result.artist.is_none());

    let default_page = server.json("search3", "").await;
    assert_eq!(default_page.envelope.search_result3.unwrap().song.unwrap().len(), 6);
}

#[tokio::test]
async fn search_finds_by_any_word_of_title_artist_or_album() {
    let server = TestServer::new();
    server.standard_library();
    let by_artist = server.json("search3", "query=echo").await;
    let songs = by_artist.envelope.search_result3.unwrap().song.unwrap();
    assert_eq!(songs.len(), 2);
    let narrow = server.json("search3", "query=echo+dim").await;
    assert_eq!(narrow.envelope.search_result3.unwrap().song.unwrap().len(), 1);
    let nothing = server.json("search3", "query=zzzz").await;
    let result = nothing.ok().envelope.search_result3.as_ref().unwrap();
    assert!(result.song.is_none() && result.album.is_none() && result.artist.is_none());
}

#[tokio::test]
async fn single_and_random_songs() {
    let server = TestServer::new();
    server.standard_library();
    let id = server.song_id("Solo").await;
    let song = server.json("getSong", &format!("id={id}")).await;
    assert_eq!(song.envelope.song.unwrap().title, "Solo");
    assert_eq!(server.json("getSong", "id=s999999").await.error_code(), 70);
    assert_eq!(server.json("getSong", "id=banana").await.error_code(), 70);

    let random = server.json("getRandomSongs", "size=4").await;
    assert_eq!(random.raw["randomSongs"]["song"].as_array().unwrap().len(), 4);
    let all = server.json("getRandomSongs", "size=500").await;
    assert_eq!(all.raw["randomSongs"]["song"].as_array().unwrap().len(), 6);
}

#[tokio::test]
async fn scrobble_counts_plays_and_now_playing_does_not() {
    let server = TestServer::new();
    server.standard_library();
    let id = server.song_id("Opening").await;
    let before = server.json("getSong", &format!("id={id}")).await;
    assert_eq!(before.raw["song"]["playCount"], 0);
    assert!(before.raw["song"].get("played").is_none());

    server.json("scrobble", &format!("id={id}&submission=false")).await.ok();
    let still = server.json("getSong", &format!("id={id}")).await;
    assert_eq!(still.raw["song"]["playCount"], 0);

    server.json("scrobble", &format!("id={id}&time=1700000000000&submission=true")).await.ok();
    server.json("scrobble", &format!("id={id}")).await.ok();
    let after = server.json("getSong", &format!("id={id}")).await;
    assert_eq!(after.raw["song"]["playCount"], 2);
    assert!(after.raw["song"]["played"].as_str().unwrap().ends_with('Z'));

    let album = server.album_id("Rough Cuts").await;
    let listed = server.json("getAlbumList2", "type=frequent").await;
    assert_eq!(listed.envelope.album_list2.unwrap().album.unwrap()[0].id, album);
    let recent = server.json("getAlbumList2", "type=recent").await;
    assert_eq!(recent.envelope.album_list2.unwrap().album.unwrap().len(), 1);

    let stored = server.state.db().fetch_all_tracks();
    let row = stored.iter().find(|row| row.title == "Opening").unwrap();
    assert_eq!(row.play_count, 2);
    assert_eq!(server.json("scrobble", "id=s999999").await.error_code(), 70);
    assert_eq!(server.json("scrobble", "").await.error_code(), 10);
}

#[tokio::test]
async fn star_and_unstar_set_and_clear_loved() {
    let server = TestServer::new();
    server.standard_library();
    let id = server.song_id("Middle").await;
    server.json("star", &format!("id={id}")).await.ok();
    let starred = server.json("getSong", &format!("id={id}")).await;
    assert!(starred.raw["song"]["starred"].as_str().unwrap().ends_with('Z'));
    let list = server.json("getStarred2", "").await;
    assert_eq!(list.raw["starred2"]["song"].as_array().unwrap().len(), 1);
    assert!(server.state.db().fetch_all_tracks().iter().any(|row| row.title == "Middle" && row.loved));

    let album = server.album_id("Rough Cuts").await;
    server.json("star", &format!("albumId={album}")).await.ok();
    server.json("star", &format!("id={album}")).await.ok();

    server.json("unstar", &format!("id={id}")).await.ok();
    let cleared = server.json("getSong", &format!("id={id}")).await;
    assert!(cleared.raw["song"].get("starred").is_none());
    let empty = server.json("getStarred2", "").await;
    assert!(empty.ok().raw["starred2"].get("song").is_none());
    assert_eq!(server.json("star", "").await.error_code(), 10);
    assert_eq!(server.json("star", "id=s999999").await.error_code(), 70);
}

#[tokio::test]
async fn an_album_with_every_song_loved_is_starred() {
    let server = TestServer::new();
    server.standard_library();
    for title in ["Glow", "Dim"] {
        let id = server.song_id(title).await;
        server.json("star", &format!("id={id}")).await.ok();
    }
    let listed = server.json("getAlbumList2", "type=starred").await;
    let albums = listed.envelope.album_list2.unwrap().album.unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].name, "Second Light");
    let starred = server.json("getStarred2", "").await;
    assert_eq!(starred.raw["starred2"]["album"][0]["name"], "Second Light");
}

#[tokio::test]
async fn ratings_are_stored_per_song_and_zero_removes_them() {
    let server = TestServer::new();
    server.standard_library();
    let id = server.song_id("Dim").await;
    server.json("setRating", &format!("id={id}&rating=4")).await.ok();
    let rated = server.json("getSong", &format!("id={id}")).await;
    assert_eq!(rated.raw["song"]["userRating"], 4);
    assert_eq!(server.state.0.store.ratings().values().copied().collect::<Vec<_>>(), vec![4]);
    server.json("setRating", &format!("id={id}&rating=0")).await.ok();
    let cleared = server.json("getSong", &format!("id={id}")).await;
    assert!(cleared.raw["song"].get("userRating").is_none());
    assert_eq!(server.json("setRating", &format!("id={id}&rating=9")).await.error_code(), 0);
    assert_eq!(server.json("setRating", &format!("id={id}")).await.error_code(), 10);
}

#[tokio::test]
async fn a_playlist_round_trips_through_create_update_and_delete() {
    let server = TestServer::new();
    server.standard_library();
    let opening = server.song_id("Opening").await;
    let middle = server.song_id("Middle").await;
    let solo = server.song_id("Solo").await;

    let created = server
        .json("createPlaylist", &format!("name=Mix&songId={opening}&songId={middle}"))
        .await;
    let playlist = created.raw["playlist"].clone();
    let id = playlist["id"].as_str().unwrap().to_string();
    assert!(id.starts_with('p'));
    assert_eq!(playlist["name"], "Mix");
    assert_eq!(playlist["songCount"], 2);
    assert_eq!(playlist["entry"].as_array().unwrap().len(), 2);

    let listed = server.json("getPlaylists", "").await;
    let all = listed.envelope.playlists.unwrap().playlist.unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].song_count, Some(2));
    assert_eq!(all[0].owner.as_deref(), Some("tester"));

    server
        .json(
            "updatePlaylist",
            &format!("playlistId={id}&name=Renamed&songIdToAdd={solo}&songIndexToRemove=0"),
        )
        .await
        .ok();
    let updated = server.json("getPlaylist", &format!("id={id}")).await;
    assert_eq!(updated.raw["playlist"]["name"], "Renamed");
    let titles: Vec<&str> = updated.raw["playlist"]["entry"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, vec!["Middle", "Solo"]);

    let replaced = server
        .json("createPlaylist", &format!("playlistId={id}&songId={opening}"))
        .await;
    assert_eq!(replaced.raw["playlist"]["songCount"], 1);

    server.json("deletePlaylist", &format!("id={id}")).await.ok();
    let gone = server.json("getPlaylists", "").await;
    assert!(gone.ok().envelope.playlists.as_ref().unwrap().playlist.is_none());
    assert_eq!(server.json("getPlaylist", &format!("id={id}")).await.error_code(), 70);
    assert_eq!(server.json("deletePlaylist", &format!("id={id}")).await.error_code(), 70);
    assert_eq!(server.json("createPlaylist", "").await.error_code(), 10);
    assert_eq!(server.json("createPlaylist", "name=X&songId=s999999").await.error_code(), 70);
}

#[tokio::test]
async fn the_play_queue_is_saved_and_read_back() {
    let server = TestServer::new();
    server.standard_library();
    let empty = server.json("getPlayQueue", "").await;
    assert!(empty.ok().raw.get("playQueue").is_none());

    let opening = server.song_id("Opening").await;
    let glow = server.song_id("Glow").await;
    server
        .json("savePlayQueue", &format!("id={opening}&id={glow}&current={glow}&position=42000"))
        .await
        .ok();
    let queue = server.json("getPlayQueue", "").await;
    let saved = &queue.raw["playQueue"];
    assert_eq!(saved["current"], glow);
    assert_eq!(saved["position"], 42000);
    assert_eq!(saved["changedBy"], "tests");
    assert_eq!(saved["username"], "tester");
    assert_eq!(saved["entry"].as_array().unwrap().len(), 2);
    assert_eq!(server.json("savePlayQueue", "id=s999999").await.error_code(), 70);
}

#[tokio::test]
async fn lyrics_come_from_what_the_library_has() {
    let server = TestServer::new();
    server.standard_library();
    let id = server.song_id("Opening").await;
    let none = server.json("getLyricsBySongId", &format!("id={id}")).await;
    assert!(none.ok().raw["lyricsList"].get("structuredLyrics").is_none());

    Db::open(&server.state.0.config.database_path())
        .unwrap()
        .save_lyrics(
            "Opening",
            "Drill Band",
            &LyricsContent {
                synced: Some("[00:01.00]first line\n[00:02.50]second line".to_string()),
                plain: None,
                lyricsfile: None,
                instrumental: false,
                revision: 1,
            },
        )
        .unwrap();
    let synced = server.json("getLyricsBySongId", &format!("id={id}")).await;
    let lyrics = &synced.ok().raw["lyricsList"]["structuredLyrics"][0];
    assert_eq!(lyrics["synced"], true);
    assert_eq!(lyrics["displayTitle"], "Opening");
    assert_eq!(lyrics["line"][0], serde_json::json!({"start": 1000, "value": "first line"}));
    assert_eq!(lyrics["line"][1]["start"], 2500);

    let xml = server
        .get(&format!("/rest/getLyricsBySongId?{}&id={id}", TestServer::login()))
        .await
        .text();
    assert!(xml.contains("<line start=\"1000\">first line</line>"), "{xml}");
}
