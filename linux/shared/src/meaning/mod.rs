//! What a song's lyrics mean: the song's own story from Wikipedia, and the
//! questions a language model is asked about the whole song or one line of it.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/LyricsMeaning` and is covered by
//! the same cases, so every client finds the same article, keeps the same
//! sections and asks the model the same words.

mod cache;
mod prompt;
mod text;
mod wikipedia;

pub use cache::{is_fresh, line_scope, SONG_SCOPE, STORY_MISS_DAYS, STORY_SCOPE, STORY_STALE_DAYS};
pub use prompt::{
    focus, lyrics_text, parse_reply, sung_lines, system_prompt, user_prompt, Focus, Question,
    CONTEXT_LINES, FIELD_LIMIT, LINE_LIMIT, LINE_WORDS, LYRICS_LIMIT, SONG_WORDS,
};
pub use text::{clip, utf16_len};
pub use wikipedia::{
    background, is_meaning_heading, parse_extract, pick_article, search_terms, song_title, story,
    wiki_for, ArticleCandidate, Section, SongStory, StorySection, Wiki, BACKGROUND_LIMIT,
    LEAD_LIMIT, MOST_SECTIONS, SEARCH_LIMIT, SECTION_LIMIT,
};
