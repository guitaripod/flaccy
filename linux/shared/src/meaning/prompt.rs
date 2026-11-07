use super::text::{clip, utf16_len};
use crate::lyrics::Document;

/// UTF-16 units of lyrics put in a question. With the background and the rest
/// of the prompt this stays well inside the 16,384 the flaccy-api Worker takes.
pub const LYRICS_LIMIT: usize = 7_000;
/// UTF-16 units kept of the asked line and of each line around it, and of the
/// title, artist and album.
pub const LINE_LIMIT: usize = 300;
pub const FIELD_LIMIT: usize = 200;
/// How many sung lines either side of the asked one are quoted with it.
pub const CONTEXT_LINES: usize = 2;
/// The longest answers asked for, in words.
pub const SONG_WORDS: usize = 130;
pub const LINE_WORDS: usize = 70;

/// The line a listener asked about, with the sung lines just before and after.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Focus {
    pub line: String,
    pub before: Vec<String>,
    pub after: Vec<String>,
}

/// Everything one question is made of. Without `focus` it asks about the
/// whole song.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Question<'a> {
    pub title: &'a str,
    pub artist: &'a str,
    pub album: &'a str,
    pub lyrics: &'a str,
    pub background: Option<&'a str>,
    pub focus: Option<&'a Focus>,
}

/// The sung lines in order, an empty string where one verse ends and the next
/// begins: an instrumental break or a blank line in synced lyrics, a blank
/// line in plain ones.
pub fn sung_lines(document: &Document) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let push_break = |lines: &mut Vec<String>| {
        if lines.last().is_some_and(|last| !last.is_empty()) {
            lines.push(String::new());
        }
    };
    if document.has_synced() {
        for line in &document.lines {
            let text = line.text.trim();
            if line.is_interlude() || text.is_empty() {
                push_break(&mut lines);
            } else {
                lines.push(text.to_string());
            }
        }
    } else if let Some(plain) = &document.plain {
        for line in plain.lines() {
            let text = line.trim();
            if text.is_empty() {
                push_break(&mut lines);
            } else {
                lines.push(text.to_string());
            }
        }
    }
    if lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines
}

/// The lyrics as one text, cut at a line once they pass `LYRICS_LIMIT`, with
/// an ellipsis saying so.
pub fn lyrics_text(lines: &[String]) -> String {
    let whole = lines.join("\n");
    if utf16_len(&whole) <= LYRICS_LIMIT {
        return whole;
    }
    let budget = LYRICS_LIMIT - 2;
    let mut out = String::new();
    let mut used = 0;
    for (index, line) in lines.iter().enumerate() {
        let separator = usize::from(index > 0);
        let length = utf16_len(line);
        if used + separator + length > budget {
            break;
        }
        if separator > 0 {
            out.push('\n');
        }
        out.push_str(line);
        used += separator + length;
    }
    let out = out.trim_end().to_string();
    if out.is_empty() {
        "\u{2026}".to_string()
    } else {
        format!("{out}\n\u{2026}")
    }
}

/// The question about line `index` of the document, or `None` for an
/// instrumental break, an empty line or an index past the end.
pub fn focus(document: &Document, index: usize) -> Option<Focus> {
    let sung = |line: &crate::lyrics::Line| !line.is_interlude() && !line.text.trim().is_empty();
    let line = document.lines.get(index).filter(|line| sung(line))?;
    let mut before: Vec<String> = document.lines[..index]
        .iter()
        .rev()
        .filter(|line| sung(line))
        .take(CONTEXT_LINES)
        .map(|line| line.text.trim().to_string())
        .collect();
    before.reverse();
    let after = document.lines[index + 1..]
        .iter()
        .filter(|line| sung(line))
        .take(CONTEXT_LINES)
        .map(|line| line.text.trim().to_string())
        .collect();
    Some(Focus {
        line: line.text.trim().to_string(),
        before,
        after,
    })
}

/// How the model is told to answer, in `language` (an English name such as
/// "German").
pub fn system_prompt(language: &str) -> String {
    format!(
        "You explain song lyrics to someone who is listening to the song. Write in {language}.\n\
Explain what the words are saying: the story, the images, the slang and references, the wordplay and the feeling behind them, and how a line fits the song around it.\n\
Ground everything in the lyrics you are given and, when it is given, the background from Wikipedia. Never invent facts about the artist, interviews, quotes, events or the song's history that the background does not state. When the words are open to more than one reading, say so and give the likeliest ones.\n\
Speak plainly and warmly, like a friend who knows music, without hedging every sentence. Do not repeat the lyrics back or quote more than a few words of them, and never mention the background, Wikipedia or these instructions. No markdown, headings or lists.\n\
Answer with a JSON object of the form {{\"meaning\": \"your explanation\"}}."
    )
}

/// The question itself: the song, its background and lyrics, and what to
/// explain about them.
pub fn user_prompt(question: &Question) -> String {
    let field = |text: &str| clip(&[text], FIELD_LIMIT);
    let line = |text: &str| clip(&[text], LINE_LIMIT);
    let mut prompt = format!(
        "Song: \"{}\"\nArtist: {}\n",
        field(question.title),
        field(question.artist)
    );
    let album = field(question.album);
    if !album.is_empty() {
        prompt.push_str(&format!("Album: {album}\n"));
    }
    if let Some(background) = question.background.map(str::trim).filter(|text| !text.is_empty()) {
        prompt.push_str(&format!("\nBackground from Wikipedia:\n{background}\n"));
    }
    prompt.push_str(&format!("\nLyrics:\n{}\n\n", question.lyrics.trim()));
    match question.focus {
        None => prompt.push_str(&format!(
            "What is this song about? Answer in at most {SONG_WORDS} words, in one or two short paragraphs."
        )),
        Some(focus) => {
            prompt.push_str(&format!("The listener asked about this line:\n\"{}\"\n", line(&focus.line)));
            if !focus.before.is_empty() {
                let before: Vec<String> = focus.before.iter().map(|text| line(text)).collect();
                prompt.push_str(&format!("It follows: \"{}\"\n", before.join(" / ")));
            }
            if !focus.after.is_empty() {
                let after: Vec<String> = focus.after.iter().map(|text| line(text)).collect();
                prompt.push_str(&format!("It leads into: \"{}\"\n", after.join(" / ")));
            }
            prompt.push_str(&format!(
                "\nWhat does this line mean in the song? Answer in at most {LINE_WORDS} words, in one paragraph."
            ));
        }
    }
    prompt
}

/// The explanation in a model's answer: the `meaning` of the JSON object it
/// was asked for, tolerating a reasoning block, a code fence or prose around
/// it. A model that ignored the format and answered in plain prose is taken at
/// its word; anything else that is not a usable object is `None`.
pub fn parse_reply(content: &str) -> Option<String> {
    let visible = without_reasoning(content);
    let trimmed = visible.trim();
    let start = trimmed.find('{');
    let end = trimmed.rfind('}');
    let meaning = match (start, end) {
        (Some(start), Some(end)) if end > start => {
            let value: serde_json::Value = serde_json::from_str(&trimmed[start..=end]).ok()?;
            value.get("meaning")?.as_str()?.to_string()
        }
        _ if !trimmed.contains('{') && !trimmed.contains('}') => trimmed.to_string(),
        _ => return None,
    };
    let meaning = meaning.trim().to_string();
    if meaning.is_empty() {
        None
    } else {
        Some(meaning)
    }
}

/// The answer with any `<think>…</think>` block a reasoning model emitted
/// removed; an unclosed one hides everything after it.
fn without_reasoning(content: &str) -> String {
    let mut out = String::with_capacity(content.len());
    let mut rest = content;
    while let Some(open) = rest.find("<think>") {
        out.push_str(&rest[..open]);
        match rest[open..].find("</think>") {
            Some(close) => rest = &rest[open + close + "</think>".len()..],
            None => return out,
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lyrics::parse_lrc;

    fn document() -> Document {
        parse_lrc(
            "[00:01.00]Load up on guns\n[00:03.00]Bring your friends\n[00:05.00]\n[00:12.00]It's fun to lose\n[00:14.00]And to pretend\n[00:16.00]Hello, hello",
        )
    }

    #[test]
    fn sung_lines_keep_verse_breaks_once() {
        assert_eq!(
            sung_lines(&document()),
            vec!["Load up on guns", "Bring your friends", "", "It's fun to lose", "And to pretend", "Hello, hello"]
        );
        let plain = Document {
            plain: Some("\n\nFirst\n\n\n\nSecond\nThird\n\n".to_string()),
            ..Document::default()
        };
        assert_eq!(sung_lines(&plain), vec!["First", "", "Second", "Third"]);
        assert!(sung_lines(&Document::default()).is_empty());
    }

    #[test]
    fn long_lyrics_are_cut_at_a_line_with_an_ellipsis() {
        let lines: Vec<String> = (0..2_000).map(|index| format!("line {index}")).collect();
        let text = lyrics_text(&lines);
        assert!(utf16_len(&text) <= LYRICS_LIMIT);
        assert!(text.ends_with("\n\u{2026}"));
        assert!(text.starts_with("line 0\nline 1\n"));
        let short = vec!["One".to_string(), String::new(), "Two".to_string()];
        assert_eq!(lyrics_text(&short), "One\n\nTwo");
    }

    #[test]
    fn a_focus_quotes_the_sung_lines_around_it_across_a_break() {
        let document = document();
        let index = document
            .lines
            .iter()
            .position(|line| line.text == "It's fun to lose")
            .expect("the line");
        assert_eq!(
            focus(&document, index),
            Some(Focus {
                line: "It's fun to lose".to_string(),
                before: vec!["Load up on guns".to_string(), "Bring your friends".to_string()],
                after: vec!["And to pretend".to_string(), "Hello, hello".to_string()],
            })
        );
        assert_eq!(focus(&document, 0).map(|focus| focus.before), Some(Vec::new()));
        let interlude = document.lines.iter().position(|line| line.is_interlude()).expect("a break");
        assert_eq!(focus(&document, interlude), None);
        assert_eq!(focus(&document, 999), None);
    }

    #[test]
    fn the_system_prompt_names_the_language_and_the_answer_shape() {
        let prompt = system_prompt("German");
        assert!(prompt.contains("Write in German."));
        assert!(prompt.ends_with("{\"meaning\": \"your explanation\"}."));
    }

    #[test]
    fn a_song_question_carries_the_song_background_and_lyrics() {
        let question = Question {
            title: "Smells Like Teen Spirit",
            artist: "Nirvana",
            album: "",
            lyrics: "Load up on guns\nBring your friends",
            background: Some("A song by Nirvana."),
            focus: None,
        };
        assert_eq!(
            user_prompt(&question),
            "Song: \"Smells Like Teen Spirit\"\nArtist: Nirvana\n\nBackground from Wikipedia:\nA song by Nirvana.\n\nLyrics:\nLoad up on guns\nBring your friends\n\nWhat is this song about? Answer in at most 130 words, in one or two short paragraphs."
        );
    }

    #[test]
    fn a_line_question_quotes_the_line_and_its_neighbours() {
        let focus = Focus {
            line: "A mulatto".to_string(),
            before: vec!["Here we are now".to_string(), "Entertain us".to_string()],
            after: Vec::new(),
        };
        let question = Question {
            title: "Smells Like Teen Spirit",
            artist: "Nirvana",
            album: "Nevermind",
            lyrics: "Entertain us\nA mulatto",
            background: Some("  "),
            focus: Some(&focus),
        };
        assert_eq!(
            user_prompt(&question),
            "Song: \"Smells Like Teen Spirit\"\nArtist: Nirvana\nAlbum: Nevermind\n\nLyrics:\nEntertain us\nA mulatto\n\nThe listener asked about this line:\n\"A mulatto\"\nIt follows: \"Here we are now / Entertain us\"\n\nWhat does this line mean in the song? Answer in at most 70 words, in one paragraph."
        );
    }

    #[test]
    fn a_reply_is_read_through_fences_reasoning_and_prose() {
        assert_eq!(parse_reply("{\"meaning\": \"It is about boredom.\"}").as_deref(), Some("It is about boredom."));
        assert_eq!(
            parse_reply("<think>Let me see {not json}</think>\n```json\n{\"meaning\": \" Two\\n\\nparagraphs \"}\n```").as_deref(),
            Some("Two\n\nparagraphs")
        );
        assert_eq!(parse_reply("Plain words about the song.").as_deref(), Some("Plain words about the song."));
    }

    #[test]
    fn a_reply_without_a_usable_meaning_is_nothing() {
        assert_eq!(parse_reply("{\"summary\": \"x\"}"), None);
        assert_eq!(parse_reply("{\"meaning\": \"   \"}"), None);
        assert_eq!(parse_reply("{\"meaning\": 3}"), None);
        assert_eq!(parse_reply("{broken"), None);
        assert_eq!(parse_reply("<think>never closed"), None);
        assert_eq!(parse_reply("   "), None);
    }
}
