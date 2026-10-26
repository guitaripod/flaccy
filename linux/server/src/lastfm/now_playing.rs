//! The "now playing" hand-off from the OpenSubsonic API to the Last.fm relay.
//!
//! `note_now_playing` costs nothing and does nothing until the relay is running; the relay coalesces calls so only the
//! newest song of each user is sent.

use std::collections::BTreeMap;
use std::sync::RwLock;

use flaccy_server_core::model::SongRef;
use tokio::sync::mpsc;

use super::api::ScrobbleEntry;
use crate::security::UserId;

type Sink = mpsc::UnboundedSender<(UserId, ScrobbleEntry)>;

static SINK: RwLock<Option<Sink>> = RwLock::new(None);

fn entry_of(song: &SongRef) -> ScrobbleEntry {
    ScrobbleEntry {
        title: song.title.clone(),
        artist: song.artist.clone(),
        album: song.album.clone(),
        timestamp: 0,
        duration_s: song.duration_ms / 1000,
    }
}

/// Tells the Last.fm relay that `user` started `song`. A no-op while the relay is not running, so callers need no check.
pub fn note_now_playing(user: &UserId, song: &SongRef) {
    let sink = SINK.read().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(sink) = sink.as_ref() {
        let _ = sink.send((user.clone(), entry_of(song)));
    }
}

/// Opens the hand-off; the relay reads what `note_now_playing` sends from the returned receiver.
pub(super) fn open_channel() -> mpsc::UnboundedReceiver<(UserId, ScrobbleEntry)> {
    let (sender, receiver) = mpsc::unbounded_channel();
    *SINK.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(sender);
    receiver
}

/// Waits for a song, then gathers every song already queued behind it; answers the newest song of each user.
pub(super) async fn next_songs(receiver: &mut mpsc::UnboundedReceiver<(UserId, ScrobbleEntry)>) -> Option<BTreeMap<UserId, ScrobbleEntry>> {
    let first = receiver.recv().await?;
    let mut newest = BTreeMap::from([first]);
    while let Ok((user, entry)) = receiver.try_recv() {
        newest.insert(user, entry);
    }
    Some(newest)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song(title: &str) -> SongRef {
        SongRef { song_key: "k".into(), title: title.into(), artist: "A".into(), duration_ms: 185_000, ..SongRef::default() }
    }

    #[tokio::test]
    async fn only_the_newest_song_of_each_user_is_kept() {
        let mut receiver = open_channel();
        let alice = UserId("alice".into());
        note_now_playing(&alice, &song("one"));
        note_now_playing(&alice, &song("two"));
        note_now_playing(&UserId("bob".into()), &song("three"));
        let newest = next_songs(&mut receiver).await.unwrap();
        assert_eq!(newest[&alice].title, "two");
        assert_eq!(newest[&alice].duration_s, 185);
        assert_eq!(newest.len(), 2);
    }
}
