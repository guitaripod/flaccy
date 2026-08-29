use crate::app::AppCore;
use gtk::glib;
use std::rc::Rc;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static LAST_LOOKUP: Mutex<Option<Instant>> = Mutex::new(None);
const MIN_INTERVAL: Duration = Duration::from_secs(6);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlatformLink {
    pub key: String,
    pub display_name: String,
    pub url: String,
}

/// What a song.link page resolves to, same shape as the Apple clients'
/// `SonglinkResult`: the universal URL plus every platform the page knows.
#[derive(Clone, Debug)]
pub struct SonglinkResult {
    pub page_url: String,
    pub links: Vec<PlatformLink>,
    pub title: String,
    pub artist: String,
}

/// Display names and ordering shared with `SonglinkService.knownPlatforms`.
const KNOWN_PLATFORMS: &[(&str, &str)] = &[
    ("spotify", "Spotify"),
    ("appleMusic", "Apple Music"),
    ("youtubeMusic", "YouTube Music"),
    ("youtube", "YouTube"),
    ("tidal", "Tidal"),
    ("amazonMusic", "Amazon Music"),
    ("deezer", "Deezer"),
    ("soundcloud", "SoundCloud"),
    ("pandora", "Pandora"),
    ("napster", "Napster"),
    ("audiomack", "Audiomack"),
    ("anghami", "Anghami"),
    ("boomplay", "Boomplay"),
    ("itunes", "iTunes"),
    ("yandex", "Yandex Music"),
    ("spinrilla", "Spinrilla"),
    ("audius", "Audius"),
    ("line", "LINE Music"),
];

/// Resolves a track or album off the main thread and hands the result back on
/// it. The callback receives `Err(message)` when nothing could be found.
pub fn lookup(
    core: &Rc<AppCore>,
    title: String,
    artist: String,
    album: bool,
    on_done: impl FnOnce(&Rc<AppCore>, Result<SonglinkResult, String>) + 'static,
) {
    let (tx, rx) = async_channel::bounded::<Result<SonglinkResult, String>>(1);
    std::thread::Builder::new()
        .name("flaccy-songlink".into())
        .spawn(move || {
            let _ = tx.send_blocking(lookup_blocking(&title, &artist, album));
        })
        .ok();
    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        let result = rx
            .recv()
            .await
            .unwrap_or(Err("lookup cancelled".to_string()));
        let Some(core) = weak.upgrade() else { return };
        match &result {
            Ok(found) => crate::logger::info(
                "songlink",
                &format!("{} — {} platform links", found.page_url, found.links.len()),
            ),
            Err(message) => crate::logger::warn("songlink", &format!("lookup failed: {message}")),
        }
        on_done(&core, result);
    });
}

/// Copies the universal link to the clipboard once it resolves.
pub fn copy_link(core: &Rc<AppCore>, title: String, artist: String, album: bool) {
    core.toast("Finding links…");
    lookup(
        core,
        title,
        artist,
        album,
        move |core, result| match result {
            Ok(found) => {
                copy_to_clipboard(&found.page_url);
                core.toast("Link copied");
            }
            Err(_) => core.toast(failure_message(album)),
        },
    );
}

pub fn failure_message(album: bool) -> &'static str {
    if album {
        "Couldn't find this album on streaming platforms"
    } else {
        "Couldn't find this track on streaming platforms"
    }
}

pub fn copy_to_clipboard(text: &str) {
    use gtk::prelude::*;
    if let Some(display) = gtk::gdk::Display::default() {
        display.clipboard().set_text(text);
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .user_agent("Mozilla/5.0 (compatible; Flaccy; +https://github.com/guitaripod/flaccy)")
        .build()
}

fn throttle() {
    let wait = {
        let Ok(mut guard) = LAST_LOOKUP.lock() else {
            return;
        };
        let wait = guard
            .map(|last| MIN_INTERVAL.saturating_sub(last.elapsed()))
            .unwrap_or(Duration::ZERO);
        *guard = Some(Instant::now() + wait);
        wait
    };
    if !wait.is_zero() {
        std::thread::sleep(wait);
    }
}

/// Odesli retired its public API (every call answers 401
/// `PUBLIC_API_ACCESS_DEPRECATED`), so the song.link page itself is the
/// source, exactly as in `SonglinkService.fetchSonglink`: an iTunes id maps
/// straight onto `song.link/i/<id>` / `album.link/i/<id>`, and the page embeds
/// its platform links as Next.js data. An unparseable page still yields the
/// universal link, which is valid on its own.
fn lookup_blocking(title: &str, artist: &str, album: bool) -> Result<SonglinkResult, String> {
    let id = itunes_seed_id(title, artist, album)?;
    let page_url = page_url(id, album);
    throttle();
    let response = agent().get(&page_url).call().map_err(|e| format!("{e}"))?;
    let html = response.into_string().map_err(|e| format!("{e}"))?;
    let parsed = parse_page(&html);
    Ok(SonglinkResult {
        page_url: parsed.page_url.unwrap_or(page_url),
        links: parsed.links,
        title: parsed.title.unwrap_or_else(|| title.to_string()),
        artist: parsed.artist.unwrap_or_else(|| artist.to_string()),
    })
}

fn page_url(id: u64, album: bool) -> String {
    if album {
        format!("https://album.link/i/{id}")
    } else {
        format!("https://song.link/i/{id}")
    }
}

#[derive(Default)]
struct ParsedPage {
    page_url: Option<String>,
    title: Option<String>,
    artist: Option<String>,
    links: Vec<PlatformLink>,
}

fn parse_page(html: &str) -> ParsedPage {
    const OPEN: &str = r#"<script id="__NEXT_DATA__" type="application/json">"#;
    let Some(start) = html.find(OPEN).map(|i| i + OPEN.len()) else {
        return ParsedPage::default();
    };
    let Some(end) = html[start..].find("</script>").map(|i| start + i) else {
        return ParsedPage::default();
    };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&html[start..end]) else {
        return ParsedPage::default();
    };
    let page_data = &json["props"]["pageProps"]["pageData"];
    let entity = &page_data["entityData"];
    let mut seen = std::collections::HashSet::new();
    let mut links = Vec::new();
    for section in page_data["sections"].as_array().into_iter().flatten() {
        for raw in section["links"].as_array().into_iter().flatten() {
            let (Some(platform), Some(url)) = (raw["platform"].as_str(), raw["url"].as_str())
            else {
                continue;
            };
            if !seen.insert(platform.to_string()) {
                continue;
            }
            links.push(PlatformLink {
                key: platform.to_string(),
                display_name: display_name(platform),
                url: url.to_string(),
            });
        }
    }
    links.sort_by_key(|link| platform_order(&link.key));
    ParsedPage {
        page_url: page_data["pageUrl"].as_str().map(String::from),
        title: entity["title"].as_str().map(String::from),
        artist: entity["artistName"].as_str().map(String::from),
        links,
    }
}

fn platform_order(key: &str) -> usize {
    KNOWN_PLATFORMS
        .iter()
        .position(|(k, _)| *k == key)
        .unwrap_or(100)
}

fn display_name(key: &str) -> String {
    if let Some((_, name)) = KNOWN_PLATFORMS.iter().find(|(k, _)| *k == key) {
        return (*name).to_string();
    }
    let mut out = String::new();
    for (i, c) in key.chars().enumerate() {
        if i == 0 {
            out.extend(c.to_uppercase());
        } else if c.is_uppercase() {
            out.push(' ');
            out.push(c);
        } else {
            out.push(c);
        }
    }
    out
}

/// iTunes Search stands in for MusicKit as the seed. The Apple clients match
/// on title ⊂ result and artist ⊂ result, then fall back to the first hit; the
/// same here, with one more pass when the joined query finds nothing — long
/// featured-artist strings and trailing ellipses defeat iTunes' term matcher,
/// so retry on the bare title and prefer a result naming any of the artists.
fn itunes_seed_id(title: &str, artist: &str, album: bool) -> Result<u64, String> {
    let entity = if album { "album" } else { "song" };
    let id_key = if album { "collectionId" } else { "trackId" };
    let name_key = if album { "collectionName" } else { "trackName" };
    let clean_title = clean_term(title);
    let clean_artist = clean_term(artist);
    let title_lower = clean_title.to_lowercase();
    let artist_tokens: Vec<String> = clean_artist
        .split(|c: char| c == '&' || c == ',' || c == '/' || c == ';')
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    let score = |entry: &serde_json::Value| -> u8 {
        let name = entry[name_key].as_str().unwrap_or("").to_lowercase();
        let by = entry["artistName"].as_str().unwrap_or("").to_lowercase();
        let name_exact = clean_term(&name) == title_lower;
        let name_ok = name_exact || name.contains(&title_lower);
        let artist_ok = artist_tokens.iter().any(|t| by.contains(t.as_str()));
        match (name_exact, name_ok, artist_ok) {
            (true, _, true) => 4,
            (false, true, true) => 3,
            (true, _, false) => 2,
            (false, true, false) => 1,
            _ => 0,
        }
    };
    let queries = [format!("{clean_artist} {clean_title}"), clean_title.clone()];
    for (pass, term) in queries.iter().enumerate() {
        let results = itunes_search(term, entity)?;
        let best = results
            .iter()
            .map(|e| (score(e), e))
            .filter(|(s, _)| *s > 0 || pass == 0)
            .max_by(|a, b| a.0.cmp(&b.0))
            .map(|(_, e)| e);
        if let Some(id) = best.and_then(|e| e[id_key].as_u64()) {
            return Ok(id);
        }
    }
    Err(format!("no iTunes match for {artist} — {title}"))
}

fn itunes_search(term: &str, entity: &str) -> Result<Vec<serde_json::Value>, String> {
    let url = format!(
        "https://itunes.apple.com/search?term={}&entity={entity}&limit=10",
        url_encode(term)
    );
    let response = agent().get(&url).call().map_err(|e| format!("{e}"))?;
    let text = response.into_string().map_err(|e| format!("{e}"))?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("{e}"))?;
    Ok(json["results"].as_array().cloned().unwrap_or_default())
}

/// Strips the decorations iTunes' matcher chokes on: trailing ellipses and
/// bracketed edition tags, plus feat. credits inside the artist string.
fn clean_term(input: &str) -> String {
    let mut s = input.trim().trim_end_matches(['.', '…']).trim().to_string();
    for open in ['(', '['] {
        if let Some(i) = s.find(open) {
            let tail = s[i..].to_lowercase();
            if tail.contains("feat") || tail.contains("remaster") || tail.contains("version") {
                s.truncate(i);
            }
        }
    }
    s.trim().to_string()
}

fn url_encode(input: &str) -> String {
    let mut result = String::new();
    for byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(*byte as char)
            }
            _ => result.push_str(&format!("%{:02X}", byte)),
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = r#"<html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"pageData":{"pageUrl":"https://song.link/i/1","entityData":{"title":"Song","artistName":"Band"},"sections":[{"links":[{"platform":"tidal","url":"https://t/1"},{"platform":"spotify","url":null},{"platform":"appleMusic","url":"https://a/1"}]},{"links":[{"platform":"tidal","url":"https://t/dup"},{"platform":"weirdShop","url":"https://w/1"}]}]}}}}</script></html>"#;

    #[test]
    fn parses_next_data_links_in_platform_order() {
        let parsed = parse_page(PAGE);
        assert_eq!(parsed.page_url.as_deref(), Some("https://song.link/i/1"));
        assert_eq!(parsed.title.as_deref(), Some("Song"));
        assert_eq!(parsed.artist.as_deref(), Some("Band"));
        let keys: Vec<&str> = parsed.links.iter().map(|l| l.key.as_str()).collect();
        assert_eq!(keys, ["appleMusic", "tidal", "weirdShop"]);
        assert_eq!(parsed.links[1].url, "https://t/1");
        assert_eq!(parsed.links[2].display_name, "Weird Shop");
    }

    #[test]
    fn unparseable_page_is_empty_not_an_error() {
        let parsed = parse_page("<html></html>");
        assert!(parsed.links.is_empty());
        assert!(parsed.page_url.is_none());
    }

    #[test]
    fn page_urls_follow_the_itunes_id() {
        assert_eq!(page_url(389080531, false), "https://song.link/i/389080531");
        assert_eq!(page_url(389079814, true), "https://album.link/i/389079814");
    }

    #[test]
    fn cleans_terms_itunes_cannot_match() {
        assert_eq!(clean_term("Silver For Monsters..."), "Silver For Monsters");
        assert_eq!(clean_term("Lithium (Remastered 2021)"), "Lithium");
        assert_eq!(clean_term("Hello (feat. X)"), "Hello");
        assert_eq!(
            clean_term("Live at Wembley (Disc 1)"),
            "Live at Wembley (Disc 1)"
        );
    }
}
