use flaccy_shared::meaning::{pick_article, search_terms, story, ArticleCandidate, SongStory, SEARCH_LIMIT};
use std::time::Duration;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// Why Wikipedia gave no answer, as opposed to answering that it has no
/// article about the song.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LookupFailure {
    Unreachable,
    TimedOut,
    Server(u16),
}

/// English Wikipedia, or the stand-in `FLACCY_WIKIPEDIA_URL` names.
fn base() -> String {
    std::env::var("FLACCY_WIKIPEDIA_URL")
        .ok()
        .map(|url| url.trim().trim_end_matches('/').to_string())
        .filter(|url| !url.is_empty())
        .unwrap_or_else(|| "https://en.wikipedia.org".to_string())
}

fn user_agent() -> String {
    format!(
        "flaccy/{} (https://github.com/guitaripod/flaccy)",
        env!("CARGO_PKG_VERSION")
    )
}

/// The song's own article and the parts of it about its meaning, `None` when
/// Wikipedia has no article about the song.
pub fn lookup(title: &str, artist: &str) -> Result<Option<SongStory>, LookupFailure> {
    lookup_at(&base(), title, artist)
}

fn lookup_at(base: &str, title: &str, artist: &str) -> Result<Option<SongStory>, LookupFailure> {
    let agent = ureq::AgentBuilder::new().timeout(REQUEST_TIMEOUT).build();
    let search = get_json(
        &agent,
        base,
        &[
            ("generator", "search"),
            ("gsrsearch", &search_terms(title, artist)),
            ("gsrlimit", &SEARCH_LIMIT.to_string()),
            ("gsrnamespace", "0"),
            ("prop", "description"),
        ],
    )?;
    let candidates = candidates_of(&search);
    let Some(index) = pick_article(&candidates, title, artist) else {
        return Ok(None);
    };
    let article = &candidates[index].title;
    let page = get_json(
        &agent,
        base,
        &[
            ("prop", "extracts|info"),
            ("inprop", "url"),
            ("explaintext", "1"),
            ("exsectionformat", "wiki"),
            ("redirects", "1"),
            ("titles", article),
        ],
    )?;
    let Some(page) = page.pointer("/query/pages/0") else {
        return Ok(None);
    };
    let extract = page.get("extract").and_then(|value| value.as_str()).unwrap_or("");
    let resolved = page.get("title").and_then(|value| value.as_str()).unwrap_or(article);
    let url = page
        .get("fullurl")
        .and_then(|value| value.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| format!("{base}/wiki/{}", resolved.replace(' ', "_")));
    Ok(story(resolved, &url, "en", extract, true))
}

/// Search results in Wikipedia's own ranking.
fn candidates_of(search: &serde_json::Value) -> Vec<ArticleCandidate> {
    let mut pages: Vec<(i64, ArticleCandidate)> = search
        .pointer("/query/pages")
        .and_then(|pages| pages.as_array())
        .map(|pages| {
            pages
                .iter()
                .filter_map(|page| {
                    let title = page.get("title")?.as_str()?.to_string();
                    let description = page
                        .get("description")
                        .and_then(|value| value.as_str())
                        .unwrap_or("")
                        .to_string();
                    let rank = page.get("index").and_then(|value| value.as_i64()).unwrap_or(i64::MAX);
                    Some((rank, ArticleCandidate { title, description }))
                })
                .collect()
        })
        .unwrap_or_default();
    pages.sort_by_key(|(rank, _)| *rank);
    pages.into_iter().map(|(_, candidate)| candidate).collect()
}

fn get_json(
    agent: &ureq::Agent,
    base: &str,
    params: &[(&str, &str)],
) -> Result<serde_json::Value, LookupFailure> {
    let mut request = agent
        .get(&format!("{base}/w/api.php"))
        .set("User-Agent", &user_agent())
        .query("action", "query")
        .query("format", "json")
        .query("formatversion", "2");
    for (key, value) in params {
        request = request.query(key, value);
    }
    match request.call() {
        Ok(response) => response.into_json().map_err(|_| LookupFailure::Unreachable),
        Err(ureq::Error::Status(code, _)) => Err(LookupFailure::Server(code)),
        Err(ureq::Error::Transport(transport)) => {
            crate::logger::warn("meaning", &format!("Wikipedia request failed: {transport}"));
            if transport.to_string().to_lowercase().contains("timed out") {
                Err(LookupFailure::TimedOut)
            } else {
                Err(LookupFailure::Unreachable)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};

    /// A stand-in Wikipedia answering the search, then the article.
    fn stub(answers: Vec<String>) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for (mut stream, body) in listener.incoming().flatten().zip(answers) {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                }
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(reply.as_bytes());
            }
        });
        base
    }

    #[test]
    fn the_songs_article_is_found_and_read_into_a_story() {
        let search = serde_json::json!({ "query": { "pages": [
            { "title": "Nevermind", "index": 1, "description": "1991 studio album by Nirvana" },
            { "title": "Breed (song)", "index": 2, "description": "1991 song by Nirvana" }
        ]}})
        .to_string();
        let page = serde_json::json!({ "query": { "pages": [{
            "title": "Breed (song)",
            "fullurl": "https://en.wikipedia.org/wiki/Breed_(song)",
            "extract": "\"Breed\" is a song by Nirvana.\n\n\n== Lyrics ==\nThe lyrics mock conformity.\n"
        }]}})
        .to_string();
        let base = stub(vec![search, page]);
        let story = lookup_at(&base, "Breed (Remastered)", "Nirvana")
            .expect("an answer")
            .expect("a story");
        assert_eq!(story.article, "Breed (song)");
        assert_eq!(story.url, "https://en.wikipedia.org/wiki/Breed_(song)");
        assert_eq!(story.lead, "\"Breed\" is a song by Nirvana.");
        assert_eq!(story.sections[0].heading, "Lyrics");
    }

    #[test]
    fn no_matching_article_is_an_answer_not_a_failure() {
        let search = serde_json::json!({ "query": { "pages": [
            { "title": "Breed", "index": 1, "description": "group of animals" }
        ]}})
        .to_string();
        let base = stub(vec![search]);
        assert_eq!(lookup_at(&base, "Breed", "Nirvana"), Ok(None));
        let empty = stub(vec!["{\"batchcomplete\": true}".to_string()]);
        assert_eq!(lookup_at(&empty, "Breed", "Nirvana"), Ok(None));
    }

    #[test]
    fn a_closed_port_is_unreachable() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        assert_eq!(lookup_at(&base, "Breed", "Nirvana"), Err(LookupFailure::Unreachable));
    }
}
