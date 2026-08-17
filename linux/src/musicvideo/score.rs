use super::Candidate;

/// A candidate is only ever accepted when it clears this. Below it the track
/// is recorded as having no music video rather than playing something wrong —
/// a mismatched video is worse than no video at all.
pub const ACCEPT: f64 = 0.58;

/// How far the leader must be ahead of the runner-up for the deterministic
/// scorer to decide alone. Inside this band the two candidates are close
/// enough that title wording — which the scorer only pattern-matches — is
/// probably deciding it, so a language model gets the casting vote.
pub const DECISIVE_MARGIN: f64 = 0.14;

/// A music video is an edit, not the album master: radio cuts run shorter and
/// cold opens run longer, so runtime is bounded by ratio rather than by
/// seconds. Outside this band the candidate is a different thing entirely — an
/// extended mix, a full concert, an hour-long loop.
const MIN_DURATION_RATIO: f64 = 0.5;
const MAX_DURATION_RATIO: f64 = 1.9;

/// However favourable the ratio, this much absolute drift means the candidate
/// is not this song.
const MAX_DURATION_DRIFT: f64 = 240.0;

/// Where a duration match stops being free: an edit that keeps the arrangement.
const FREE_DURATION_DRIFT: f64 = 8.0;

/// Drift at which the runtime signal bottoms out. It never reaches zero,
/// because a legitimate music video really can be a minute shorter than the
/// album cut.
const DURATION_SPAN: f64 = 90.0;

pub struct Scored<'a> {
    pub candidate: &'a Candidate,
    pub score: f64,
}

/// Ranks search results for one library track, best first. Candidates whose
/// runtime rules them out are dropped entirely rather than ranked low, so the
/// LLM tie-break never sees a 12-minute "extended" edit.
pub fn rank<'a>(
    title: &str,
    artist: &str,
    duration: f64,
    candidates: &'a [Candidate],
) -> Vec<Scored<'a>> {
    let plausible: Vec<&'a Candidate> = candidates
        .iter()
        .filter(|candidate| !candidate.live_now)
        .filter(|candidate| duration_plausible(duration, candidate.duration))
        .collect();
    let most_watched = plausible
        .iter()
        .filter_map(|candidate| candidate.view_count)
        .max()
        .unwrap_or(0);

    let mut scored: Vec<Scored<'a>> = plausible
        .into_iter()
        .map(|candidate| Scored {
            candidate,
            score: score(title, artist, duration, candidate, most_watched),
        })
        .collect();
    scored.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.candidate.id.cmp(&b.candidate.id))
    });
    scored
}

/// True when the deterministic ranking is clear enough to skip the language
/// model: a confident leader that no one is close to.
pub fn decisive(scored: &[Scored]) -> bool {
    let Some(best) = scored.first() else { return false };
    if best.score < ACCEPT {
        return false;
    }
    let runner_up = scored.get(1).map(|s| s.score).unwrap_or(0.0);
    best.score - runner_up >= DECISIVE_MARGIN
}

fn duration_plausible(track: f64, candidate: f64) -> bool {
    if track <= 0.0 || candidate <= 0.0 {
        return true;
    }
    let ratio = candidate / track;
    (MIN_DURATION_RATIO..=MAX_DURATION_RATIO).contains(&ratio)
        && (track - candidate).abs() <= MAX_DURATION_DRIFT
}

/// Blends six independent judgements into one 0..1 score. Naming the artist
/// and naming the artist's *channel* are scored apart on purpose: every
/// re-upload puts the artist in its title, so that says almost nothing, while
/// the uploader's identity says almost everything. Reach is the other signal a
/// convincing copy cannot forge — a song's real music video outdraws every
/// re-upload of it by orders of magnitude.
pub fn score(
    title: &str,
    artist: &str,
    duration: f64,
    candidate: &Candidate,
    most_watched: u64,
) -> f64 {
    let video_title = normalize(&candidate.title);
    let channel = normalize(&candidate.channel);
    let wanted_title = normalize(&search_title(title));
    let wanted_artist = normalize(&crate::hygiene::primary_artist(artist));

    let title_hit = phrase_score(&video_title, &wanted_title);
    if title_hit <= 0.0 {
        return 0.0;
    }
    let uploader = channel_score(&channel, &wanted_artist);
    let artist_named = f64::max(phrase_score(&video_title, &wanted_artist), uploader);

    let raw = 0.26 * title_hit
        + 0.10 * artist_named
        + 0.22 * uploader
        + 0.24 * intent_score(&video_title, &channel)
        + 0.12 * reach_score(candidate.view_count, most_watched)
        + 0.06 * duration_score(duration, candidate.duration);
    raw.clamp(0.0, 1.0)
}

/// Watch counts span several orders of magnitude, so they are compared on a
/// log scale against the most-watched candidate in the same search.
fn reach_score(views: Option<u64>, most_watched: u64) -> f64 {
    if most_watched == 0 {
        return 0.5;
    }
    let Some(views) = views else { return 0.5 };
    ((views + 1) as f64).ln() / ((most_watched + 1) as f64).ln()
}

/// 1.0 when the whole phrase appears in order, tapering with the share of its
/// words that made it, so "Instant Crush" still matches
/// "Instant Crush (Official Video) ft. Julian Casablancas".
fn phrase_score(haystack: &str, needle: &str) -> f64 {
    if needle.is_empty() {
        return 0.0;
    }
    if haystack.contains(needle) {
        return 1.0;
    }
    let words: Vec<&str> = needle.split(' ').filter(|w| !w.is_empty()).collect();
    if words.is_empty() {
        return 0.0;
    }
    let hits = words.iter().filter(|word| haystack.contains(**word)).count();
    let ratio = hits as f64 / words.len() as f64;
    if ratio < 0.6 {
        0.0
    } else {
        ratio * 0.8
    }
}

/// An artist's own channel is the strongest authenticity signal there is;
/// VEVO and the auto-generated "- Topic" uploads are the same entity wearing a
/// suffix.
fn channel_score(channel: &str, artist: &str) -> f64 {
    if artist.is_empty() || channel.is_empty() {
        return 0.0;
    }
    let bare = channel
        .trim_end_matches(" topic")
        .trim_end_matches("vevo")
        .trim();
    if bare == artist || channel == artist {
        return 1.0;
    }
    if bare.contains(artist) || artist.contains(bare) {
        return 0.85;
    }
    phrase_score(channel, artist) * 0.7
}

fn duration_score(track: f64, candidate: f64) -> f64 {
    if track <= 0.0 || candidate <= 0.0 {
        return 0.5;
    }
    let drift = (track - candidate).abs();
    if drift <= FREE_DURATION_DRIFT {
        return 1.0;
    }
    (1.0 - (drift - FREE_DURATION_DRIFT) / DURATION_SPAN).clamp(0.0, 1.0)
}

/// What the uploader says the video *is*. A music video is the goal; a lyric
/// video, a visualizer, a live take or a fan edit all use the same song title
/// and would otherwise score identically.
fn intent_score(video_title: &str, channel: &str) -> f64 {
    let mut score: f64 = 0.5;
    for promise in [
        "official music video",
        "official video",
        "music video",
        "official mv",
    ] {
        if video_title.contains(promise) {
            score = 1.0;
            break;
        }
    }
    if score < 1.0 && channel.ends_with("vevo") {
        score = 0.85;
    }
    for wrong_medium in [
        "lyric",
        "lyrics",
        "visualizer",
        "visualiser",
        "official audio",
        "audio only",
        "full album",
        "topic",
    ] {
        if video_title.contains(wrong_medium) {
            score -= 0.55;
        }
    }
    if channel.ends_with(" topic") {
        score -= 0.4;
    }
    for wrong_take in [
        "live",
        "concert",
        "acoustic",
        "cover",
        "remix",
        "reaction",
        "karaoke",
        "instrumental",
        "slowed",
        "reverb",
        "nightcore",
        "sped up",
        "8d",
        "loop",
        "extended",
        "hour",
        "unofficial",
        "fan made",
        "fanmade",
        "amv",
        "tutorial",
        "behind the scenes",
        "making of",
    ] {
        if contains_word(video_title, wrong_take) {
            score -= 0.45;
        }
    }
    score.clamp(0.0, 1.0)
}

/// Substring matching alone would read "cover" out of "discover" and "live"
/// out of "delivered", so qualifiers are matched on word boundaries.
fn contains_word(haystack: &str, needle: &str) -> bool {
    let mut start = 0;
    while let Some(found) = haystack[start..].find(needle) {
        let at = start + found;
        let before_ok = at == 0 || !haystack.as_bytes()[at - 1].is_ascii_alphanumeric();
        let end = at + needle.len();
        let after_ok = end >= haystack.len() || !haystack.as_bytes()[end].is_ascii_alphanumeric();
        if before_ok && after_ok {
            return true;
        }
        start = at + needle.len();
    }
    false
}

/// Words that describe a *pressing* rather than a performance. A bracketed
/// group made only of these (and years) names the same recording the video was
/// made for, so it is dropped before searching. Anything else in the brackets —
/// "Acoustic", "Live", a remixer's name — identifies a different recording and
/// is kept, because that recording has a different video or none at all.
const PRESSING_WORDS: [&str; 27] = [
    "album", "single", "version", "radio", "edit", "remaster", "remastered", "remasters", "mono",
    "stereo", "explicit", "clean", "bonus", "track", "deluxe", "edition", "anniversary",
    "expanded", "original", "mix", "master", "mastered", "digital", "reissue", "hd", "hq", "the",
];

/// The song title as it should be searched for: the library's title with any
/// pressing qualifier removed. "Heart-Shaped Box (Album Version)" is looking
/// for the video of "Heart-Shaped Box".
pub fn search_title(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    let mut group = String::new();
    let mut depth = 0usize;
    for ch in title.chars() {
        match ch {
            '(' | '[' => {
                depth += 1;
                if depth == 1 {
                    group.clear();
                    continue;
                }
            }
            ')' | ']' if depth > 0 => {
                depth -= 1;
                if depth == 0 {
                    if !is_pressing_qualifier(&group) {
                        out.push(if ch == ')' { '(' } else { '[' });
                        out.push_str(&group);
                        out.push(ch);
                    }
                    continue;
                }
            }
            _ => {}
        }
        if depth > 0 {
            group.push(ch);
        } else {
            out.push(ch);
        }
    }
    let trimmed = out.split_whitespace().collect::<Vec<_>>().join(" ");
    if trimmed.is_empty() {
        title.trim().to_string()
    } else {
        trimmed
    }
}

fn is_pressing_qualifier(group: &str) -> bool {
    let normalized = normalize(group);
    let mut words = normalized.split(' ').filter(|word| !word.is_empty()).peekable();
    if words.peek().is_none() {
        return false;
    }
    words.all(|word| {
        PRESSING_WORDS.contains(&word)
            || (word.len() == 4 && word.chars().all(|c| c.is_ascii_digit()))
    })
}

/// Lowercases, folds punctuation to spaces and collapses runs, so titles that
/// differ only in dashes, brackets or smart quotes compare equal.
pub fn normalize(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut pending_space = false;
    for ch in value.chars() {
        if ch.is_alphanumeric() {
            if pending_space && !out.is_empty() {
                out.push(' ');
            }
            pending_space = false;
            for lower in ch.to_lowercase() {
                out.push(lower);
            }
        } else {
            pending_space = true;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(title: &str, channel: &str, duration: f64) -> Candidate {
        Candidate {
            id: title.chars().take(11).collect(),
            title: title.to_string(),
            channel: channel.to_string(),
            duration,
            view_count: None,
            live_now: false,
        }
    }

    fn watched(title: &str, channel: &str, duration: f64, views: u64) -> Candidate {
        Candidate {
            view_count: Some(views),
            ..candidate(title, channel, duration)
        }
    }

    #[test]
    fn a_pressing_qualifier_is_not_part_of_the_song() {
        assert_eq!(search_title("Heart-Shaped Box (Album Version)"), "Heart-Shaped Box");
        assert_eq!(search_title("Come As You Are (2013 Mix)"), "Come As You Are");
        assert_eq!(search_title("Song [Remastered 2011]"), "Song");
        assert_eq!(search_title("Song (Radio Edit)"), "Song");
        assert_eq!(search_title("Song (Original Mix)"), "Song");
    }

    #[test]
    fn a_different_performance_keeps_its_qualifier() {
        assert_eq!(search_title("Song (Acoustic)"), "Song (Acoustic)");
        assert_eq!(search_title("Song (Live at Wembley)"), "Song (Live at Wembley)");
        assert_eq!(search_title("Song (Kaskade Remix)"), "Song (Kaskade Remix)");
        assert_eq!(
            search_title("Heart Shaped Box (Original Steve Albini 1993 Mix)"),
            "Heart Shaped Box (Original Steve Albini 1993 Mix)"
        );
        assert_eq!(search_title("Instant Crush"), "Instant Crush");
    }

    #[test]
    fn a_title_that_is_only_a_qualifier_is_left_alone() {
        assert_eq!(search_title("(Album Version)"), "(Album Version)");
        assert_eq!(search_title(""), "");
    }

    #[test]
    fn normalizes_punctuation_and_case() {
        assert_eq!(normalize("Instant Crush (Official Video)"), "instant crush official video");
        assert_eq!(normalize("Don't — Stop!"), "don t stop");
        assert_eq!(normalize("  "), "");
    }

    #[test]
    fn word_matching_ignores_substrings() {
        assert!(!contains_word("discovery channel", "cover"));
        assert!(contains_word("a cover version", "cover"));
        assert!(!contains_word("delivered", "live"));
        assert!(contains_word("live at wembley", "live"));
        assert!(contains_word("wembley live", "live"));
    }

    #[test]
    fn official_video_beats_lyric_and_fan_edits() {
        let candidates = vec![
            candidate(
                "Daft Punk - Instant Crush (Official Video) ft. Julian Casablancas",
                "Daft Punk",
                340.0,
            ),
            candidate("UNOFFICIAL Daft Punk - Instant Crush", "Daniel m", 333.0),
            candidate("Daft Punk - Instant Crush (Lyrics)", "7clouds", 330.0),
            candidate("Instant Crush - Daft Punk, Unofficial, Extended", "Yuri Zhukov", 735.0),
        ];
        let ranked = rank("Instant Crush", "Daft Punk", 337.0, &candidates);
        assert_eq!(ranked[0].candidate.channel, "Daft Punk");
        assert!(ranked[0].score >= ACCEPT);
        assert!(decisive(&ranked));
    }

    #[test]
    fn drops_candidates_whose_runtime_rules_them_out() {
        let candidates = vec![candidate(
            "Instant Crush - Daft Punk, Unofficial, Extended",
            "Yuri Zhukov",
            735.0,
        )];
        assert!(rank("Instant Crush", "Daft Punk", 337.0, &candidates).is_empty());
    }

    /// The real search for this song, verbatim. Every wrong answer here was
    /// once the one that played: the official video is a minute shorter than
    /// the album cut, and a static-artwork re-upload matches its runtime
    /// exactly.
    #[test]
    fn picks_the_official_video_over_a_runtime_perfect_reupload() {
        let candidates = vec![
            watched(
                "Avenged Sevenfold - Bat Country [Official Music Video]",
                "Avenged Sevenfold",
                251.0,
                80_558_943,
            ),
            watched("Avenged Sevenfold - Bat Country / Lyrics", "MOSHPIT", 312.0, 2_071_488),
            watched(
                "Avenged Sevenfold - Bat Country - Official  Video!",
                "VengeanceTelevision",
                256.0,
                1_481_678,
            ),
            watched(
                "Avenged Sevenfold - Bat Country Music Video FULL SONG [HD]",
                "a7xfan209",
                313.0,
                3_842,
            ),
            watched(
                "Avenged Sevenfold - Bat Country | Live In The LBC 2008 [HD]",
                "Etiennouh",
                330.0,
                1_535_325,
            ),
            watched("Avenged Sevenfold - Bat Country", "lavenged7xl", 314.0, 264_601),
        ];
        let ranked = rank("Bat Country", "Avenged Sevenfold", 313.0, &candidates);
        assert_eq!(ranked[0].candidate.channel, "Avenged Sevenfold");
        assert!(ranked[0].score >= ACCEPT);
        assert!(decisive(&ranked), "the official upload should not need a tie-break");
    }

    #[test]
    fn an_edit_a_minute_shorter_than_the_album_cut_still_qualifies() {
        let short_edit = watched(
            "Artist - Song (Official Music Video)",
            "Artist",
            250.0,
            9_000_000,
        );
        assert!(!rank("Song", "Artist", 313.0, &[short_edit]).is_empty());
    }

    #[test]
    fn reach_separates_an_official_upload_from_a_faithful_copy() {
        let candidates = vec![
            watched("Artist - Song (Official Video)", "Artist", 200.0, 50_000_000),
            watched("Artist - Song (Official Video)", "Artist Fan", 200.0, 900),
        ];
        let ranked = rank("Song", "Artist", 200.0, &candidates);
        assert_eq!(ranked[0].candidate.channel, "Artist");
    }

    #[test]
    fn drops_live_streams() {
        let mut live = candidate("Artist - Song (Official Video)", "Artist", 200.0);
        live.live_now = true;
        assert!(rank("Song", "Artist", 200.0, &[live]).is_empty());
    }

    #[test]
    fn a_song_with_no_matching_title_scores_zero() {
        let other = candidate("Some Other Song (Official Video)", "Daft Punk", 337.0);
        assert_eq!(score("Instant Crush", "Daft Punk", 337.0, &other, 0), 0.0);
    }

    #[test]
    fn topic_uploads_lose_to_a_real_video() {
        let candidates = vec![
            candidate("Instant Crush", "Daft Punk - Topic", 337.0),
            candidate("Daft Punk - Instant Crush (Official Video)", "DaftPunkVEVO", 340.0),
        ];
        let ranked = rank("Instant Crush", "Daft Punk", 337.0, &candidates);
        assert_eq!(ranked[0].candidate.channel, "DaftPunkVEVO");
    }

    #[test]
    fn two_close_readings_are_left_to_the_model() {
        let candidates = vec![
            candidate("Artist - Song (Official Video)", "Artist", 200.0),
            candidate("Artist - Song (Official Music Video)", "ArtistVEVO", 201.0),
        ];
        let ranked = rank("Song", "Artist", 200.0, &candidates);
        assert!(ranked[0].score >= ACCEPT);
        assert!(!decisive(&ranked));
    }

    #[test]
    fn nothing_plausible_is_not_decisive() {
        let candidates = vec![candidate("Song (Lyrics)", "7clouds", 200.0)];
        let ranked = rank("Song", "Artist", 200.0, &candidates);
        assert!(ranked[0].score < ACCEPT);
        assert!(!decisive(&ranked));
    }

    #[test]
    fn feature_credits_still_match_the_lead_artist() {
        let candidates = vec![candidate(
            "Calvin Harris - Feel So Close (Official Video)",
            "Calvin Harris",
            210.0,
        )];
        let ranked = rank("Feel So Close", "Calvin Harris feat. Example", 208.0, &candidates);
        assert!(ranked[0].score >= ACCEPT);
    }
}
