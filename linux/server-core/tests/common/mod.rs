#![allow(dead_code)]

use flaccy_server_core::apply::{apply_playlist, Caller, Outcome};
use flaccy_server_core::model::{PlaylistDoc, SongRef};
use flaccy_server_core::mutation::{parse, Op};
use flaccy_server_core::song::song_key;
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::Mutation;
use serde_json::{json, Value};

pub fn alice() -> Caller {
    Caller::member("alice", "phone")
}

pub fn song(index: usize) -> SongRef {
    let key = song_key(&format!("artist{index}"), &format!("title{index}"));
    SongRef {
        song_key: key,
        title: format!("Title {index}"),
        artist: format!("Artist {index}"),
        ..SongRef::default()
    }
}

pub fn song_json(index: usize) -> Value {
    serde_json::to_value(song(index)).unwrap()
}

pub fn mutation(id: i64, name: &str, stamp: i64, args: Value) -> Mutation {
    Mutation {
        id,
        name: name.to_owned(),
        stamp: Stamp(stamp),
        args,
    }
}

pub fn parsed(name: &str, args: Value) -> Op {
    parse(&mutation(1, name, 1, args)).unwrap()
}

pub fn run_playlist(
    doc: &mut Option<PlaylistDoc>,
    caller: &Caller,
    stamp: i64,
    name: &str,
    args: Value,
) -> Outcome {
    match parsed(name, args) {
        Op::Playlist(op) => apply_playlist(doc, &op, caller, Stamp(stamp)),
        other => panic!("not a playlist op: {other:?}"),
    }
}

pub fn entry(id: &str, index: usize) -> Value {
    json!({ "id": id, "ref": song_json(index) })
}

pub fn created(id: &str, entries: Vec<Value>) -> Option<PlaylistDoc> {
    let mut doc = None;
    let outcome = run_playlist(
        &mut doc,
        &alice(),
        100,
        "playlist.create",
        json!({ "id": id, "name": "Mix", "entries": entries }),
    );
    assert_eq!(outcome.status, flaccy_server_core::apply::Status::Applied);
    doc
}

pub fn visible_ids(doc: &PlaylistDoc) -> Vec<String> {
    doc.visible().iter().map(|entry| entry.id.clone()).collect()
}

pub fn place(kind: &str, anchor: Option<&str>) -> Value {
    match anchor {
        Some(id) => json!({ "kind": kind, "id": id }),
        None => json!({ "kind": kind }),
    }
}

/// A scripted sequence of valid playlist mutations, each with a larger stamp than the last.
pub fn playlist_script(
    choices: &[(u8, u16, u16, bool)],
    playlist: &str,
    first_stamp: i64,
) -> Vec<Mutation> {
    let mut ids: Vec<String> = Vec::new();
    let mut script = Vec::new();
    for (index, &(kind, a, b, flag)) in choices.iter().enumerate() {
        let stamp = first_stamp + index as i64 * 10;
        let target = (!ids.is_empty()).then(|| ids[a as usize % ids.len()].clone());
        let anchor = (!ids.is_empty()).then(|| ids[b as usize % ids.len()].clone());
        let where_to = match (a % 4, &anchor) {
            (2, Some(id)) => place("after", Some(id)),
            (3, Some(id)) => place("before", Some(id)),
            (0, _) => place("first", None),
            _ => place("last", None),
        };
        let fresh = format!("{playlist}-e{index}");
        let (name, args) = match (kind % 8, &target) {
            (2, Some(id)) => ("entry.move", json!({ "id": id, "place": where_to })),
            (3, Some(id)) => ("entry.remove", json!({ "id": id })),
            (1, _) => {
                let second = format!("{fresh}b");
                ids.push(fresh.clone());
                ids.push(second.clone());
                (
                    "entry.insertMany",
                    json!({ "playlist": playlist, "entries": [entry(&fresh, 1), entry(&second, 2)], "place": where_to }),
                )
            }
            (4, _) => (
                "playlist.rename",
                json!({ "id": playlist, "name": format!("Name {a}") }),
            ),
            (5, _) if flag => ("playlist.delete", json!({ "id": playlist })),
            (5, _) => ("playlist.restore", json!({ "id": playlist })),
            (6, _) if flag => ("playlist.clearCover", json!({ "id": playlist })),
            (6, _) => (
                "playlist.setCover",
                json!({ "id": playlist, "blob": "ab".repeat(32) }),
            ),
            (7, _) => (
                "playlist.setVisibility",
                json!({ "id": playlist, "visibility": if flag { "household" } else { "private" } }),
            ),
            _ => {
                ids.push(fresh.clone());
                (
                    "entry.insert",
                    json!({ "id": fresh, "playlist": playlist, "ref": song_json(0), "place": where_to }),
                )
            }
        };
        script.push(mutation(index as i64 + 1, name, stamp, args));
    }
    script
}
