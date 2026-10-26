use flaccy_server_core::song::song_key;
use flaccy_server_core_ffi::*;
use serde_json::{json, Value};
use std::path::PathBuf;

const WRITE_VARIABLE: &str = "FLACCY_WRITE_SWIFT_CASES";
const COVER_HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn cases_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Core/FlaccyServerCore/Tests/FlaccyServerCoreTests/Resources/cases.json")
}

fn alice() -> Value {
    json!({ "user": "alice", "role": "member", "device": "phone" })
}

fn bob() -> Value {
    json!({ "user": "bob", "role": "member", "device": "tablet" })
}

fn guest() -> Value {
    json!({ "user": "gus", "role": "guest", "device": "kiosk" })
}

fn song(index: usize) -> Value {
    let key = song_key(&format!("artist{index}"), &format!("title{index}"));
    json!({
        "songKey": key,
        "title": format!("Title {index}"),
        "artist": format!("Artist {index}"),
        "album": "Album",
        "durationMs": 200_000 + index,
        "fp": null,
        "mbid": null,
        "albumKey": null,
        "relPath": format!("a/{index}.flac"),
    })
}

fn mutation(id: i64, name: &str, stamp: i64, args: Value) -> Value {
    json!({ "id": id, "name": name, "stamp": stamp, "args": args })
}

fn pending(mutation: &Value, failed: bool) -> Value {
    json!({ "mutation": mutation, "failed": failed })
}

fn new_entry(id: &str, index: usize) -> Value {
    json!({ "id": id, "ref": song(index) })
}

fn invoke(function: &str, input: &Value) -> Result<String, ServerCoreFfiError> {
    let input = input.to_string();
    match function {
        "applyPlaylist" => apply_playlist(input),
        "applyScalar" => apply_scalar(input),
        "rebasePlaylist" => rebase_playlist(input),
        "rebaseLove" => rebase_love(input),
        "rebaseRating" => rebase_rating(input),
        "rebaseScalar" => rebase_scalar(input),
        "rebaseSession" => rebase_session(input),
        "between" => between(input),
        "songKey" => song_key_export(input),
        "suppressedFlags" => suppressed_flags(input),
        "nextStamp" => next_stamp(input),
        other => panic!("unknown function {other}"),
    }
}

fn song_key_export(input: String) -> Result<String, ServerCoreFfiError> {
    flaccy_server_core_ffi::song_key(input)
}

fn expected_of(answer: Result<String, ServerCoreFfiError>) -> Value {
    match answer {
        Ok(document) => serde_json::from_str(&document).unwrap(),
        Err(ServerCoreFfiError::Message(message)) => json!({ "error": message }),
    }
}

#[derive(Default)]
struct Cases {
    list: Vec<Value>,
}

impl Cases {
    fn add(&mut self, name: &str, function: &str, input: Value) -> Value {
        let expected = expected_of(invoke(function, &input));
        self.list.push(json!({
            "name": name,
            "function": function,
            "input": input,
            "expected": expected,
        }));
        expected
    }

    fn playlist(
        &mut self,
        name: &str,
        doc: &Value,
        mutation: Value,
        caller: Value,
        stamp: Option<i64>,
    ) -> Value {
        let mut input = json!({ "doc": doc, "mutation": mutation, "caller": caller });
        if let Some(stamp) = stamp {
            input["stamp"] = json!(stamp);
        }
        self.add(name, "applyPlaylist", input)
    }

    fn scalar(&mut self, name: &str, scalar: &Value, mutation: Value) -> Value {
        let input = json!({ "scalar": scalar, "mutation": mutation, "caller": alice() });
        self.add(name, "applyScalar", input)
    }
}

fn playlist_cases(cases: &mut Cases) {
    let create = mutation(
        1,
        "playlist.create",
        100,
        json!({ "id": "p1", "name": "Mix", "entries": [new_entry("e1", 1), new_entry("e2", 2)] }),
    );
    let created = cases.playlist(
        "create with two entries",
        &Value::Null,
        create.clone(),
        alice(),
        None,
    );
    let doc = created["doc"].clone();
    cases.playlist(
        "create again is a noop for the owner",
        &doc,
        create.clone(),
        alice(),
        None,
    );
    cases.playlist(
        "create over another user's playlist is forbidden",
        &doc,
        create,
        bob(),
        None,
    );
    let rename = |stamp: i64| {
        mutation(
            2,
            "playlist.rename",
            stamp,
            json!({ "id": "p1", "name": "Renamed" }),
        )
    };
    let renamed = cases.playlist("rename", &doc, rename(200), alice(), None);
    cases.playlist(
        "rename with an older stamp is a noop",
        &doc,
        rename(50),
        alice(),
        None,
    );
    cases.playlist(
        "rename of an unknown playlist is invalid",
        &Value::Null,
        rename(200),
        alice(),
        None,
    );
    cases.playlist(
        "rename takes the stored stamp when given",
        &doc,
        rename(60),
        alice(),
        Some(900),
    );
    let cover = mutation(
        3,
        "playlist.setCover",
        210,
        json!({ "id": "p1", "blob": COVER_HASH }),
    );
    let covered = cases.playlist("set cover", &doc, cover, alice(), None);
    let clear = mutation(4, "playlist.clearCover", 220, json!({ "id": "p1" }));
    cases.playlist("clear cover", &covered["doc"], clear, alice(), None);
    let delete = mutation(5, "playlist.delete", 230, json!({ "id": "p1" }));
    let deleted = cases.playlist("delete", &renamed["doc"], delete, alice(), None);
    let restore = mutation(6, "playlist.restore", 240, json!({ "id": "p1" }));
    cases.playlist("restore", &deleted["doc"], restore, alice(), None);
    let household = mutation(
        7,
        "playlist.setVisibility",
        250,
        json!({ "id": "p1", "visibility": "household" }),
    );
    cases.playlist(
        "household visibility by the owner",
        &doc,
        household.clone(),
        alice(),
        None,
    );
    cases.playlist(
        "visibility by a guest is forbidden",
        &doc,
        household,
        guest(),
        None,
    );
}

fn entry_cases(cases: &mut Cases) {
    let create = mutation(
        1,
        "playlist.create",
        100,
        json!({ "id": "p1", "name": "Mix", "entries": [new_entry("e1", 1), new_entry("e2", 2)] }),
    );
    let doc = cases.playlist("entry base", &Value::Null, create, alice(), None)["doc"].clone();
    let insert = |place: Value| {
        mutation(
            8,
            "entry.insert",
            300,
            json!({ "id": "e3", "playlist": "p1", "ref": song(3), "place": place }),
        )
    };
    cases.playlist(
        "insert first",
        &doc,
        insert(json!({ "kind": "first" })),
        alice(),
        None,
    );
    let after = cases.playlist(
        "insert after an anchor",
        &doc,
        insert(json!({ "kind": "after", "id": "e1" })),
        alice(),
        None,
    );
    cases.playlist(
        "insert before an anchor",
        &doc,
        insert(json!({ "kind": "before", "id": "e2" })),
        alice(),
        None,
    );
    cases.playlist(
        "insert after an unknown anchor is invalid",
        &doc,
        insert(json!({ "kind": "after", "id": "ghost" })),
        alice(),
        None,
    );
    let many = mutation(
        9,
        "entry.insertMany",
        310,
        json!({ "playlist": "p1", "entries": [new_entry("e4", 4), new_entry("e5", 5)], "place": { "kind": "last" } }),
    );
    cases.playlist("insert many at the end", &after["doc"], many, alice(), None);
    let move_entry = mutation(
        10,
        "entry.move",
        320,
        json!({ "id": "e1", "place": { "kind": "last" } }),
    );
    cases.playlist("move to the end", &doc, move_entry, alice(), None);
    let move_ghost = mutation(
        11,
        "entry.move",
        321,
        json!({ "id": "ghost", "place": { "kind": "first" } }),
    );
    cases.playlist(
        "move of an unknown entry is invalid",
        &doc,
        move_ghost,
        alice(),
        None,
    );
    let remove = mutation(12, "entry.remove", 330, json!({ "id": "e2" }));
    cases.playlist("remove an entry", &doc, remove, alice(), None);
    let wrong_kind = mutation(13, "scalar.clear", 340, json!({ "key": "pref/theme" }));
    cases.playlist(
        "a scalar mutation is not a playlist mutation",
        &doc,
        wrong_kind,
        alice(),
        None,
    );
    let unknown = mutation(14, "playlist.explode", 350, json!({}));
    cases.playlist(
        "an unknown mutation name is an error",
        &doc,
        unknown,
        alice(),
        None,
    );
}

fn scalar_cases(cases: &mut Cases) {
    let set = |stamp: i64, value: Value| {
        mutation(
            1,
            "scalar.set",
            stamp,
            json!({ "key": "pref/theme", "value": value }),
        )
    };
    let stored = cases.scalar(
        "scalar set",
        &Value::Null,
        set(200, json!({ "mode": "dark", "accent": [1, 2, 3] })),
    );
    cases.scalar(
        "scalar set with an older stamp is a noop",
        &stored["scalar"],
        set(100, json!("light")),
    );
    let clear = mutation(2, "scalar.clear", 300, json!({ "key": "pref/theme" }));
    cases.scalar("scalar clear", &stored["scalar"], clear);
    let bad_prefix = mutation(3, "scalar.set", 400, json!({ "key": "nope/x", "value": 1 }));
    cases.scalar(
        "scalar set under an unknown prefix is an error",
        &Value::Null,
        bad_prefix,
    );
}

fn rebase_cases(cases: &mut Cases) {
    let create = mutation(
        1,
        "playlist.create",
        100,
        json!({ "id": "p1", "name": "Mix", "entries": [new_entry("e1", 1)] }),
    );
    let rename = mutation(
        2,
        "playlist.rename",
        200,
        json!({ "id": "p1", "name": "Pending" }),
    );
    let insert = mutation(
        3,
        "entry.insert",
        210,
        json!({ "id": "e2", "playlist": "p1", "ref": song(2), "place": { "kind": "last" } }),
    );
    let remove = mutation(4, "entry.remove", 220, json!({ "id": "e1" }));
    let rebase = |base: &Value, list: Vec<Value>| json!({ "playlistId": "p1", "base": base, "caller": alice(), "pending": list });
    let from_nothing = cases.add(
        "rebase playlist from no base",
        "rebasePlaylist",
        rebase(
            &Value::Null,
            vec![pending(&create, false), pending(&rename, false)],
        ),
    );
    cases.add(
        "rebase playlist skips failed mutations",
        "rebasePlaylist",
        rebase(
            &Value::Null,
            vec![pending(&create, false), pending(&rename, true)],
        ),
    );
    cases.add(
        "rebase playlist onto a base",
        "rebasePlaylist",
        rebase(
            &from_nothing["doc"],
            vec![pending(&insert, false), pending(&remove, false)],
        ),
    );
    cases.add(
        "rebase playlist with nothing pending",
        "rebasePlaylist",
        rebase(&from_nothing["doc"], vec![]),
    );

    let key = song_key("artist1", "title1");
    let love = mutation(
        5,
        "love.set",
        300,
        json!({ "songKey": key, "ref": song(1), "loved": true }),
    );
    let unlove = mutation(
        6,
        "love.set",
        310,
        json!({ "songKey": key, "ref": song(1), "loved": false }),
    );
    cases.add("rebase love", "rebaseLove", json!({ "songKey": key, "base": null, "caller": alice(), "pending": [pending(&love, false)] }));
    cases.add("rebase love last writer wins", "rebaseLove", json!({ "songKey": key, "base": null, "caller": alice(), "pending": [pending(&love, false), pending(&unlove, false)] }));
    let rating = mutation(
        7,
        "rating.set",
        320,
        json!({ "songKey": key, "ref": song(1), "rating": 4 }),
    );
    cases.add("rebase rating", "rebaseRating", json!({ "songKey": key, "base": null, "caller": alice(), "pending": [pending(&rating, false)] }));
    let set = mutation(
        8,
        "scalar.set",
        330,
        json!({ "key": "pref/theme", "value": "dark" }),
    );
    cases.add("rebase scalar", "rebaseScalar", json!({ "key": "pref/theme", "base": null, "caller": alice(), "pending": [pending(&set, false)] }));
    let save = mutation(
        9,
        "session.save",
        340,
        json!({ "session": { "queue": ["a", "b"], "index": 1 } }),
    );
    cases.add("rebase session of the caller's device", "rebaseSession", json!({ "device": "phone", "base": null, "caller": alice(), "pending": [pending(&save, false)] }));
    cases.add("rebase session of another device", "rebaseSession", json!({ "device": "tablet", "base": null, "caller": alice(), "pending": [pending(&save, false)] }));
}

fn helper_cases(cases: &mut Cases) {
    cases.add(
        "between with no bounds",
        "between",
        json!({ "a": null, "b": null }),
    );
    cases.add(
        "between after a key",
        "between",
        json!({ "a": "V", "b": null }),
    );
    cases.add(
        "between before a key",
        "between",
        json!({ "a": null, "b": "V" }),
    );
    cases.add("between two keys", "between", json!({ "a": "a", "b": "c" }));
    cases.add(
        "between a reversed range",
        "between",
        json!({ "a": "c", "b": "a" }),
    );
    cases.add(
        "song key of two keys",
        "songKey",
        json!({ "artistKey": "radiohead", "titleKey": "karma police" }),
    );
    cases.add(
        "song key of empty keys",
        "songKey",
        json!({ "artistKey": "", "titleKey": "" }),
    );
    let events = json!([
        { "eventId": "000000000000000000000001", "recorded": false, "titleKey": "t", "artistKey": "x", "suppressed": false },
        { "eventId": "000000000000000000000002", "recorded": true, "titleKey": "t", "artistKey": "x", "suppressed": true },
        { "eventId": "000000000000000000000003", "recorded": false, "titleKey": "u", "artistKey": "x", "suppressed": false },
    ]);
    cases.add(
        "suppressed flags of one second",
        "suppressedFlags",
        json!({ "events": events }),
    );
    cases.add(
        "suppressed flags of no events",
        "suppressedFlags",
        json!({ "events": [] }),
    );
    cases.add(
        "next stamp from an empty clock",
        "nextStamp",
        json!({ "last": 0, "offsetMs": 500, "nowMs": 1000 }),
    );
    cases.add(
        "next stamp keeps counting inside a millisecond",
        "nextStamp",
        json!({ "last": 1500_i64 << 16, "offsetMs": 500, "nowMs": 1000 }),
    );
}

fn all_cases() -> Value {
    let mut cases = Cases::default();
    playlist_cases(&mut cases);
    entry_cases(&mut cases);
    scalar_cases(&mut cases);
    rebase_cases(&mut cases);
    helper_cases(&mut cases);
    Value::Array(cases.list)
}

fn rendered(cases: &Value) -> String {
    format!("{}\n", serde_json::to_string_pretty(cases).unwrap())
}

#[test]
fn there_are_enough_cases_covering_errors_and_every_function() {
    let cases = all_cases();
    let list = cases.as_array().unwrap();
    assert!(list.len() >= 25);
    assert!(list
        .iter()
        .any(|case| case["expected"]["error"].is_string()));
    for function in [
        "applyPlaylist",
        "applyScalar",
        "rebasePlaylist",
        "rebaseLove",
        "rebaseRating",
        "rebaseScalar",
        "rebaseSession",
        "between",
        "songKey",
        "suppressedFlags",
        "nextStamp",
    ] {
        assert!(
            list.iter().any(|case| case["function"] == function),
            "{function}"
        );
    }
}

#[test]
fn swift_cases_file_is_current() {
    let text = rendered(&all_cases());
    let path = cases_path();
    if std::env::var_os(WRITE_VARIABLE).is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &text).unwrap();
    }
    let committed = std::fs::read_to_string(&path)
        .unwrap_or_else(|_| panic!("run with {WRITE_VARIABLE}=1 to write {}", path.display()));
    assert_eq!(committed, text, "regenerate with {WRITE_VARIABLE}=1");
}
