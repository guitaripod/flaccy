//! What one user did with the songs: stars, ratings and plays, read from the
//! sync state and kept per user until a commit changes it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::sync::broadcast::error::RecvError;
use tokio::sync::broadcast::Receiver;

use crate::security::UserId;
use crate::sync::{self, PlayStat, Poke, SyncError, UserState};

/// A user's loves, ratings and plays by song key.
#[derive(Clone, Debug, Default)]
pub struct UserView {
    state: UserState,
}

impl UserView {
    /// The view of `state`.
    pub fn new(state: UserState) -> Self {
        Self { state }
    }

    /// When the song was starred, in Unix milliseconds, `None` when it is not.
    pub fn starred_at(&self, song_key: &str) -> Option<i64> {
        self.state.loved.get(song_key).copied()
    }

    /// The song's stars, one to five.
    pub fn rating(&self, song_key: &str) -> Option<i64> {
        self.state.ratings.get(song_key).map(|stars| i64::from(*stars))
    }

    /// How often the user played the song.
    pub fn play_count(&self, song_key: &str) -> i64 {
        self.plays(song_key).count
    }

    /// When the user last played the song, in Unix seconds.
    pub fn last_played(&self, song_key: &str) -> Option<i64> {
        self.state.plays.get(song_key).map(|stat| stat.last)
    }

    fn plays(&self, song_key: &str) -> PlayStat {
        self.state.plays.get(song_key).copied().unwrap_or_default()
    }
}

#[derive(Default)]
struct Slot {
    generation: u64,
    view: Option<Arc<UserView>>,
}

/// The cache of [`UserView`]s, one per user, cheap to clone.
///
/// A commit that changes a user's scope announces it on the store's poke channel and [`UserViews::follow`] drops that
/// user's view; a write made through this server drops it directly, so the next read already sees it.
#[derive(Clone, Default)]
pub struct UserViews {
    slots: Arc<Mutex<HashMap<String, Slot>>>,
}

impl UserViews {
    fn slots(&self) -> MutexGuard<'_, HashMap<String, Slot>> {
        self.slots.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The user's view, read from the store when none is cached.
    pub async fn get(&self, store: &sync::Store, user: &UserId) -> Result<Arc<UserView>, SyncError> {
        let key = user.to_string();
        let generation = {
            let mut slots = self.slots();
            let slot = slots.entry(key.clone()).or_default();
            if let Some(view) = &slot.view {
                return Ok(view.clone());
            }
            slot.generation
        };
        let view = Arc::new(UserView::new(store.user_state(user).await?));
        let mut slots = self.slots();
        let slot = slots.entry(key).or_default();
        if slot.generation == generation {
            slot.view = Some(view.clone());
        }
        Ok(view)
    }

    /// Forgets the view of the user a scope names; the household scope names nobody.
    pub fn invalidate(&self, scope: &str) {
        if let Some(slot) = self.slots().get_mut(scope) {
            slot.generation += 1;
            slot.view = None;
        }
    }

    fn invalidate_all(&self) {
        for slot in self.slots().values_mut() {
            slot.generation += 1;
            slot.view = None;
        }
    }

    /// Keeps the cache honest by dropping the view of every user a commit touches, until the channel closes.
    pub fn follow(&self, mut pokes: Receiver<Poke>) {
        let views = self.clone();
        tokio::spawn(async move {
            loop {
                match pokes.recv().await {
                    Ok(poke) => views.invalidate(&poke.scope),
                    Err(RecvError::Lagged(_)) => views.invalidate_all(),
                    Err(RecvError::Closed) => break,
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn view_with_one_play() -> UserView {
        let mut state = UserState::default();
        state.plays.insert("k".to_owned(), PlayStat { count: 3, last: 99 });
        state.loved.insert("k".to_owned(), 5_000);
        state.ratings.insert("k".to_owned(), 4);
        UserView::new(state)
    }

    #[test]
    fn a_view_answers_per_song_key() {
        let view = view_with_one_play();
        assert_eq!(view.play_count("k"), 3);
        assert_eq!(view.last_played("k"), Some(99));
        assert_eq!(view.starred_at("k"), Some(5_000));
        assert_eq!(view.rating("k"), Some(4));
        assert_eq!(view.play_count("other"), 0);
        assert_eq!(view.last_played("other"), None);
        assert_eq!(view.starred_at("other"), None);
        assert_eq!(view.rating("other"), None);
    }

    #[test]
    fn invalidating_a_user_drops_only_that_slot() {
        let views = UserViews::default();
        {
            let mut slots = views.slots();
            for user in ["a", "b"] {
                slots.insert(
                    user.to_owned(),
                    Slot {
                        generation: 0,
                        view: Some(Arc::new(UserView::default())),
                    },
                );
            }
        }
        views.invalidate("a");
        views.invalidate("household");
        let slots = views.slots();
        assert!(slots["a"].view.is_none() && slots["a"].generation == 1);
        assert!(slots["b"].view.is_some());
    }
}
