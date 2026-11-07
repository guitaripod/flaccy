/// The stored row that holds a song's Wikipedia story, or an empty body for
/// "Wikipedia has no article about it".
pub const STORY_SCOPE: &str = "wikipedia";
/// The stored row that holds the model's reading of the whole song.
pub const SONG_SCOPE: &str = "song";
/// How long a found story and a miss are believed before Wikipedia is asked
/// again. A reading the model wrote never goes stale: asking again would cost
/// a request and give a different wording of the same thing.
pub const STORY_STALE_DAYS: f64 = 90.0;
pub const STORY_MISS_DAYS: f64 = 30.0;

/// The stored row for one line's reading. A chorus sung four times is one
/// question, whatever its case or spacing.
pub fn line_scope(text: &str) -> String {
    let folded = text
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    format!("line:{folded}")
}

/// Whether a stored row still answers, by its scope, whether it holds
/// anything and how many days old it is.
pub fn is_fresh(scope: &str, has_body: bool, age_days: f64) -> bool {
    if scope != STORY_SCOPE {
        return has_body;
    }
    let limit = if has_body { STORY_STALE_DAYS } else { STORY_MISS_DAYS };
    age_days < limit
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_is_one_question_whatever_its_case_or_spacing() {
        assert_eq!(line_scope("  Here we are NOW,\tentertain us "), "line:here we are now, entertain us");
        assert_eq!(line_scope("Here we are now, entertain us"), line_scope("here  we are now, ENTERTAIN us"));
    }

    #[test]
    fn a_story_is_asked_for_again_after_ninety_days_and_a_miss_after_thirty() {
        assert!(is_fresh(STORY_SCOPE, true, 89.9));
        assert!(!is_fresh(STORY_SCOPE, true, 90.0));
        assert!(is_fresh(STORY_SCOPE, false, 29.9));
        assert!(!is_fresh(STORY_SCOPE, false, 30.0));
    }

    #[test]
    fn a_reading_never_goes_stale_and_an_empty_one_never_counts() {
        assert!(is_fresh(SONG_SCOPE, true, 10_000.0));
        assert!(is_fresh(&line_scope("a"), true, 10_000.0));
        assert!(!is_fresh(SONG_SCOPE, false, 0.0));
    }
}
