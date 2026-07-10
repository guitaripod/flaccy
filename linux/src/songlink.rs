use crate::app::AppCore;
use gtk::glib;
use gtk::prelude::*;
use std::rc::Rc;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static LAST_LOOKUP: Mutex<Option<Instant>> = Mutex::new(None);
const MIN_INTERVAL: Duration = Duration::from_secs(6);

/// Resolves a track or album to a song.link universal URL (seeded via iTunes
/// Search, since Odesli needs a platform URL) and copies it to the clipboard.
pub fn copy_link(core: &Rc<AppCore>, title: String, artist: String, album: bool) {
    let (tx, rx) = async_channel::bounded::<Result<String, String>>(1);
    std::thread::Builder::new()
        .name("flaccy-songlink".into())
        .spawn(move || {
            let _ = tx.send_blocking(lookup_blocking(&title, &artist, album));
        })
        .ok();

    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        let result = rx.recv().await.unwrap_or(Err("lookup cancelled".to_string()));
        let Some(core) = weak.upgrade() else { return };
        match result {
            Ok(url) => {
                if let Some(display) = gtk::gdk::Display::default() {
                    display.clipboard().set_text(&url);
                }
                crate::logger::info("songlink", &format!("copied {url}"));
                core.toast("song.link copied to clipboard");
            }
            Err(message) => {
                crate::logger::warn("songlink", &format!("lookup failed: {message}"));
                core.toast("Couldn't find a song.link for this");
            }
        }
    });
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .user_agent("flaccy/1.0 (https://github.com/guitaripod/flaccy)")
        .build()
}

fn throttle() {
    let wait = {
        let Ok(mut guard) = LAST_LOOKUP.lock() else { return };
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

fn lookup_blocking(title: &str, artist: &str, album: bool) -> Result<String, String> {
    let seed = itunes_seed_url(title, artist, album)?;
    throttle();
    let url = format!(
        "https://api.song.link/v1-alpha.1/links?url={}&userCountry=US&songIfSingle=true",
        url_encode(&seed)
    );
    let response = agent().get(&url).call().map_err(|e| format!("{e}"))?;
    let text = response.into_string().map_err(|e| format!("{e}"))?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("{e}"))?;
    json["pageUrl"]
        .as_str()
        .map(String::from)
        .ok_or_else(|| "no pageUrl in song.link response".to_string())
}

fn itunes_seed_url(title: &str, artist: &str, album: bool) -> Result<String, String> {
    let entity = if album { "album" } else { "song" };
    let term = if album {
        format!("{artist} {title}")
    } else {
        format!("{artist} {title}")
    };
    let url = format!(
        "https://itunes.apple.com/search?term={}&entity={entity}&limit=5",
        url_encode(&term)
    );
    let response = agent().get(&url).call().map_err(|e| format!("{e}"))?;
    let text = response.into_string().map_err(|e| format!("{e}"))?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("{e}"))?;
    let results = json["results"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let key = if album { "collectionViewUrl" } else { "trackViewUrl" };
    let name_key = if album { "collectionName" } else { "trackName" };
    let title_lower = title.to_lowercase();
    let artist_lower = artist.to_lowercase();
    let best = results
        .iter()
        .find(|entry| {
            entry[name_key]
                .as_str()
                .map(|n| n.to_lowercase().contains(&title_lower))
                .unwrap_or(false)
                && entry["artistName"]
                    .as_str()
                    .map(|a| a.to_lowercase().contains(&artist_lower))
                    .unwrap_or(false)
        })
        .or_else(|| results.first());
    best.and_then(|entry| entry[key].as_str())
        .map(String::from)
        .ok_or_else(|| format!("no iTunes match for {artist} — {title}"))
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
