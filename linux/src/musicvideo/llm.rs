use super::Candidate;
use std::time::Duration;

/// A local model is a tie-breaker, not a bottleneck: if it hasn't answered by
/// now the deterministic ranking stands.
const CHAT_TIMEOUT: Duration = Duration::from_secs(45);
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Small instruct models handle this well and answer in a few seconds; the
/// larger the model, the longer the video lens sits on a spinner. Sorted best
/// first, matched as substrings against installed tags.
const PREFERRED_MODELS: [&str; 6] = ["qwen3", "llama3.2", "gemma", "mistral", "phi", "llama3"];

/// How the model's opinion is weighed against the scorer's. The scorer knows
/// runtimes and channel identity; the model reads the wording. Neither alone
/// is right often enough.
const MODEL_WEIGHT: f64 = 0.45;

pub struct Verdict {
    pub index: Option<usize>,
    pub confidence: f64,
    pub reason: String,
}

pub fn host() -> String {
    let raw = std::env::var("OLLAMA_HOST").unwrap_or_default();
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return "http://127.0.0.1:11434".to_string();
    }
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("http://{trimmed}")
    }
}

/// Lists installed models, newest-usable first. An empty result means either
/// no Ollama or no models — both mean "decide without a model", so the caller
/// never has to tell them apart.
pub fn installed_models() -> Vec<String> {
    let response = ureq::get(&format!("{}/api/tags", host()))
        .timeout(PROBE_TIMEOUT)
        .call();
    let Ok(response) = response else { return Vec::new() };
    let Ok(value) = response.into_json::<serde_json::Value>() else {
        return Vec::new();
    };
    value
        .get("models")
        .and_then(|m| m.as_array())
        .map(|models| {
            models
                .iter()
                .filter_map(|model| model.get("name")?.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Picks the model to adjudicate with: the user's choice when it is actually
/// installed, otherwise the first small instruct model we recognise, otherwise
/// whatever is there.
pub fn choose_model(preferred: &str, installed: &[String]) -> Option<String> {
    if installed.is_empty() {
        return None;
    }
    let wanted = preferred.trim();
    if !wanted.is_empty() {
        if let Some(exact) = installed.iter().find(|name| name.as_str() == wanted) {
            return Some(exact.clone());
        }
        if let Some(prefix) = installed
            .iter()
            .find(|name| name.split(':').next() == Some(wanted))
        {
            return Some(prefix.clone());
        }
    }
    for family in PREFERRED_MODELS {
        if let Some(found) = installed
            .iter()
            .find(|name| name.to_lowercase().contains(family))
        {
            return Some(found.clone());
        }
    }
    installed.first().cloned()
}

/// Asks the local model which candidate is the song's actual music video.
/// Returns `None` whenever Ollama is unreachable, slow, or answers with
/// something that isn't a usable verdict — every one of which means "fall back
/// to the deterministic ranking".
pub fn adjudicate(
    model: &str,
    title: &str,
    artist: &str,
    duration: f64,
    candidates: &[&Candidate],
) -> Option<Verdict> {
    if candidates.is_empty() {
        return None;
    }
    let body = serde_json::json!({
        "model": model,
        "stream": false,
        "think": false,
        "format": verdict_schema(),
        "options": { "temperature": 0, "num_predict": 220 },
        "messages": [
            { "role": "system", "content": SYSTEM_PROMPT },
            { "role": "user", "content": prompt(title, artist, duration, candidates) }
        ]
    });
    let response = ureq::post(&format!("{}/api/chat", host()))
        .timeout(CHAT_TIMEOUT)
        .send_json(body)
        .ok()?;
    let value: serde_json::Value = response.into_json().ok()?;
    let content = value.get("message")?.get("content")?.as_str()?;
    parse_verdict(content, candidates.len())
}

const SYSTEM_PROMPT: &str = "You identify official music videos on YouTube. \
You answer only with the requested JSON object. A music video is a filmed \
performance or narrative made for the song. A lyric video, a visualizer, a \
static-artwork audio upload, a live concert recording, a cover, a remix, a \
reaction, a fan edit and a sped-up or slowed edit are NOT music videos. \
Judge the uploader by the evidence in front of you: a channel whose name \
merely resembles the artist's is a re-upload, and re-uploads draw far fewer \
views than the real thing. A music video is often a minute shorter or longer \
than the album track, so a runtime that matches exactly is not evidence.";

fn prompt(title: &str, artist: &str, duration: f64, candidates: &[&Candidate]) -> String {
    let mut lines = format!(
        "Song: \"{title}\"\nArtist: {artist}\nRuntime: {:.0} seconds\n\nCandidates:\n",
        duration
    );
    for (index, candidate) in candidates.iter().enumerate() {
        let views = match candidate.view_count {
            Some(views) => views.to_string(),
            None => "unknown".to_string(),
        };
        lines.push_str(&format!(
            "{index}) title={:?} channel={:?} runtime={:.0}s views={views}\n",
            candidate.title, candidate.channel, candidate.duration
        ));
    }
    lines.push_str(
        "\nWhich candidate is this song's official music video? Answer with its \
index, your confidence from 0 to 1, and one short sentence of reasoning. If none \
of them is a music video for this exact song, answer with index -1.",
    );
    lines
}

fn verdict_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            "index": { "type": "integer" },
            "confidence": { "type": "number" },
            "reason": { "type": "string" }
        },
        "required": ["index", "confidence", "reason"]
    })
}

/// Reads the model's JSON, tolerating the fenced or prose-wrapped output a
/// model occasionally emits despite the schema.
pub fn parse_verdict(content: &str, candidate_count: usize) -> Option<Verdict> {
    let json = extract_object(content)?;
    let value: serde_json::Value = serde_json::from_str(&json).ok()?;
    let raw_index = value.get("index").and_then(|v| v.as_i64())?;
    let index = if raw_index < 0 {
        None
    } else {
        let index = raw_index as usize;
        if index >= candidate_count {
            return None;
        }
        Some(index)
    };
    let confidence = value
        .get("confidence")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.5)
        .clamp(0.0, 1.0);
    let reason = value
        .get("reason")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_string();
    Some(Verdict {
        index,
        confidence,
        reason,
    })
}

fn extract_object(content: &str) -> Option<String> {
    let start = content.find('{')?;
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    for (offset, ch) in content[start..].char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        match ch {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(content[start..start + offset + ch.len_utf8()].to_string());
                }
            }
            _ => {}
        }
    }
    None
}

/// Folds a verdict into the deterministic scores: the chosen candidate is
/// pulled toward the model's confidence, everything else away from it. The
/// scorer's own ranking survives a lukewarm opinion, which is what keeps a
/// small model from confidently promoting a lyric video.
pub fn blend(scores: &[f64], verdict: &Verdict) -> Vec<f64> {
    let weight = MODEL_WEIGHT * verdict.confidence;
    scores
        .iter()
        .enumerate()
        .map(|(index, score)| {
            let target = if verdict.index == Some(index) { 1.0 } else { 0.0 };
            score * (1.0 - weight) + target * weight
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verdict(index: Option<usize>, confidence: f64) -> Verdict {
        Verdict {
            index,
            confidence,
            reason: String::new(),
        }
    }

    #[test]
    fn parses_a_plain_verdict() {
        let parsed = parse_verdict(r#"{"index":0,"confidence":0.98,"reason":"official"}"#, 3).unwrap();
        assert_eq!(parsed.index, Some(0));
        assert!((parsed.confidence - 0.98).abs() < 1e-9);
        assert_eq!(parsed.reason, "official");
    }

    #[test]
    fn parses_a_fenced_verdict_with_prose_around_it() {
        let parsed = parse_verdict(
            "Here you go:\n```json\n{\"index\": 1, \"confidence\": 0.7, \"reason\": \"a } brace\"}\n```\nDone.",
            3,
        )
        .unwrap();
        assert_eq!(parsed.index, Some(1));
        assert_eq!(parsed.reason, "a } brace");
    }

    #[test]
    fn a_negative_index_means_none_of_them() {
        let parsed = parse_verdict(r#"{"index":-1,"confidence":0.9,"reason":"all lyric videos"}"#, 4)
            .unwrap();
        assert_eq!(parsed.index, None);
    }

    #[test]
    fn an_out_of_range_index_is_rejected() {
        assert!(parse_verdict(r#"{"index":9,"confidence":1,"reason":"x"}"#, 3).is_none());
        assert!(parse_verdict("no json here", 3).is_none());
        assert!(parse_verdict(r#"{"confidence":1}"#, 3).is_none());
    }

    #[test]
    fn confidence_is_clamped() {
        let parsed = parse_verdict(r#"{"index":0,"confidence":7,"reason":""}"#, 1).unwrap();
        assert_eq!(parsed.confidence, 1.0);
    }

    #[test]
    fn a_confident_verdict_reorders_a_close_race() {
        let blended = blend(&[0.70, 0.66], &verdict(Some(1), 1.0));
        assert!(blended[1] > blended[0]);
    }

    #[test]
    fn a_hesitant_verdict_leaves_the_ranking_alone() {
        let blended = blend(&[0.80, 0.40], &verdict(Some(1), 0.2));
        assert!(blended[0] > blended[1]);
    }

    #[test]
    fn rejecting_every_candidate_pushes_them_all_down() {
        let blended = blend(&[0.70, 0.66], &verdict(None, 1.0));
        assert!(blended.iter().all(|score| *score < 0.45));
    }

    #[test]
    fn prefers_the_configured_model_then_a_known_family() {
        let installed = vec!["gemma4:latest".to_string(), "qwen3.8:4b-q8_0".to_string()];
        assert_eq!(
            choose_model("qwen3.8:4b-q8_0", &installed).as_deref(),
            Some("qwen3.8:4b-q8_0")
        );
        assert_eq!(choose_model("qwen3.8", &installed).as_deref(), Some("qwen3.8:4b-q8_0"));
        assert_eq!(choose_model("", &installed).as_deref(), Some("qwen3.8:4b-q8_0"));
        assert_eq!(choose_model("missing", &installed).as_deref(), Some("qwen3.8:4b-q8_0"));
        assert_eq!(choose_model("", &[]), None);
        assert_eq!(
            choose_model("", &["something-exotic:1b".to_string()]).as_deref(),
            Some("something-exotic:1b")
        );
    }

    #[test]
    fn host_falls_back_and_gains_a_scheme() {
        assert!(host().starts_with("http"));
    }
}
