//! What a song's lyrics mean on Linux: what Wikipedia says about the song, and
//! a reading of the whole song or one of its lines by a model on this
//! computer, both kept in the library database. Linux never asks flaccy-api's
//! AI proxy, so without a local model only Wikipedia answers.

pub mod copy;
pub mod local_model;
pub mod wikipedia;

use crate::db::Db;
use crate::library::Track;
use flaccy_shared::lyrics::Document;
use flaccy_shared::meaning::{
    background, focus, is_fresh, line_scope, lyrics_text, parse_reply, sung_lines, system_prompt,
    user_prompt, Focus, Question, SongStory, SONG_SCOPE, STORY_SCOPE,
};
use local_model::ModelFailure;
use std::path::Path;
use wikipedia::LookupFailure;

/// The Linux client speaks English, so it reads English Wikipedia and asks
/// for English answers.
const LANGUAGE: &str = "en";
const LANGUAGE_NAME: &str = "English";

/// What Wikipedia had to say about a song.
#[derive(Clone, Debug, PartialEq)]
pub enum StoryOutcome {
    Found(SongStory),
    Missing,
    Failed(LookupFailure),
}

/// Where a reading was asked: the server's address and the model's id, for
/// the attribution under the answer and the words of a failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reader {
    pub server: String,
    pub model: String,
}

/// What asking for a reading came to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reading {
    Answered { text: String, model: String },
    Failed { failure: ModelFailure, reader: Reader },
}

/// The song's story: a fresh stored answer, else Wikipedia's, which is then
/// stored; a stale stored story stands in when Wikipedia cannot be reached.
pub fn story(db_path: &Path, track: &Track) -> StoryOutcome {
    let db = Db::open(db_path).ok();
    let stored = db
        .as_ref()
        .and_then(|db| db.fetch_lyric_meaning(&track.title, &track.artist, STORY_SCOPE, LANGUAGE));
    if let Some((body, age)) = &stored {
        if is_fresh(STORY_SCOPE, !body.is_empty(), *age) {
            return decode(body);
        }
    }
    match wikipedia::lookup(&track.title, &track.artist) {
        Ok(found) => {
            let body = found
                .as_ref()
                .and_then(|story| serde_json::to_string(story).ok())
                .unwrap_or_default();
            if let Some(db) = &db {
                let _ = db.save_lyric_meaning(&track.title, &track.artist, STORY_SCOPE, LANGUAGE, &body);
            }
            found.map_or(StoryOutcome::Missing, StoryOutcome::Found)
        }
        Err(failure) => match stored {
            Some((body, _)) if !body.is_empty() => decode(&body),
            _ => StoryOutcome::Failed(failure),
        },
    }
}

fn decode(body: &str) -> StoryOutcome {
    serde_json::from_str::<SongStory>(body).map_or(StoryOutcome::Missing, StoryOutcome::Found)
}

/// The question about line `line` of the document, or about the whole song
/// when `line` is `None`. `None` when the line has nothing sung in it.
pub fn focus_for(document: &Document, line: Option<usize>) -> Option<Option<Focus>> {
    match line {
        None => Some(None),
        Some(index) => focus(document, index).map(Some),
    }
}

/// A reading of the song, or of `focus` within it: a stored one, else the
/// local model's, which is then stored. `asking` hears which model is asked
/// before the wait for its answer begins.
#[allow(clippy::too_many_arguments)]
pub fn reading(
    db_path: &Path,
    track: &Track,
    document: &Document,
    focus: Option<&Focus>,
    story: Option<&SongStory>,
    configured_server: &str,
    configured_model: &str,
    asking: &dyn Fn(&str),
) -> Reading {
    let scope = focus.map_or_else(|| SONG_SCOPE.to_string(), |focus| line_scope(&focus.line));
    let db = Db::open(db_path).ok();
    if let Some((body, age)) = db
        .as_ref()
        .and_then(|db| db.fetch_lyric_meaning(&track.title, &track.artist, &scope, LANGUAGE))
    {
        if is_fresh(&scope, !body.is_empty(), age) {
            let (model, text) = split_signed(&body);
            return Reading::Answered { text, model };
        }
    }
    let server = local_model::server_url(configured_server);
    let models = match local_model::models(&server) {
        Ok(models) => models,
        Err(failure) => return failed(failure, &server, configured_model),
    };
    let Some(model) = local_model::choose(configured_model, &models) else {
        return failed(ModelFailure::NoModels, &server, configured_model);
    };
    let lyrics = lyrics_text(&sung_lines(document));
    let background = story.map(background);
    let question = Question {
        title: &track.title,
        artist: &track.artist,
        album: &track.album,
        lyrics: &lyrics,
        background: background.as_deref(),
        focus,
    };
    asking(&model);
    crate::logger::info(
        "meaning",
        &format!("asking {model} at {server} about {}", if focus.is_some() { "a line" } else { "the song" }),
    );
    let answer = local_model::chat(&server, &model, &system_prompt(LANGUAGE_NAME), &user_prompt(&question));
    let text = match answer.map(|content| parse_reply(&content)) {
        Ok(Some(text)) => text,
        Ok(None) => return failed(ModelFailure::Unreadable, &server, &model),
        Err(failure) => return failed(failure, &server, &model),
    };
    if let Some(db) = &db {
        let _ = db.save_lyric_meaning(&track.title, &track.artist, &scope, LANGUAGE, &signed(&model, &text));
    }
    Reading::Answered { text, model }
}

fn failed(failure: ModelFailure, server: &str, model: &str) -> Reading {
    crate::logger::warn("meaning", &format!("no reading from {model} at {server}: {failure:?}"));
    Reading::Failed {
        failure,
        reader: Reader {
            server: server.to_string(),
            model: model.to_string(),
        },
    }
}

/// A stored reading keeps the model that wrote it on its first line, so the
/// attribution under it stays true after the person switches models.
const SIGNATURE: &str = "model:";

fn signed(model: &str, text: &str) -> String {
    format!("{SIGNATURE}{model}\n{text}")
}

fn split_signed(body: &str) -> (String, String) {
    match body.strip_prefix(SIGNATURE).and_then(|rest| rest.split_once('\n')) {
        Some((model, text)) => (model.to_string(), text.to_string()),
        None => (String::new(), body.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("flaccy-meaning-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn track() -> Track {
        Track {
            id: 1,
            rel_path: "a.flac".to_string(),
            title: "Breed".to_string(),
            artist: "Nirvana".to_string(),
            album: "Nevermind".to_string(),
            album_artist: None,
            track_number: 4,
            duration: 183.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
            disc_number: None,
        }
    }

    #[test]
    fn a_stored_reading_keeps_the_model_that_wrote_it() {
        assert_eq!(split_signed(&signed("bolt", "Line one\nLine two")), ("bolt".to_string(), "Line one\nLine two".to_string()));
        assert_eq!(split_signed("unsigned"), (String::new(), "unsigned".to_string()));
    }

    #[test]
    fn a_stored_reading_answers_without_asking_any_server() {
        let dir = scratch_dir("stored");
        let db_path = dir.join("library.sqlite");
        let db = Db::open(&db_path).unwrap();
        let focus = Focus {
            line: "I don't care".to_string(),
            before: Vec::new(),
            after: Vec::new(),
        };
        db.save_lyric_meaning("Breed", "Nirvana", &line_scope("I DON'T  care"), LANGUAGE, &signed("bolt", "Apathy."))
            .unwrap();
        let reading = reading(&db_path, &track(), &Document::default(), Some(&focus), None, "http://127.0.0.1:9", "", &|_| {});
        assert_eq!(
            reading,
            Reading::Answered {
                text: "Apathy.".to_string(),
                model: "bolt".to_string()
            }
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn no_server_is_a_failure_that_names_where_it_looked() {
        let dir = scratch_dir("no-server");
        let db_path = dir.join("library.sqlite");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let server = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let reading = reading(&db_path, &track(), &Document::default(), None, None, &server, "", &|_| {});
        assert_eq!(
            reading,
            Reading::Failed {
                failure: ModelFailure::Unreachable,
                reader: Reader { server, model: String::new() }
            }
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_story_and_a_miss_are_remembered() {
        let dir = scratch_dir("story");
        let db_path = dir.join("library.sqlite");
        let db = Db::open(&db_path).unwrap();
        let story = SongStory {
            article: "Breed (song)".to_string(),
            url: "u".to_string(),
            language: "en".to_string(),
            lead: "A song.".to_string(),
            sections: Vec::new(),
        };
        db.save_lyric_meaning("Breed", "Nirvana", STORY_SCOPE, LANGUAGE, &serde_json::to_string(&story).unwrap())
            .unwrap();
        assert_eq!(super::story(&db_path, &track()), StoryOutcome::Found(story));
        let mut other = track();
        other.title = "Unknown".to_string();
        db.save_lyric_meaning("Unknown", "Nirvana", STORY_SCOPE, LANGUAGE, "").unwrap();
        assert_eq!(super::story(&db_path, &other), StoryOutcome::Missing);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_question_about_an_instrumental_break_is_not_asked() {
        let document = flaccy_shared::lyrics::parse_lrc("[00:01.00]Sing\n[00:30.00]Again");
        let interlude = document.lines.iter().position(|line| line.is_interlude()).unwrap();
        assert_eq!(focus_for(&document, Some(interlude)), None);
        assert_eq!(focus_for(&document, None), Some(None));
        assert!(matches!(focus_for(&document, Some(0)), Some(Some(_))));
    }
}
