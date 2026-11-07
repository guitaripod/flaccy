use super::text::clip;
use crate::lyrics::{clean_title, lead_artist};
use serde::{Deserialize, Serialize};

/// How many search results are weighed before giving up on an article.
pub const SEARCH_LIMIT: usize = 10;
/// UTF-16 units kept of the article's introduction, of each section, and of
/// everything handed to the model as background.
pub const LEAD_LIMIT: usize = 1_500;
pub const SECTION_LIMIT: usize = 2_000;
pub const BACKGROUND_LIMIT: usize = 3_000;
/// The most sections of an article shown beside its introduction.
pub const MOST_SECTIONS: usize = 3;

/// Words in a section heading that promise the song's meaning or making.
const MEANING_WORDS: [&str; 24] = [
    "background",
    "composition",
    "concept",
    "content",
    "inspiration",
    "inspirations",
    "interpretation",
    "interpretations",
    "lyric",
    "lyrical",
    "lyrics",
    "meaning",
    "meanings",
    "message",
    "origin",
    "origins",
    "song",
    "story",
    "subject",
    "theme",
    "themes",
    "writing",
    "written",
    "narrative",
];

/// Words that mark a heading as about the record's life after it was made,
/// which win over a meaning word in the same heading.
const OFF_TOPIC_WORDS: [&str; 30] = [
    "accolades",
    "awards",
    "bibliography",
    "certification",
    "certifications",
    "chart",
    "charts",
    "controversy",
    "cover",
    "covers",
    "credits",
    "critical",
    "culture",
    "format",
    "formats",
    "legacy",
    "links",
    "listing",
    "live",
    "notes",
    "parodies",
    "performances",
    "personnel",
    "reception",
    "references",
    "release",
    "remixes",
    "sales",
    "versions",
    "video",
];

/// A search result: the article's title and its short description, which for
/// a song reads like "1991 single by Nirvana".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArticleCandidate {
    pub title: String,
    pub description: String,
}

/// One `== Heading ==` part of an article's plain text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Section {
    pub heading: String,
    pub level: usize,
    pub body: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorySection {
    pub heading: String,
    pub body: String,
}

/// What Wikipedia says about a song: the introduction and the sections about
/// its meaning and making, cut to size, with where they came from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SongStory {
    pub article: String,
    pub url: String,
    pub language: String,
    pub lead: String,
    pub sections: Vec<StorySection>,
}

/// The Wikipedia to read a story from: its subdomain, and the script variant
/// Chinese articles are converted to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Wiki {
    pub language: String,
    pub variant: Option<String>,
}

/// The Wikipedia for an app localization such as `de`, `pt-BR` or `zh-Hant`.
pub fn wiki_for(localization: &str) -> Wiki {
    let lower = localization.trim().to_lowercase().replace('_', "-");
    let variant = match lower.as_str() {
        "zh-hans" | "zh-cn" | "zh-sg" => Some("zh-cn".to_string()),
        "zh-hant" | "zh-tw" | "zh-hk" | "zh-mo" => Some("zh-tw".to_string()),
        _ => None,
    };
    let language = lower.split('-').next().unwrap_or("").to_string();
    let language = if language.is_empty() || !language.chars().all(|c| c.is_ascii_lowercase()) {
        "en".to_string()
    } else {
        language
    };
    Wiki { language, variant }
}

/// The song a recording is a version of, for finding writing about it: a
/// leading track number removed, then the lyrics query's cleaning, then every
/// bracketed group and a dashed suffix ("- Live", "- Radio Edit"). A live take
/// or a remix means what the song means.
pub fn song_title(title: &str) -> String {
    let cleaned = clean_title(strip_track_number(title.trim()));
    let ungrouped = remove_groups(&cleaned);
    let undashed = [" - ", " \u{2013} ", " \u{2014} "]
        .iter()
        .filter_map(|separator| ungrouped.find(separator))
        .min()
        .map_or(ungrouped.as_str(), |index| &ungrouped[..index]);
    let collapsed = undashed.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        cleaned
    } else {
        collapsed
    }
}

/// What to search Wikipedia for.
pub fn search_terms(title: &str, artist: &str) -> String {
    format!("{} {} song", song_title(title), lead_artist(artist))
}

/// The first search result that is this song's own article: its title, less a
/// trailing disambiguation, reads as the song's title, and its description or
/// disambiguation says it is a song or single by the lead artist.
pub fn pick_article(candidates: &[ArticleCandidate], title: &str, artist: &str) -> Option<usize> {
    let wanted_title = tokens(&song_title(title));
    let wanted_artist = tokens(&lead_artist(artist));
    if wanted_title.is_empty() || wanted_artist.is_empty() {
        return None;
    }
    candidates.iter().position(|candidate| {
        let (base, qualifier) = split_disambiguation(&candidate.title);
        if tokens(base) != wanted_title {
            return false;
        }
        let description = tokens(&candidate.description);
        let qualifier = tokens(qualifier);
        let is_song = [&description, &qualifier]
            .iter()
            .any(|words| words.iter().any(|word| word == "song" || word == "single"));
        let by_artist =
            contains_run(&description, &wanted_artist) || contains_run(&qualifier, &wanted_artist);
        is_song && by_artist
    })
}

/// Splits the plain text the TextExtracts API returns with `exsectionformat=wiki`
/// into its introduction and its sections, each a list of paragraphs.
pub fn parse_extract(extract: &str) -> (Vec<String>, Vec<Section>) {
    let mut lead = Vec::new();
    let mut sections: Vec<Section> = Vec::new();
    for line in extract.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some((level, heading)) = heading_of(line) {
            sections.push(Section {
                heading,
                level,
                body: Vec::new(),
            });
            continue;
        }
        match sections.last_mut() {
            Some(section) => section.body.push(line.to_string()),
            None => lead.push(line.to_string()),
        }
    }
    (lead, sections)
}

/// Whether a section heading promises what the song means or how it was made.
pub fn is_meaning_heading(heading: &str) -> bool {
    let words = tokens(heading);
    words.iter().any(|word| MEANING_WORDS.contains(&word.as_str()))
        && !words.iter().any(|word| OFF_TOPIC_WORDS.contains(&word.as_str()))
}

/// The story an article tells: its introduction, and with `with_sections` (an
/// English article, whose headings can be read) up to `MOST_SECTIONS` sections
/// about the song's meaning, each cut to size. `None` when nothing is left.
pub fn story(
    article: &str,
    url: &str,
    language: &str,
    extract: &str,
    with_sections: bool,
) -> Option<SongStory> {
    let (lead, sections) = parse_extract(extract);
    let lead = clip(&as_strs(&lead), LEAD_LIMIT);
    let sections: Vec<StorySection> = if with_sections {
        sections
            .iter()
            .filter(|section| !section.body.is_empty() && is_meaning_heading(&section.heading))
            .take(MOST_SECTIONS)
            .map(|section| StorySection {
                heading: section.heading.clone(),
                body: clip(&as_strs(&section.body), SECTION_LIMIT),
            })
            .filter(|section| !section.body.is_empty())
            .collect()
    } else {
        Vec::new()
    };
    if lead.is_empty() && sections.is_empty() {
        return None;
    }
    Some(SongStory {
        article: article.to_string(),
        url: url.to_string(),
        language: language.to_string(),
        lead,
        sections,
    })
}

/// The story as one passage for the model, sections introduced by their
/// headings, cut to `BACKGROUND_LIMIT`.
pub fn background(story: &SongStory) -> String {
    let mut paragraphs: Vec<String> = story
        .lead
        .split("\n\n")
        .map(str::to_string)
        .collect();
    for section in &story.sections {
        let mut parts = section.body.split("\n\n");
        if let Some(first) = parts.next() {
            paragraphs.push(format!("{}: {first}", section.heading));
        }
        paragraphs.extend(parts.map(str::to_string));
    }
    clip(&as_strs(&paragraphs), BACKGROUND_LIMIT)
}

fn as_strs(paragraphs: &[String]) -> Vec<&str> {
    paragraphs.iter().map(String::as_str).collect()
}

/// `== Heading ==` at any depth, as its depth and text.
fn heading_of(line: &str) -> Option<(usize, String)> {
    let level = line.chars().take_while(|&c| c == '=').count();
    if level < 2 || !line.ends_with(&"=".repeat(level)) || line.chars().count() <= level * 2 {
        return None;
    }
    let inner = line[level..line.len() - level].trim();
    if inner.is_empty() {
        return None;
    }
    Some((level, inner.to_string()))
}

/// Lowercased runs of letters and digits, the way titles and descriptions are
/// compared.
fn tokens(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(str::to_string)
        .collect()
}

fn contains_run(haystack: &[String], needle: &[String]) -> bool {
    !needle.is_empty() && haystack.windows(needle.len()).any(|window| window == needle)
}

/// "Kim (song)" as "Kim" and "song"; a title without a trailing group as
/// itself and nothing.
fn split_disambiguation(title: &str) -> (&str, &str) {
    let trimmed = title.trim();
    if trimmed.ends_with(')') {
        if let Some(open) = trimmed.rfind(" (") {
            return (&trimmed[..open], &trimmed[open + 2..trimmed.len() - 1]);
        }
    }
    (trimmed, "")
}

/// "09 - Song" and "9. Song" as "Song"; a number that is the title's own
/// first word ("99 Problems") stays.
fn strip_track_number(title: &str) -> &str {
    let digits = title.chars().take_while(char::is_ascii_digit).count();
    if digits == 0 || digits > 3 {
        return title;
    }
    let rest = title[digits..].trim_start();
    let Some(after) = rest.strip_prefix(['-', '.']) else {
        return title;
    };
    if !after.starts_with(char::is_whitespace) {
        return title;
    }
    let after = after.trim_start();
    if after.is_empty() {
        title
    } else {
        after
    }
}

/// The text with every top-level `(…)` or `[…]` group removed; a group that
/// never closes is kept as written.
fn remove_groups(text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < characters.len() {
        let character = characters[index];
        if character == '(' || character == '[' {
            if let Some(close) = matching_close(&characters, index) {
                index = close + 1;
                continue;
            }
        }
        out.push(character);
        index += 1;
    }
    out
}

fn matching_close(characters: &[char], open: usize) -> Option<usize> {
    let mut depth = 0i32;
    for (offset, character) in characters[open..].iter().enumerate() {
        match character {
            '(' | '[' => depth += 1,
            ')' | ']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(open + offset);
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(title: &str, description: &str) -> ArticleCandidate {
        ArticleCandidate {
            title: title.to_string(),
            description: description.to_string(),
        }
    }

    #[test]
    fn a_recording_is_searched_for_as_the_song_it_is_a_version_of() {
        assert_eq!(song_title("Smells Like Teen Spirit (Remastered 2021)"), "Smells Like Teen Spirit");
        assert_eq!(song_title("When I'm Gone (Album Version (Explicit))"), "When I'm Gone");
        assert_eq!(song_title("09 - Flashing Lights feat. Dwele"), "Flashing Lights");
        assert_eq!(song_title("9. Breed"), "Breed");
        assert_eq!(song_title("A Small Victory (Live In Munich 1992)"), "A Small Victory");
        assert_eq!(song_title("Play - INFANCTUS Remix"), "Play");
        assert_eq!(song_title("99 Problems"), "99 Problems");
        assert_eq!(song_title("1-800-273-8255"), "1-800-273-8255");
        assert_eq!(song_title("(Untitled)"), "(Untitled)");
    }

    #[test]
    fn the_search_names_the_song_its_lead_artist_and_the_word_song() {
        assert_eq!(
            search_terms("Mo Money Mo Problems (Feat. Mase & Puff Daddy)", "The Notorious B.I.G. feat. Mase"),
            "Mo Money Mo Problems The Notorious B.I.G. song"
        );
    }

    #[test]
    fn the_songs_own_article_is_picked_over_the_album_and_a_parody() {
        let candidates = [
            candidate("Nevermind", "1991 studio album by Nirvana"),
            candidate("Smells Like Nirvana", "1992 single by \"Weird Al\" Yankovic"),
            candidate("Smells Like Teen Spirit", "1991 single by Nirvana"),
        ];
        assert_eq!(pick_article(&candidates, "Smells Like Teen Spirit", "Nirvana"), Some(2));
    }

    #[test]
    fn a_disambiguated_title_matches_and_can_name_the_artist() {
        let candidates = [
            candidate("Kim Mathers", "American woman"),
            candidate("Kim (song)", "2000 song by Eminem"),
        ];
        assert_eq!(pick_article(&candidates, "Kim", "Eminem"), Some(1));
        let qualified = [candidate("Nightmare (Avenged Sevenfold song)", "")];
        assert_eq!(pick_article(&qualified, "Nightmare", "Avenged Sevenfold"), Some(0));
    }

    #[test]
    fn a_song_by_someone_else_or_an_album_is_refused() {
        let candidates = [
            candidate("Nightmare (Avenged Sevenfold album)", "2010 studio album by Avenged Sevenfold"),
            candidate("Nightmare (Halsey song)", "2019 single by Halsey"),
        ];
        assert_eq!(pick_article(&candidates, "Nightmare", "Avenged Sevenfold"), None);
    }

    #[test]
    fn punctuation_and_case_do_not_matter_but_whole_words_do() {
        let candidates = [candidate("Mr. Brownstone", "1987 single by Guns N' Roses")];
        assert_eq!(pick_article(&candidates, "Mr Brownstone", "Guns N’ Roses"), Some(0));
        let partial = [candidate("Ross", "Song by Diana Ross")];
        assert_eq!(pick_article(&partial, "Ross", "Ross"), Some(0));
        assert_eq!(pick_article(&partial, "Ross", "Diana"), Some(0));
        assert_eq!(pick_article(&partial, "Ross", "Dian"), None);
    }

    #[test]
    fn nothing_is_picked_without_a_title_or_an_artist() {
        let candidates = [candidate("Song", "song by someone")];
        assert_eq!(pick_article(&candidates, "", "someone"), None);
        assert_eq!(pick_article(&candidates, "Song", "  "), None);
    }

    #[test]
    fn localizations_map_to_their_wikipedia() {
        assert_eq!(wiki_for("en"), Wiki { language: "en".into(), variant: None });
        assert_eq!(wiki_for("pt-BR"), Wiki { language: "pt".into(), variant: None });
        assert_eq!(wiki_for("zh-Hans"), Wiki { language: "zh".into(), variant: Some("zh-cn".into()) });
        assert_eq!(wiki_for("zh-Hant"), Wiki { language: "zh".into(), variant: Some("zh-tw".into()) });
        assert_eq!(wiki_for(""), Wiki { language: "en".into(), variant: None });
    }

    const EXTRACT: &str = "\"Breed\" is a song by Nirvana.\nIt was written by Kurt Cobain.\n\n\n== Early history ==\nOriginally titled \"Imodium\".\n\n\n== Composition ==\n\n\n=== Music ===\nA driving riff.\n\n\n=== Lyrics ===\nThe lyrics mock suburban conformity.\nCobain called it a joke.\n\n\n== Release and reception ==\nIt charted.\n\n\n== Song meaning ==\nA second take.\n\n\n== Themes ==\nA third.\n\n\n== Lyrical content ==\nA fourth that is never shown.\n\n\n== References ==\n";

    #[test]
    fn an_extract_splits_into_its_introduction_and_sections() {
        let (lead, sections) = parse_extract(EXTRACT);
        assert_eq!(lead, vec!["\"Breed\" is a song by Nirvana.", "It was written by Kurt Cobain."]);
        let headings: Vec<(&str, usize)> = sections
            .iter()
            .map(|section| (section.heading.as_str(), section.level))
            .collect();
        assert_eq!(
            headings,
            vec![
                ("Early history", 2),
                ("Composition", 2),
                ("Music", 3),
                ("Lyrics", 3),
                ("Release and reception", 2),
                ("Song meaning", 2),
                ("Themes", 2),
                ("Lyrical content", 2),
                ("References", 2),
            ]
        );
        assert_eq!(sections[3].body, vec!["The lyrics mock suburban conformity.", "Cobain called it a joke."]);
        assert!(sections[1].body.is_empty());
    }

    #[test]
    fn headings_about_meaning_are_kept_and_the_records_afterlife_is_not() {
        for heading in ["Background", "Writing and recording", "Lyrics and interpretation", "Song", "Composition and lyrics"] {
            assert!(is_meaning_heading(heading), "{heading}");
        }
        for heading in ["Music video", "Release and reception", "Charts", "Live performances", "Covers of the song", "Music", "In popular culture"] {
            assert!(!is_meaning_heading(heading), "{heading}");
        }
    }

    #[test]
    fn a_story_keeps_the_introduction_and_the_first_three_meaning_sections_with_text() {
        let story = story("Breed (song)", "https://en.wikipedia.org/wiki/Breed_(song)", "en", EXTRACT, true)
            .expect("a story");
        assert_eq!(story.lead, "\"Breed\" is a song by Nirvana.\n\nIt was written by Kurt Cobain.");
        let headings: Vec<&str> = story.sections.iter().map(|section| section.heading.as_str()).collect();
        assert_eq!(headings, vec!["Lyrics", "Song meaning", "Themes"]);
        assert_eq!(story.sections[0].body, "The lyrics mock suburban conformity.\n\nCobain called it a joke.");
    }

    #[test]
    fn a_story_without_sections_is_the_introduction_alone() {
        let story = story("Breed", "u", "de", EXTRACT, false).expect("a story");
        assert!(story.sections.is_empty());
        assert!(super::story("x", "u", "en", "== Only ==\n", true).is_none());
    }

    #[test]
    fn the_background_names_each_section_and_stays_within_its_limit() {
        let story = story("Breed", "u", "en", EXTRACT, true).expect("a story");
        assert_eq!(
            background(&story),
            "\"Breed\" is a song by Nirvana.\n\nIt was written by Kurt Cobain.\n\nLyrics: The lyrics mock suburban conformity.\n\nCobain called it a joke.\n\nSong meaning: A second take.\n\nThemes: A third."
        );
        let long = SongStory {
            article: "a".into(),
            url: "u".into(),
            language: "en".into(),
            lead: "word ".repeat(1_000),
            sections: Vec::new(),
        };
        assert!(super::super::utf16_len(&background(&long)) <= BACKGROUND_LIMIT);
    }

    #[test]
    fn a_story_round_trips_through_json() {
        let story = story("Breed", "u", "en", EXTRACT, true).expect("a story");
        let json = serde_json::to_string(&story).expect("encodes");
        assert_eq!(serde_json::from_str::<SongStory>(&json).expect("decodes"), story);
    }
}
