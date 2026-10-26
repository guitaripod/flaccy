use flaccy_server_core::song::{
    event_id_lfm, event_id_mig, event_id_rec, is_event_id, is_song_key, song_key,
};

#[test]
fn song_key_matches_the_documented_construction() {
    assert_eq!(
        song_key("artist", "title"),
        "b9462736abd2d6f17625aa8c96e05005"
    );
}

#[test]
fn song_key_separates_artist_from_title() {
    assert_ne!(song_key("ab", "c"), song_key("a", "bc"));
}

#[test]
fn song_key_is_32_lowercase_hex() {
    let key = song_key("a", "b");
    assert!(is_song_key(&key));
    assert!(!is_song_key(&key.to_uppercase()));
    assert!(!is_song_key("abc"));
}

#[test]
fn event_ids_are_24_hex_and_distinct_per_scheme() {
    let rec = event_id_rec("device", "instance", 7);
    let lfm = event_id_lfm("account", 1_790_000_000, &song_key("a", "b"));
    let mig = event_id_mig(1_790_000_000, "title", "artist");
    for id in [&rec, &lfm, &mig] {
        assert!(is_event_id(id), "{id}");
    }
    assert_ne!(rec, lfm);
    assert_ne!(lfm, mig);
}

#[test]
fn rec_ids_depend_on_the_counter() {
    assert_ne!(event_id_rec("d", "i", 1), event_id_rec("d", "i", 2));
    assert_eq!(event_id_rec("d", "i", 1), event_id_rec("d", "i", 1));
}

#[test]
fn rec_id_matches_the_documented_construction() {
    assert_eq!(event_id_rec("dev", "inst", 3), "774e544cb37f53a8a84bcc4b");
}
