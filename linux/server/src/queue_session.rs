//! The play queue as a device session: the shape the OpenSubsonic `savePlayQueue`
//! writes and `getPlayQueue` reads, and the legacy migration fills.

use flaccy_server_core::model::{SessionDoc, SongRef};
use serde_json::{json, Value};

/// What the `kind` of a session this server writes says about its shape.
pub const SESSION_KIND: &str = "opensubsonic";
const SESSION_BUDGET_BYTES: usize = 60_000;

/// One queued song: its identity key and, when known, the file it was queued from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueueItem {
    /// The song key.
    pub key: String,
    /// The path relative to the music folder.
    pub path: Option<String>,
}

impl QueueItem {
    /// The queue entry for `song`.
    pub fn of(song: &SongRef) -> Self {
        Self {
            key: song.song_key.clone(),
            path: song.rel_path.clone(),
        }
    }

    /// Just enough of a reference to find the song again in the library.
    pub fn reference(&self) -> SongRef {
        SongRef {
            song_key: self.key.clone(),
            rel_path: self.path.clone(),
            ..SongRef::default()
        }
    }

    fn to_value(&self) -> Value {
        json!({ "k": self.key, "p": self.path })
    }

    fn from_value(value: &Value) -> Option<Self> {
        let key = value.get("k").or_else(|| value.get("songKey"))?.as_str()?;
        let path = value.get("p").or_else(|| value.get("relPath")).and_then(Value::as_str);
        Some(Self {
            key: key.to_owned(),
            path: path.map(str::to_owned),
        })
    }
}

fn fitting(items: &[QueueItem]) -> usize {
    let mut used = 0;
    items
        .iter()
        .take_while(|item| {
            used += item.to_value().to_string().len() + 1;
            used <= SESSION_BUDGET_BYTES
        })
        .count()
}

/// The session document for a queue. A queue too long for a session is cut at its end, and `current` is dropped
/// when it fell off.
pub fn session_value(queue: &[QueueItem], current: Option<String>, position_ms: i64, changed_by: &str) -> Value {
    let kept = &queue[..fitting(queue)];
    let current = current.filter(|key| kept.iter().any(|item| item.key == *key));
    json!({
        "kind": SESSION_KIND,
        "queue": kept.iter().map(QueueItem::to_value).collect::<Vec<_>>(),
        "current": current,
        "positionMs": position_ms.max(0),
        "changedBy": changed_by,
    })
}

/// The queue a session holds, `None` when the session is not a queue.
pub fn queue_of(session: &SessionDoc) -> Option<Vec<QueueItem>> {
    let items = session.session.get("queue")?.as_array()?;
    Some(items.iter().filter_map(QueueItem::from_value).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(number: usize) -> QueueItem {
        QueueItem {
            key: format!("{number:032x}"),
            path: Some(format!("Artist/Album/{number:04} Song.flac")),
        }
    }

    #[test]
    fn a_queue_round_trips_through_its_session() {
        let queue = vec![item(1), item(2)];
        let session = session_value(&queue, Some(item(2).key), 4200, "phone");
        let doc = SessionDoc {
            device: "d".to_owned(),
            session,
            stamp: flaccy_server_core::stamp::Stamp(0),
        };
        assert_eq!(queue_of(&doc), Some(queue));
        assert_eq!(doc.session["current"], item(2).key);
        assert_eq!(doc.session["positionMs"], 4200);
        assert_eq!(doc.session["changedBy"], "phone");
    }

    #[test]
    fn a_queue_too_long_for_a_session_is_cut_and_loses_a_current_that_fell_off() {
        let queue: Vec<QueueItem> = (0..2000).map(item).collect();
        let session = session_value(&queue, Some(item(1999).key), 0, "");
        let kept = session["queue"].as_array().unwrap().len();
        assert!(kept > 300 && kept < 2000, "{kept}");
        assert!(session.to_string().len() <= 64 * 1024);
        assert!(session["current"].is_null());
    }

    #[test]
    fn a_session_without_a_queue_is_not_one() {
        let doc = SessionDoc {
            device: "d".to_owned(),
            session: json!({ "something": 1 }),
            stamp: flaccy_server_core::stamp::Stamp(0),
        };
        assert_eq!(queue_of(&doc), None);
    }
}
