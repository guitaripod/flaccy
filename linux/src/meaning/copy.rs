//! The words of the Meaning dialog. The Apple clients carry the same English
//! in `Features/LyricsMeaning/LyricsMeaningCopy.swift`, apart from where the
//! reading comes from: a model on this computer here, flaccy-api there.

use super::local_model::{ModelFailure, ANSWER_TIMEOUT};
use super::wikipedia::LookupFailure;

pub const TITLE: &str = "Meaning";
pub const BUTTON_TOOLTIP: &str = "What This Song Means";
pub const EXPLAIN_LINE: &str = "Explain This Line";
pub const LINE_HEADER: &str = "This Line";
pub const SONG_HEADER: &str = "About the Song";
pub const WIKIPEDIA_HEADER: &str = "From Wikipedia";
pub const READ_ON_WIKIPEDIA: &str = "Read on Wikipedia";
pub const READING: &str = "Reading the lyrics…";
pub const LOOKING_UP: &str = "Looking for the song on Wikipedia…";
pub const TRY_AGAIN: &str = "Try Again";
pub const NO_LYRICS: &str =
    "Couldn't explain this song because its lyrics aren't loaded. Wait for them to appear and try again.";

pub fn wikipedia_credit(article: &str) -> String {
    format!("From the Wikipedia article “{article}”, CC BY-SA 4.0.")
}

pub fn written_by(model: &str) -> String {
    format!("Written by {model} on this computer from the lyrics. It can be wrong.")
}

pub fn asking(model: &str) -> String {
    format!("Asking {model}…")
}

pub fn wikipedia_failure(failure: LookupFailure) -> String {
    match failure {
        LookupFailure::Unreachable => {
            "Couldn't reach Wikipedia. Check your connection and try again.".to_string()
        }
        LookupFailure::TimedOut => {
            "Wikipedia took too long to answer. Try again in a moment.".to_string()
        }
        LookupFailure::Server(code) => {
            format!("Wikipedia couldn't answer (HTTP {code}). Try again in a few minutes.")
        }
    }
}

/// What went wrong asking the local model, the cause and what to do next.
pub fn model_failure(failure: &ModelFailure, server: &str, model: &str) -> String {
    match failure {
        ModelFailure::Unreachable => format!(
            "Couldn't explain this because no model server answered at {server}. Start Ollama or another local model server, or set its address in Preferences › Lyrics, then try again."
        ),
        ModelFailure::NoModels => format!(
            "Couldn't explain this because the model server at {server} has no models. Add one (for example, ollama pull qwen3) and try again."
        ),
        ModelFailure::TimedOut => format!(
            "Couldn't explain this because {model} took longer than {} seconds to answer. Try again, or pick a smaller model in Preferences › Lyrics.",
            ANSWER_TIMEOUT.as_secs()
        ),
        ModelFailure::Refused(code) => format!(
            "Couldn't explain this because the model server refused the request for {model} (HTTP {code}). Check the model in Preferences › Lyrics and try again."
        ),
        ModelFailure::Unreadable => format!(
            "Couldn't explain this because {model}'s answer couldn't be read. Try again, or pick another model in Preferences › Lyrics."
        ),
    }
}
