//! Mirrors `FlaccyCore/Sources/FlaccyCore/Library/AlbumCredit.swift`.
//!
//! Who a *release* is filed under, as opposed to who performs each track.
//! Grouping albums by the per-track credit shatters every compilation,
//! soundtrack and split record into one album per performer; `ALBUMARTIST`
//! exists to prevent that but most rips in the wild do not carry it, so the
//! credit is decided from the tag when it is there and from the shape of the
//! release when it is not.

/// The conventional credit for a release no single artist carries. Left
/// untranslated on purpose: it is also the literal string taggers write into
/// `ALBUMARTIST`, so a derived credit and a tagged one have to collide.
pub const VARIOUS_ARTISTS: &str = "Various Artists";

/// The share of a release's tracks one artist must exceed to be credited with
/// the whole of it. At or below this, the release is a compilation.
///
/// A strict majority is the line between "an album with a guest track" and "an
/// album by several people": eleven of twelve tracks is plainly one artist's
/// record, a six-six split plainly is not.
pub const DOMINANT_SHARE: f64 = 0.5;

/// One track's claim on its release's credit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Member {
    /// The `ALBUMARTIST` tag, already trimmed; `None` or empty when absent.
    pub album_artist_tag: Option<String>,
    /// The performing credit as it should be displayed.
    pub artist_display: String,
    /// The normalized key two performing credits share when they are the same
    /// artist — supplied by the caller, because the clients fold
    /// collaborations and diacritics in their own (mirrored) hygiene code.
    pub artist_key: String,
}

impl Member {
    pub fn new(
        album_artist_tag: Option<&str>,
        artist_display: &str,
        artist_key: &str,
    ) -> Self {
        Self {
            album_artist_tag: album_artist_tag.map(|s| s.to_string()),
            artist_display: artist_display.to_string(),
            artist_key: artist_key.to_string(),
        }
    }
}

/// The credit for one release's worth of tracks.
///
/// A tag wins outright wherever one exists: a half-tagged album is best served
/// by the answer somebody actually wrote down. Otherwise a single dominant
/// performer takes the release and anything less concentrated is
/// [`VARIOUS_ARTISTS`].
pub fn credit(members: &[Member]) -> String {
    if members.is_empty() {
        return VARIOUS_ARTISTS.to_string();
    }

    let tags: Vec<&str> = members
        .iter()
        .filter_map(|member| member.album_artist_tag.as_deref())
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
        .collect();
    if !tags.is_empty() {
        return majority(tags.into_iter());
    }

    let mut counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for member in members {
        *counts.entry(member.artist_key.as_str()).or_default() += 1;
    }
    let Some((lead_key, lead_count)) = counts
        .into_iter()
        .max_by(|(ka, ca), (kb, cb)| ca.cmp(cb).then_with(|| kb.cmp(ka)))
    else {
        return VARIOUS_ARTISTS.to_string();
    };

    if (lead_count as f64) <= members.len() as f64 * DOMINANT_SHARE {
        return VARIOUS_ARTISTS.to_string();
    }
    majority(
        members
            .iter()
            .filter(|member| member.artist_key == lead_key)
            .map(|member| member.artist_display.as_str()),
    )
}

/// The folder a release occupies, which is the boundary a compilation's tracks
/// share when their tags do not.
///
/// `None` for a file sitting at the library root: a flat folder is not a
/// release, and treating it as one would fuse two unrelated "Greatest Hits"
/// into a single bogus compilation. Callers fall back to the performing artist
/// there, which is the behavior that predates this module.
pub fn release_scope(relative_path: &str) -> Option<&str> {
    let cut = relative_path.rfind('/')?;
    let parent = &relative_path[..cut];
    (!parent.is_empty()).then_some(parent)
}

fn majority<'a, I>(values: I) -> String
where
    I: Iterator<Item = &'a str>,
{
    let mut counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    let mut first: Option<&str> = None;
    for value in values {
        if first.is_none() {
            first = Some(value);
        }
        *counts.entry(value).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by(|(ka, ca), (kb, cb)| ca.cmp(cb).then_with(|| kb.len().cmp(&ka.len())))
        .map(|(k, _)| k.to_string())
        .or_else(|| first.map(str::to_string))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn untagged(display: &str, key: &str) -> Member {
        Member::new(None, display, key)
    }

    #[test]
    fn a_soundtrack_by_seven_composers_is_various_artists() {
        let composers = [
            ("Gerard K. Marino", 11),
            ("Mike Reagan", 6),
            ("Cris Velasco", 5),
            ("Ron Fish", 6),
            ("Junkie XL", 1),
            ("Shadows Fall", 1),
            ("George \"TraGiC\" Doman", 1),
        ];
        let members: Vec<Member> = composers
            .iter()
            .flat_map(|(name, count)| {
                (0..*count).map(move |_| untagged(name, &name.to_lowercase()))
            })
            .collect();
        assert_eq!(members.len(), 31);
        assert_eq!(credit(&members), VARIOUS_ARTISTS);
    }

    #[test]
    fn one_guest_track_does_not_make_a_compilation() {
        let mut members: Vec<Member> = (0..11).map(|_| untagged("50 Cent", "50cent")).collect();
        members.push(untagged("Eminem", "eminem"));
        assert_eq!(credit(&members), "50 Cent");
    }

    #[test]
    fn an_even_split_is_a_compilation() {
        let mut members: Vec<Member> = (0..6).map(|_| untagged("Artist A", "artista")).collect();
        members.extend((0..6).map(|_| untagged("Artist B", "artistb")));
        assert_eq!(credit(&members), VARIOUS_ARTISTS);
    }

    #[test]
    fn the_album_artist_tag_wins_over_the_derived_credit() {
        let members = vec![
            Member::new(Some("Various Artists"), "Aphex Twin", "aphextwin"),
            untagged("Aphex Twin", "aphextwin"),
            untagged("Aphex Twin", "aphextwin"),
        ];
        assert_eq!(credit(&members), VARIOUS_ARTISTS);
    }

    #[test]
    fn a_blank_album_artist_tag_is_not_a_tag() {
        let members = vec![
            Member::new(Some("   "), "Boards of Canada", "boardsofcanada"),
            untagged("Boards of Canada", "boardsofcanada"),
        ];
        assert_eq!(credit(&members), "Boards of Canada");
    }

    #[test]
    fn a_single_artist_release_keeps_its_artist() {
        let members: Vec<Member> = (0..9)
            .map(|_| untagged("Sigur Rós", "sigurros"))
            .collect();
        assert_eq!(credit(&members), "Sigur Rós");
    }

    #[test]
    fn no_members_is_various_artists() {
        assert_eq!(credit(&[]), VARIOUS_ARTISTS);
    }

    #[test]
    fn release_scope_is_the_containing_folder_and_nothing_at_the_root() {
        assert_eq!(
            release_scope("God of War II/01.Main Titles.flac"),
            Some("God of War II")
        );
        assert_eq!(
            release_scope("Scores/God of War II/CD1/01.flac"),
            Some("Scores/God of War II/CD1")
        );
        assert_eq!(release_scope("loose-track.flac"), None);
    }

    #[test]
    fn the_dominant_share_matches_the_apple_clients() {
        assert_eq!(DOMINANT_SHARE, 0.5);
        assert_eq!(VARIOUS_ARTISTS, "Various Artists");
    }
}
