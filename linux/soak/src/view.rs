use flaccy_library::server_sync::{ListenItem, ListensRequest, PullRequest, Transport};
use flaccy_server_core::model::{Entry, EntityKind, Love, Playlist, Scalar};
use serde_json::from_value;
use std::collections::HashMap;
use std::sync::Mutex;

use crate::sync_util::locked;

const PAGE: usize = 5000;
const MAX_PAGES: usize = 200;

/// The server's state as the observer device sees it.
#[derive(Default)]
pub struct ServerView {
    /// Every playlist, dead ones included.
    pub playlists: HashMap<String, Playlist>,
    /// Every entry, dead ones included.
    pub entries: HashMap<String, Entry>,
    /// Every love by song key.
    pub loves: HashMap<String, Love>,
    /// Every scalar by key.
    pub scalars: HashMap<String, Scalar>,
    /// Every listen the server holds, suppressed ones included.
    pub listens: Vec<ListenItem>,
}

/// A device of its own that talks to the server directly, around the proxy, and only reads.
pub struct Observer {
    transport: Transport,
    instance: String,
    incarnation: Mutex<Option<String>>,
    last_head: Mutex<i64>,
}

impl Observer {
    /// Enrolls a read-only device with a fresh code.
    pub fn enroll(url: &str, code: &str) -> Result<Observer, String> {
        let instance = "00000000-0000-7000-8000-00000000ab01".to_owned();
        let reply = Transport::probing(url)
            .enroll(code, "soak observer", &instance)
            .map_err(|error| format!("observer enrollment failed: {error}"))?;
        Ok(Observer {
            transport: Transport::new(url).with_token(Some(reply.token.clone())),
            instance,
            incarnation: Mutex::new(Some(reply.incarnation.clone())),
            last_head: Mutex::new(0),
        })
    }

    /// Pulls everything from cursor 0 and reads every listen. Fails on a transport error or a broken cursor.
    pub fn snapshot(&self) -> Result<ServerView, String> {
        let incarnation = locked(&self.incarnation).clone();
        let mut view = ServerView::default();
        let mut since = 0;
        for _ in 0..MAX_PAGES {
            let request = PullRequest {
                since,
                limit: PAGE,
                instance: self.instance.clone(),
                incarnation: incarnation.clone(),
            };
            let page = self.transport.pull(&request).map_err(|error| format!("observer pull failed: {error}"))?;
            self.check_cursor(since, page.head, page.changes.iter().map(|change| change.seq))?;
            for change in page.changes {
                since = since.max(change.seq);
                absorb(&mut view, change.kind, change.value)?;
            }
            if !page.more {
                break;
            }
        }
        self.read_listens(&mut view, incarnation.as_deref())?;
        Ok(view)
    }

    fn check_cursor(&self, since: i64, head: i64, seqs: impl Iterator<Item = i64>) -> Result<(), String> {
        let mut previous = since;
        for seq in seqs {
            if seq <= previous {
                return Err(format!("cursor not monotone: seq {seq} follows {previous}"));
            }
            previous = seq;
        }
        let mut last = locked(&self.last_head);
        if head < *last {
            return Err(format!("cursor not monotone: head went from {} back to {head}", *last));
        }
        *last = head;
        Ok(())
    }

    fn read_listens(&self, view: &mut ServerView, incarnation: Option<&str>) -> Result<(), String> {
        let mut after = 0;
        for _ in 0..MAX_PAGES {
            let request = ListensRequest { before: None, after: Some(after), limit: PAGE };
            let page = self
                .transport
                .listens(&request, incarnation)
                .map_err(|error| format!("observer listens failed: {error}"))?;
            after = page.listens.last().map_or(after, |item| item.seq);
            view.listens.extend(page.listens);
            if !page.more {
                return Ok(());
            }
        }
        Ok(())
    }
}

fn absorb(view: &mut ServerView, kind: EntityKind, value: serde_json::Value) -> Result<(), String> {
    let bad = |error: serde_json::Error| format!("the server sent a {kind:?} the harness cannot read: {error}");
    match kind {
        EntityKind::Playlist => {
            let playlist: Playlist = from_value(value).map_err(bad)?;
            view.playlists.insert(playlist.id.clone(), playlist);
        }
        EntityKind::PlaylistEntry => {
            let entry: Entry = from_value(value).map_err(bad)?;
            view.entries.insert(entry.id.clone(), entry);
        }
        EntityKind::Love => {
            let love: Love = from_value(value).map_err(bad)?;
            view.loves.insert(love.song_key.clone(), love);
        }
        EntityKind::Scalar => {
            let scalar: Scalar = from_value(value).map_err(bad)?;
            view.scalars.insert(scalar.key.clone(), scalar);
        }
        _ => {}
    }
    Ok(())
}
