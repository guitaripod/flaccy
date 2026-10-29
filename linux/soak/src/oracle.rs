use crate::view::ServerView;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// One queued mutation as a client's pending table holds it.
#[derive(Clone, Debug)]
pub struct Row {
    /// The client stamp, unique per client and kept across renumbering.
    pub stamp: i64,
    /// The mutation name.
    pub name: String,
    /// The mutation arguments.
    pub args: Value,
    /// True once the server refused it.
    pub failed: bool,
}

#[derive(Clone, Debug)]
struct LastWriter<T> {
    stamp: i64,
    value: T,
    tied: bool,
}

#[derive(Clone, Debug, Default)]
struct Field<T>(Option<LastWriter<T>>);

impl<T: PartialEq + Clone> Field<T> {
    fn offer(&mut self, stamp: i64, value: T) {
        match &mut self.0 {
            Some(current) if current.stamp == stamp => current.tied |= current.value != value,
            Some(current) if current.stamp > stamp => {}
            slot => *slot = Some(LastWriter { stamp, value, tied: false }),
        }
    }

    fn winner(&self) -> Option<&LastWriter<T>> {
        self.0.as_ref().filter(|writer| !writer.tied)
    }
}

#[derive(Clone, Debug, Default)]
struct PlaylistFacts {
    name: Field<String>,
    deleted: bool,
}

/// What the clients saw acknowledged, folded into the last-writer-wins outcome per entity.
#[derive(Clone, Debug, Default)]
pub struct Oracle {
    playlists: BTreeMap<String, PlaylistFacts>,
    entries: BTreeSet<String>,
    removed_acked: BTreeSet<String>,
    removed_issued: BTreeSet<String>,
    loves: BTreeMap<String, Field<bool>>,
    lyrics: BTreeMap<String, Field<i64>>,
    listens: BTreeSet<(i64, String)>,
    issued: u64,
    acked: u64,
    refused: u64,
}

impl Oracle {
    /// Mutations clients queued.
    pub fn issued(&self) -> u64 {
        self.issued
    }

    /// Mutations retired by a complete pull after the server answered them.
    pub fn acked(&self) -> u64 {
        self.acked
    }

    /// Mutations the server refused before they were retired.
    pub fn refused(&self) -> u64 {
        self.refused
    }

    /// Adds the removals `later` saw, so a check against a server snapshot also knows the removals issued while the snapshot was being read.
    pub fn absorb_removals(&mut self, later: &Oracle) {
        self.removed_issued.extend(later.removed_issued.iter().cloned());
    }

    /// A new mutation appeared in a client's queue.
    pub fn note_issued(&mut self, row: &Row) {
        self.issued += 1;
        if row.name == "entry.remove" {
            if let Some(id) = row.args["id"].as_str() {
                self.removed_issued.insert(id.to_owned());
            }
        }
    }

    /// A mutation left a client's queue because a pull retired it.
    pub fn note_retired(&mut self, row: &Row) {
        if row.name == "state.reseed" {
            return;
        }
        if row.failed {
            self.refused += 1;
            return;
        }
        self.acked += 1;
        self.fold(row);
    }

    fn fold(&mut self, row: &Row) {
        let args = &row.args;
        let text = |value: &Value| value.as_str().unwrap_or_default().to_owned();
        match row.name.as_str() {
            "playlist.create" | "playlist.rename" => {
                let facts = self.playlists.entry(text(&args["id"])).or_default();
                facts.name.offer(row.stamp, text(&args["name"]));
            }
            "playlist.delete" => self.playlists.entry(text(&args["id"])).or_default().deleted = true,
            "entry.insert" => {
                self.entries.insert(text(&args["id"]));
            }
            "entry.insertMany" => {
                for entry in args["entries"].as_array().into_iter().flatten() {
                    self.entries.insert(text(&entry["id"]));
                }
            }
            "entry.remove" => {
                self.removed_acked.insert(text(&args["id"]));
            }
            "love.set" => {
                let loved = args["loved"].as_bool().unwrap_or(false);
                self.loves.entry(text(&args["songKey"])).or_default().offer(row.stamp, loved);
            }
            "scalar.set" => {
                let key = text(&args["key"]);
                if let (Some(song), Some(value)) = (key.strip_prefix("lyr/"), args["value"].as_i64()) {
                    self.lyrics.entry(song.to_owned()).or_default().offer(row.stamp, value);
                }
            }
            "listen.record" => {
                for listen in args["listens"].as_array().into_iter().flatten() {
                    self.listens.insert((listen["ts"].as_i64().unwrap_or(0), text(&listen["ref"]["songKey"])));
                }
            }
            _ => {}
        }
    }

    /// Fails with the first acknowledged mutation whose effect the server state lacks and no later write explains.
    pub fn check(&self, server: &ServerView) -> Result<(), String> {
        self.check_playlists(server)?;
        self.check_entries(server)?;
        self.check_loves(server)?;
        self.check_lyrics(server)?;
        self.check_listens(server)
    }

    fn check_playlists(&self, server: &ServerView) -> Result<(), String> {
        for (id, facts) in &self.playlists {
            let Some(playlist) = server.playlists.get(id) else {
                return Err(format!("playlist {id}: acknowledged create is missing on the server"));
            };
            if facts.deleted && playlist.alive {
                return Err(format!("playlist {id} ({:?}): acknowledged delete was resurrected", playlist.name));
            }
            if let Some(winner) = facts.name.winner() {
                let superseded = playlist.stamps.name.0 > winner.stamp;
                if playlist.name != winner.value && !superseded {
                    return Err(format!(
                        "playlist {id}: acknowledged name {:?} (stamp {}) lost, server has {:?} (stamp {})",
                        winner.value, winner.stamp, playlist.name, playlist.stamps.name.0
                    ));
                }
            }
        }
        Ok(())
    }

    fn check_entries(&self, server: &ServerView) -> Result<(), String> {
        for id in &self.entries {
            match server.entries.get(id) {
                None => return Err(format!("entry {id}: acknowledged insert is missing on the server")),
                Some(entry) if !entry.alive && !self.removed_issued.contains(id) => {
                    return Err(format!("entry {id}: dead on the server but no remove was ever issued"));
                }
                Some(_) => {}
            }
        }
        for id in &self.removed_acked {
            if server.entries.get(id).is_some_and(|entry| entry.alive) {
                return Err(format!("entry {id}: acknowledged remove was resurrected"));
            }
        }
        Ok(())
    }

    fn check_loves(&self, server: &ServerView) -> Result<(), String> {
        for (song, field) in &self.loves {
            let Some(winner) = field.winner() else { continue };
            let Some(love) = server.loves.get(song) else {
                return Err(format!("love {song}: acknowledged write is missing on the server"));
            };
            if love.loved != winner.value && love.stamp.0 <= winner.stamp {
                return Err(format!(
                    "love {song}: acknowledged loved={} (stamp {}) lost, server has loved={} (stamp {})",
                    winner.value, winner.stamp, love.loved, love.stamp.0
                ));
            }
        }
        Ok(())
    }

    fn check_lyrics(&self, server: &ServerView) -> Result<(), String> {
        for (song, field) in &self.lyrics {
            let Some(winner) = field.winner() else { continue };
            let Some(scalar) = server.scalars.get(&format!("lyr/{song}")) else {
                return Err(format!("lyric offset {song}: acknowledged write is missing on the server"));
            };
            let value = scalar.value.as_i64();
            if (scalar.deleted || value != Some(winner.value)) && scalar.stamp.0 <= winner.stamp {
                return Err(format!(
                    "lyric offset {song}: acknowledged {} (stamp {}) lost, server has {:?} (stamp {})",
                    winner.value, winner.stamp, value, scalar.stamp.0
                ));
            }
        }
        Ok(())
    }

    /// A play is identified by its second and song, not by its id: a client that meets a stale instance gives its unanswered plays new ids.
    fn check_listens(&self, server: &ServerView) -> Result<(), String> {
        let held: BTreeSet<(i64, &str)> = server
            .listens
            .iter()
            .map(|item| (item.ts, item.song.song_key.as_str()))
            .collect();
        for (ts, song) in &self.listens {
            if !held.contains(&(*ts, song.as_str())) {
                return Err(format!("listen (ts {ts}, song {song}): acknowledged but absent on the server"));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn row(stamp: i64, name: &str, args: Value) -> Row {
        Row { stamp, name: name.into(), args, failed: false }
    }

    #[test]
    fn the_later_stamp_wins_and_a_missing_love_is_reported() {
        let mut oracle = Oracle::default();
        oracle.note_retired(&row(5, "love.set", json!({"songKey": "k", "loved": true})));
        oracle.note_retired(&row(9, "love.set", json!({"songKey": "k", "loved": false})));
        let error = oracle.check(&ServerView::default()).unwrap_err();
        assert!(error.contains("love k"));
    }

    #[test]
    fn a_refused_mutation_is_counted_and_never_expected() {
        let mut oracle = Oracle::default();
        let mut refused = row(1, "entry.insert", json!({"id": "e"}));
        refused.failed = true;
        oracle.note_retired(&refused);
        assert_eq!(oracle.refused(), 1);
        assert!(oracle.check(&ServerView::default()).is_ok());
    }
}
