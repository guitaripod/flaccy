//! What a client is playing right now, for the live channel.

use flaccy_server_core::model::SongRef;

use crate::security::Principal;

/// Notes that the user behind `principal` has started `song`.
///
/// Nothing is kept yet: the live channel will turn this into a presence frame for the user's other devices and the
/// Last.fm "now playing" call will hang off it.
pub(crate) fn note_now_playing(principal: &Principal, song: &SongRef) {
    crate::lastfm::note_now_playing(&principal.user, song);
}
