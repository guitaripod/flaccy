use std::time::Duration;

/// Where Ollama listens unless `OLLAMA_HOST` or Preferences say otherwise.
pub const DEFAULT_SERVER: &str = "http://127.0.0.1:11434";
const PROBE_TIMEOUT: Duration = Duration::from_secs(4);
/// A model server may have to load the model first, which on a big one takes
/// most of a minute before the first word.
pub const ANSWER_TIMEOUT: Duration = Duration::from_secs(180);
/// Room for a reasoning model that thinks anyway before it writes the answer
/// asked for: Gemma 4 26B spent 1,500 tokens thinking about one line and
/// wrote nothing.
const MAX_TOKENS: u32 = 4_000;
const TEMPERATURE: f64 = 0.3;
/// Instruct models that read lyrics well, best first, matched as substrings of
/// a model's id when the person has not picked one.
const PREFERRED_MODELS: [&str; 6] = ["qwen3", "gemma", "llama3", "mistral", "phi", "qwen"];

/// How llama-swap marks a model in memory in its `/v1/models` list.
const LOADED_STATES: [&str; 2] = ["loaded", "ready"];

/// One model a server offers, and whether it is already in memory when the
/// server says (llama-swap does; Ollama does not).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    pub id: String,
    pub loaded: Option<bool>,
}

/// Why the local model gave no reading.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ModelFailure {
    Unreachable,
    NoModels,
    TimedOut,
    Refused(u16),
    Unreadable,
}

/// The OpenAI-compatible server to ask: the address set in Preferences, else
/// `OLLAMA_HOST`, else Ollama's own default. Ollama, llama-swap, llama.cpp's
/// server and LM Studio all answer the same `/v1` paths.
pub fn server_url(configured: &str) -> String {
    let chosen = if configured.trim().is_empty() {
        std::env::var("OLLAMA_HOST").unwrap_or_default()
    } else {
        configured.to_string()
    };
    normalize(&chosen).unwrap_or_else(|| DEFAULT_SERVER.to_string())
}

/// An address as typed, with a scheme, without a trailing slash or `/v1`.
pub fn normalize(address: &str) -> Option<String> {
    let trimmed = address.trim().trim_end_matches('/');
    let trimmed = trimmed.strip_suffix("/v1").unwrap_or(trimmed).trim_end_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        Some(trimmed.to_string())
    } else {
        Some(format!("http://{trimmed}"))
    }
}

/// The models the server offers.
pub fn models(server: &str) -> Result<Vec<Model>, ModelFailure> {
    let response = ureq::get(&format!("{server}/v1/models"))
        .timeout(PROBE_TIMEOUT)
        .call()
        .map_err(|error| failure_of(&error))?;
    let value: serde_json::Value = response.into_json().map_err(|_| ModelFailure::Unreadable)?;
    Ok(models_of(&value))
}

fn models_of(value: &serde_json::Value) -> Vec<Model> {
    value
        .get("data")
        .and_then(|data| data.as_array())
        .map(|data| {
            data.iter()
                .filter_map(|entry| {
                    let id = entry.get("id")?.as_str()?.to_string();
                    let loaded = entry
                        .pointer("/status/value")
                        .and_then(|status| status.as_str())
                        .map(|status| LOADED_STATES.contains(&status));
                    Some(Model { id, loaded })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The model to ask: the person's pick when the server has it, else one the
/// server already holds in memory (so a request never evicts what another
/// program is using), else the first instruct model recognised, else the
/// first offered.
pub fn choose(preferred: &str, models: &[Model]) -> Option<String> {
    let wanted = preferred.trim();
    if !wanted.is_empty() {
        if let Some(model) = models.iter().find(|model| model.id == wanted) {
            return Some(model.id.clone());
        }
    }
    if let Some(model) = models.iter().find(|model| model.loaded == Some(true)) {
        return Some(model.id.clone());
    }
    PREFERRED_MODELS
        .iter()
        .find_map(|family| {
            models
                .iter()
                .find(|model| model.id.to_lowercase().contains(family))
        })
        .or_else(|| models.first())
        .map(|model| model.id.clone())
}

/// Asks `model` the question and returns what it wrote. Thinking is turned
/// off where the server's chat template allows it (llama.cpp, vLLM and SGLang
/// read `chat_template_kwargs`; Ollama ignores it): on llama-swap's Gemma 4
/// 26B it took a line's answer from 71 s and no text to 5 s.
pub fn chat(server: &str, model: &str, system: &str, user: &str) -> Result<String, ModelFailure> {
    let body = serde_json::json!({
        "model": model,
        "stream": false,
        "temperature": TEMPERATURE,
        "max_tokens": MAX_TOKENS,
        "response_format": { "type": "json_object" },
        "chat_template_kwargs": { "enable_thinking": false },
        "messages": [
            { "role": "system", "content": system },
            { "role": "user", "content": user }
        ]
    });
    let response = ureq::post(&format!("{server}/v1/chat/completions"))
        .timeout(ANSWER_TIMEOUT)
        .send_json(body)
        .map_err(|error| failure_of(&error))?;
    let value: serde_json::Value = response.into_json().map_err(|_| ModelFailure::Unreadable)?;
    value
        .pointer("/choices/0/message/content")
        .and_then(|content| content.as_str())
        .map(str::to_string)
        .ok_or(ModelFailure::Unreadable)
}

fn failure_of(error: &ureq::Error) -> ModelFailure {
    match error {
        ureq::Error::Status(code, _) => ModelFailure::Refused(*code),
        ureq::Error::Transport(transport) => {
            if transport.to_string().to_lowercase().contains("timed out") {
                ModelFailure::TimedOut
            } else {
                ModelFailure::Unreachable
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(id: &str, loaded: Option<bool>) -> Model {
        Model {
            id: id.to_string(),
            loaded,
        }
    }

    #[test]
    fn an_address_gains_a_scheme_and_loses_its_v1_and_slashes() {
        assert_eq!(normalize("127.0.0.1:8081/v1/").as_deref(), Some("http://127.0.0.1:8081"));
        assert_eq!(normalize("https://box.local/").as_deref(), Some("https://box.local"));
        assert_eq!(normalize("   "), None);
        assert_eq!(server_url("localhost:1234"), "http://localhost:1234");
    }

    #[test]
    fn the_models_list_reads_llama_swap_and_ollama_shapes() {
        let swap = serde_json::json!({ "data": [
            { "id": "bolt", "status": { "value": "loaded" } },
            { "id": "flint", "status": { "value": "unloaded" } },
            { "id": "groot", "status": { "value": "ready" } }
        ]});
        assert_eq!(
            models_of(&swap),
            vec![model("bolt", Some(true)), model("flint", Some(false)), model("groot", Some(true))]
        );
        let ollama = serde_json::json!({ "object": "list", "data": [{ "id": "qwen3:8b", "object": "model" }] });
        assert_eq!(models_of(&ollama), vec![model("qwen3:8b", None)]);
        assert!(models_of(&serde_json::json!({})).is_empty());
    }

    #[test]
    fn the_persons_pick_wins_then_a_loaded_model_then_a_known_family() {
        let offered = [model("flint", Some(false)), model("gemma3:4b", Some(false)), model("bolt", Some(true))];
        assert_eq!(choose("flint", &offered).as_deref(), Some("flint"));
        assert_eq!(choose("", &offered).as_deref(), Some("bolt"));
        assert_eq!(choose("gone", &offered).as_deref(), Some("bolt"));
        let cold = [model("flint", None), model("gemma3:4b", None)];
        assert_eq!(choose("", &cold).as_deref(), Some("gemma3:4b"));
        assert_eq!(choose("", &[model("x", None)]).as_deref(), Some("x"));
        assert_eq!(choose("", &[]), None);
    }
}
