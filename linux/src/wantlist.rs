use crate::app::AppCore;
use crate::db::{Db, NewReleaseRow, WantlistItemRow};
use crate::events::AppEvent;
use crate::library::{Album, Track};
use gtk::glib;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

const MISSING_ALBUM_LIMIT: usize = 18;
const MISSING_TRACK_LIMIT: usize = 20;
const DISCOVER_ARTIST_LIMIT: usize = 10;
const DISCOVER_ALBUM_LIMIT: usize = 9;
const SEED_ARTIST_COUNT: usize = 6;
const RELEASE_TTL_SECONDS: i64 = 7 * 24 * 3600;
const RELEASE_WINDOW_SECONDS: i64 = 120 * 24 * 3600;
const RELEASE_ARTIST_LIMIT: usize = 15;
const ITUNES_THROTTLE: Duration = Duration::from_secs(3);

pub const EDITION_KEYWORDS: [&str; 25] = [
    "deluxe", "edition", "remaster", "bonus", "expanded", "anniversary", "special", "extended",
    "complete", "reissue", "version", "collector", "platinum", "legacy", "super", "tour", "feat",
    "ft.", "with", "explicit", "clean", "mono", "stereo", "single", "ep",
];

/// Strips diacritics and every non-alphanumeric character, lowercased —
/// the iOS WantlistOwnership.normalize.
pub fn normalize(value: &str) -> String {
    value
        .chars()
        .flat_map(fold_diacritic)
        .filter(|c| c.is_alphanumeric())
        .flat_map(|c| c.to_lowercase())
        .collect()
}

/// ASCII-folds the Latin-1/Latin Extended diacritics that occur in practice in
/// music metadata; other scripts pass through untouched.
fn fold_diacritic(c: char) -> Vec<char> {
    let folded: &str = match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Å' | 'Ā' => "A",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
        'È' | 'É' | 'Ê' | 'Ë' | 'Ē' => "E",
        'ì' | 'í' | 'î' | 'ï' | 'ī' | 'į' | 'ı' => "i",
        'Ì' | 'Í' | 'Î' | 'Ï' => "I",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' => "o",
        'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ö' | 'Ø' => "O",
        'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' => "u",
        'Ù' | 'Ú' | 'Û' | 'Ü' => "U",
        'ý' | 'ÿ' => "y",
        'ñ' | 'ń' | 'ň' => "n",
        'Ñ' => "N",
        'ç' | 'ć' | 'č' => "c",
        'Ç' => "C",
        'ß' => "ss",
        'š' | 'ś' => "s",
        'ž' | 'ź' | 'ż' => "z",
        'ł' => "l",
        'đ' => "d",
        'ţ' | 'ť' => "t",
        'ř' => "r",
        'ğ' => "g",
        'æ' => "ae",
        'Æ' => "AE",
        'œ' => "oe",
        _ => return vec![c],
    };
    folded.chars().collect()
}

pub fn contains_edition_keyword(segment: &str, keywords: &[&str]) -> bool {
    let lowered = segment.to_lowercase();
    let words = lowered
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty());
    for word in words {
        if keywords.contains(&word) {
            return true;
        }
    }
    keywords.contains(&"ft.") && lowered.contains("ft.")
}

pub fn strip_decorated_brackets(value: &str, keywords: &[&str]) -> String {
    let mut result = value.to_string();
    for (open, close) in [('(', ')'), ('[', ']'), ('{', '}')] {
        let mut search_from = 0usize;
        while let Some(open_offset) = result[search_from..].find(open) {
            let open_index = search_from + open_offset;
            let Some(close_offset) = result[open_index + open.len_utf8()..].find(close) else {
                break;
            };
            let close_index = open_index + open.len_utf8() + close_offset;
            let segment = &result[open_index + open.len_utf8()..close_index];
            if contains_edition_keyword(segment, keywords) {
                result.replace_range(open_index..close_index + close.len_utf8(), "");
                search_from = 0;
            } else {
                search_from = close_index + close.len_utf8();
            }
        }
    }
    result
}

/// Reduces a title to its edition-free base: decorated brackets removed, then
/// dash/colon suffixes dropped when they carry an edition keyword, then fully
/// normalized (iOS WantlistOwnership.baseTitle). The wantlist keyword set.
pub fn base_title(raw: &str) -> String {
    base_title_with(raw, &EDITION_KEYWORDS)
}

/// The keyword-parametrized base-title reduction backing both the wantlist
/// (full `EDITION_KEYWORDS`) and library consolidation (`CONSOLIDATION_KEYWORDS`)
/// so the strip logic is never forked.
pub fn base_title_with(raw: &str, keywords: &[&str]) -> String {
    let mut title = strip_decorated_brackets(&raw.to_lowercase(), keywords);
    for separator in [" - ", ": ", " – "] {
        if let Some(index) = title.find(separator) {
            let suffix = &title[index + separator.len()..];
            if contains_edition_keyword(suffix, keywords) {
                title.truncate(index);
            }
        }
    }
    normalize(&title)
}

pub fn match_key(title: &str, artist: &str) -> String {
    format!("{}\u{0}{}", normalize(artist), base_title(title))
}

pub fn norm_key(kind: &str, title: &str, artist: &str) -> String {
    format!("{}\u{0}{}", kind, match_key(title, artist))
}

/// Edition-aware ownership index over the local library, matching iOS
/// WantlistOwnership exactly (including the ≥4-char prefix tolerance for
/// album titles within the same artist).
pub struct Ownership {
    album_titles_by_artist: HashMap<String, Vec<String>>,
    track_keys: HashSet<String>,
    artists: HashSet<String>,
    track_count_by_album_key: HashMap<String, i64>,
}

impl Ownership {
    pub fn new(albums: &[Album], tracks: &[Track]) -> Self {
        let mut by_artist: HashMap<String, Vec<String>> = HashMap::new();
        for album in albums {
            by_artist
                .entry(normalize(&album.artist))
                .or_default()
                .push(base_title(&album.title));
        }
        let track_keys = tracks
            .iter()
            .map(|t| format!("{}\u{0}{}", normalize(&t.artist), base_title(&t.title)))
            .collect();
        let artists = albums.iter().map(|a| normalize(&a.artist)).collect();
        let mut counts: HashMap<String, i64> = HashMap::new();
        for track in tracks {
            *counts
                .entry(match_key(&track.album, &track.artist))
                .or_insert(0) += 1;
        }
        Self {
            album_titles_by_artist: by_artist,
            track_keys,
            artists,
            track_count_by_album_key: counts,
        }
    }

    pub fn owns_album(&self, name: &str, artist: &str) -> bool {
        let Some(owned) = self.album_titles_by_artist.get(&normalize(artist)) else {
            return false;
        };
        let base = base_title(name);
        if base.is_empty() {
            return true;
        }
        owned.iter().any(|candidate| {
            candidate == &base
                || (base.chars().count() >= 4 && candidate.starts_with(&base))
                || (candidate.chars().count() >= 4 && base.starts_with(candidate))
        })
    }

    pub fn owns_track(&self, title: &str, artist: &str) -> bool {
        self.track_keys
            .contains(&format!("{}\u{0}{}", normalize(artist), base_title(title)))
    }

    pub fn has_artist(&self, name: &str) -> bool {
        self.artists.contains(&normalize(name))
    }

    pub fn owned_track_count(&self, album_name: &str, artist: &str) -> i64 {
        self.track_count_by_album_key
            .get(&match_key(album_name, artist))
            .copied()
            .unwrap_or(0)
    }
}

fn is_lossless(track: &Track) -> bool {
    matches!(
        track.codec.as_deref().map(|c| c.to_uppercase()),
        Some(ref c) if ["FLAC", "ALAC", "WAV", "AIFF"].contains(&c.as_str())
    )
}

/// Gap: an album where the highest track number exceeds the owned count.
/// Upgrade: an album where every track with a known codec is lossy.
pub fn local_suggestions(albums: &[Album]) -> Vec<WantlistItemRow> {
    let mut records = Vec::new();
    for album in albums {
        let owned = album.tracks.len();
        let total = album
            .tracks
            .iter()
            .map(|t| t.track_number)
            .max()
            .unwrap_or(0) as usize;
        if owned >= 2 && total > owned && total <= 50 {
            records.push(WantlistItemRow {
                norm_key: format!("{}\u{0}gap", norm_key("album", &album.title, &album.artist)),
                kind: "album".to_string(),
                title: album.title.clone(),
                artist: album.artist.clone(),
                image_url: None,
                source: "gap".to_string(),
                score: 800.0 + owned as f64 / total as f64 * 100.0,
                reason: format!("You own {owned} of {total} tracks"),
                play_count: 0,
            });
        }
        let known_codecs = album.tracks.iter().filter(|t| t.codec.is_some()).count();
        if known_codecs == album.tracks.len()
            && !album.tracks.is_empty()
            && album.tracks.iter().all(|t| !is_lossless(t))
        {
            let codec = album
                .tracks
                .first()
                .and_then(|t| t.codec.clone())
                .map(|c| c.to_uppercase())
                .unwrap_or_else(|| "lossy".to_string());
            records.push(WantlistItemRow {
                norm_key: format!(
                    "{}\u{0}upgrade",
                    norm_key("album", &album.title, &album.artist)
                ),
                kind: "album".to_string(),
                title: album.title.clone(),
                artist: album.artist.clone(),
                image_url: None,
                source: "upgrade".to_string(),
                score: 300.0,
                reason: format!("In library as {codec} — get it lossless"),
                play_count: 0,
            });
        }
    }
    records
}

/// Crosses off wanted rows the library now covers (iOS resolveAgainstLibrary):
/// gap/upgrade rows resolve when the deficiency disappears and retire when the
/// album leaves the library; other rows resolve on plain ownership.
pub fn resolve_against_library(db: &Db, albums: &[Album], tracks: &[Track]) -> Vec<String> {
    let ownership = Ownership::new(albums, tracks);
    let open_deficiencies: HashSet<String> = local_suggestions(albums)
        .into_iter()
        .map(|s| s.norm_key)
        .collect();
    let mut resolved = Vec::new();
    for item in db.fetch_wanted_items() {
        if item.source == "gap" || item.source == "upgrade" {
            if open_deficiencies.contains(&item.norm_key) {
                continue;
            }
            if ownership.owns_album(&item.title, &item.artist) {
                if db.set_wantlist_state(&item.norm_key, "acquired").is_ok() {
                    resolved.push(item.title.clone());
                }
            } else {
                let _ = db.set_wantlist_state(&item.norm_key, "dismissed");
            }
            continue;
        }
        let owned = match item.kind.as_str() {
            "album" => ownership.owns_album(&item.title, &item.artist),
            "track" => ownership.owns_track(&item.title, &item.artist),
            "artist" => ownership.has_artist(&item.artist),
            _ => false,
        };
        if owned && db.set_wantlist_state(&item.norm_key, "acquired").is_ok() {
            resolved.push(if item.kind == "artist" {
                item.artist.clone()
            } else {
                item.title.clone()
            });
        }
    }
    resolved
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .user_agent("flaccy/1.0 (https://github.com/guitaripod/flaccy)")
        .build()
}

fn itunes_search(params: &[(&str, &str)]) -> Option<serde_json::Value> {
    let query: Vec<String> = params
        .iter()
        .map(|(k, v)| format!("{}={}", k, itunes_encode(v)))
        .collect();
    let url = format!("https://itunes.apple.com/search?{}", query.join("&"));
    let text = agent().get(&url).call().ok()?.into_string().ok()?;
    serde_json::from_str(&text).ok()
}

fn itunes_encode(input: &str) -> String {
    let mut result = String::new();
    for byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(*byte as char)
            }
            b' ' => result.push('+'),
            _ => result.push_str(&format!("%{:02X}", byte)),
        }
    }
    result
}

/// iTunes album search for one artist (attribute=artistTerm, limit 25), kept to
/// exact case-insensitive artist matches, mapped to release rows with 600x600
/// artwork (iOS fetchITunesAlbums).
fn fetch_itunes_albums(artist: &str) -> Option<Vec<NewReleaseRow>> {
    let json = itunes_search(&[
        ("term", artist),
        ("entity", "album"),
        ("attribute", "artistTerm"),
        ("limit", "25"),
    ])?;
    let results = json["results"].as_array()?;
    Some(
        results
            .iter()
            .filter_map(|entry| {
                let name = entry["collectionName"].as_str()?;
                let result_artist = entry["artistName"].as_str()?;
                if !result_artist.eq_ignore_ascii_case(artist) {
                    return None;
                }
                let date = entry["releaseDate"].as_str()?;
                let release_unix = chrono::DateTime::parse_from_rfc3339(date)
                    .ok()?
                    .timestamp();
                Some(NewReleaseRow {
                    artist: result_artist.to_string(),
                    album: name.to_string(),
                    release_unix,
                    image_url: entry["artworkUrl100"]
                        .as_str()
                        .map(|u| u.replace("100x100", "600x600")),
                    store_url: entry["collectionViewUrl"].as_str().map(String::from),
                })
            })
            .collect(),
    )
}

/// Resolves an artwork/store URL for a wantlist row that has none, via iTunes
/// album search (throttled by the caller).
fn fetch_itunes_artwork(title: &str, artist: &str) -> Option<(Option<String>, Option<String>)> {
    let term = format!("{artist} {title}");
    let json = itunes_search(&[("term", &term), ("entity", "album"), ("limit", "5")])?;
    let results = json["results"].as_array()?;
    let matched = results
        .iter()
        .find(|entry| {
            entry["artistName"]
                .as_str()
                .map(|a| a.eq_ignore_ascii_case(artist))
                .unwrap_or(false)
        })
        .or_else(|| results.first())?;
    Some((
        matched["artworkUrl100"]
            .as_str()
            .map(|u| u.replace("100x100", "600x600")),
        matched["collectionViewUrl"].as_str().map(String::from),
    ))
}

struct RefreshOutcome {
    resolved: Vec<String>,
    merged: usize,
}

/// Full wantlist refresh on a worker thread: local gaps/upgrades always, plus
/// Last.fm-sourced suggestions and the iTunes new-release watch when
/// authenticated. Emits WantlistChanged on completion.
pub fn refresh(core: &Rc<AppCore>) {
    if core.wantlist_in_flight.get() {
        return;
    }
    core.wantlist_in_flight.set(true);
    let library = core.library.borrow().clone();
    let albums = library.albums.clone();
    let tracks = library.tracks.clone();
    let db_path = core.db_path.clone();
    let session = core.session.borrow().clone();
    let (tx, rx) = async_channel::bounded::<RefreshOutcome>(1);
    std::thread::Builder::new()
        .name("flaccy-wantlist".into())
        .spawn(move || {
            let outcome = refresh_blocking(&db_path, session, &albums, &tracks);
            let _ = tx.send_blocking(outcome);
        })
        .ok();
    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        let outcome = rx.recv().await.ok();
        let Some(core) = weak.upgrade() else { return };
        core.wantlist_in_flight.set(false);
        if let Some(outcome) = outcome {
            crate::logger::info(
                "wantlist",
                &format!(
                    "wantlist refresh done: {} suggestions merged, {} resolved",
                    outcome.merged,
                    outcome.resolved.len()
                ),
            );
            if !outcome.resolved.is_empty() {
                core.toast(&format!("Got it: {}", outcome.resolved.join(", ")));
            }
        }
        core.hub.emit(&AppEvent::WantlistChanged);
    });
}

fn refresh_blocking(
    db_path: &PathBuf,
    session: Option<crate::config::Session>,
    albums: &[Album],
    tracks: &[Track],
) -> RefreshOutcome {
    let Ok(db) = Db::open(db_path) else {
        return RefreshOutcome {
            resolved: Vec::new(),
            merged: 0,
        };
    };
    let mut suggestions = local_suggestions(albums);
    let ownership = Ownership::new(albums, tracks);

    let client = crate::lastfm::LastFmClient::new(session.as_ref().map(|s| s.key.clone()));
    if let (Some(client), Some(session)) = (&client, &session) {
        suggestions.extend(remote_suggestions(client, &session.username, &ownership));
    }
    let merged = suggestions.len();
    if let Err(err) = db.merge_wantlist_suggestions(&suggestions) {
        crate::logger::error("wantlist", &format!("merge failed: {err}"));
    }
    let resolved = resolve_against_library(&db, albums, tracks);
    backfill_artwork(&db);
    if session.is_some() {
        refresh_new_releases_if_stale(&db, &ownership, tracks);
    }
    RefreshOutcome { resolved, merged }
}

fn remote_suggestions(
    client: &crate::lastfm::LastFmClient,
    username: &str,
    ownership: &Ownership,
) -> Vec<WantlistItemRow> {
    let mut records = Vec::new();

    let top_albums = client
        .fetch_top_albums(username, "overall", 50)
        .unwrap_or_default();
    for (name, artist, play_count, image_url) in top_albums
        .into_iter()
        .filter(|(name, artist, _, _)| !ownership.owns_album(name, artist))
        .take(MISSING_ALBUM_LIMIT)
    {
        let owned_tracks = ownership.owned_track_count(&name, &artist);
        let mut reason = format!("{play_count} plays on Last.fm");
        if owned_tracks > 0 {
            reason += &format!(" · you own {owned_tracks} of its tracks");
        }
        records.push(WantlistItemRow {
            norm_key: norm_key("album", &name, &artist),
            kind: "album".to_string(),
            title: name,
            artist,
            image_url,
            source: "history".to_string(),
            score: play_count as f64 * (1.0 + 0.15 * owned_tracks as f64),
            reason,
            play_count,
        });
    }

    let mut seen_tracks = HashSet::new();
    let top_tracks = client
        .fetch_top_tracks(username, "overall", 50)
        .unwrap_or_default();
    for (name, artist, play_count) in top_tracks {
        if ownership.owns_track(&name, &artist) {
            continue;
        }
        if !seen_tracks.insert(match_key(&name, &artist)) {
            continue;
        }
        records.push(WantlistItemRow {
            norm_key: norm_key("track", &name, &artist),
            kind: "track".to_string(),
            title: name,
            artist,
            image_url: None,
            source: "history".to_string(),
            score: play_count as f64,
            reason: format!("{play_count} plays on Last.fm"),
            play_count,
        });
        if seen_tracks.len() >= MISSING_TRACK_LIMIT {
            break;
        }
    }

    let loved = client
        .fetch_loved_tracks(username, 1, 200)
        .map(|(tracks, _)| tracks)
        .unwrap_or_default();
    for (name, artist) in loved {
        if ownership.owns_track(&name, &artist) {
            continue;
        }
        if !seen_tracks.insert(match_key(&name, &artist)) {
            continue;
        }
        records.push(WantlistItemRow {
            norm_key: norm_key("track", &name, &artist),
            kind: "track".to_string(),
            title: name,
            artist,
            image_url: None,
            source: "loved".to_string(),
            score: 500.0,
            reason: "Loved on Last.fm".to_string(),
            play_count: 0,
        });
        if seen_tracks.len() >= MISSING_TRACK_LIMIT + 10 {
            break;
        }
    }

    let seeds: Vec<(String, i64)> = client
        .fetch_top_artists(username, "overall", 20)
        .unwrap_or_default();
    records.extend(discovery_suggestions(client, &seeds, ownership));
    records
}

/// Scores each similar-artist candidate as Σ match × ln(1 + seed plays) across
/// all seeds that suggested it (iOS discoverySuggestions).
fn discovery_suggestions(
    client: &crate::lastfm::LastFmClient,
    seeds: &[(String, i64)],
    ownership: &Ownership,
) -> Vec<WantlistItemRow> {
    let seed_artists: Vec<&(String, i64)> = seeds.iter().take(SEED_ARTIST_COUNT).collect();
    if seed_artists.is_empty() {
        return Vec::new();
    }
    let known_names: HashSet<String> = seeds.iter().map(|(name, _)| match_key("", name)).collect();
    let mut scores: HashMap<String, (String, f64, String, f64)> = HashMap::new();
    for (seed_name, seed_plays) in &seed_artists {
        let similar = client
            .fetch_similar_artists(seed_name)
            .unwrap_or_default()
            .into_iter()
            .take(20);
        let weight = (1.0 + *seed_plays as f64).ln();
        for (candidate, matched) in similar {
            let key = match_key("", &candidate);
            if known_names.contains(&key) || ownership.has_artist(&candidate) {
                continue;
            }
            let contribution = matched * weight;
            let entry = scores
                .entry(key)
                .or_insert((candidate, 0.0, seed_name.clone(), 0.0));
            entry.1 += contribution;
            if contribution > entry.3 {
                entry.2 = seed_name.clone();
                entry.3 = contribution;
            }
        }
    }
    let mut ranked: Vec<(String, f64, String, f64)> = scores.into_values().collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    ranked.truncate(DISCOVER_ARTIST_LIMIT);

    let mut records: Vec<WantlistItemRow> = ranked
        .iter()
        .map(|(name, score, top_seed, _)| WantlistItemRow {
            norm_key: norm_key("artist", "", name),
            kind: "artist".to_string(),
            title: name.clone(),
            artist: name.clone(),
            image_url: None,
            source: "discovery".to_string(),
            score: *score,
            reason: format!("Because you play {top_seed}"),
            play_count: 0,
        })
        .collect();

    let mut album_count = 0;
    for (name, score, top_seed, _) in &ranked {
        if album_count >= DISCOVER_ALBUM_LIMIT {
            break;
        }
        let top = client.fetch_artist_top_albums(name, 3).unwrap_or_default();
        let Some((album, album_artist, image_url)) = top
            .into_iter()
            .find(|(album, artist, _)| !ownership.owns_album(album, artist))
        else {
            continue;
        };
        records.push(WantlistItemRow {
            norm_key: norm_key("album", &album, &album_artist),
            kind: "album".to_string(),
            title: album,
            artist: album_artist,
            image_url,
            source: "discovery".to_string(),
            score: *score,
            reason: format!("Because you play {top_seed}"),
            play_count: 0,
        });
        album_count += 1;
    }
    records
}

/// Fills missing artwork for wanted album rows via iTunes (3s/lookup throttle,
/// max 10 lookups per refresh so a large wantlist never stalls the worker).
fn backfill_artwork(db: &Db) {
    let missing: Vec<WantlistItemRow> = db
        .fetch_wanted_items()
        .into_iter()
        .filter(|item| item.kind == "album" && item.image_url.is_none())
        .take(10)
        .collect();
    for (index, item) in missing.iter().enumerate() {
        if index > 0 {
            std::thread::sleep(ITUNES_THROTTLE);
        }
        let Some((image_url, _)) = fetch_itunes_artwork(&item.title, &item.artist) else {
            continue;
        };
        if image_url.is_none() {
            continue;
        }
        let mut updated = item.clone();
        updated.image_url = image_url;
        let _ = db.merge_wantlist_suggestions(&[updated]);
    }
}

/// New-release watch (7-day TTL): iTunes album search for the top local
/// artists plus wantlisted artists (max 15, 3s apart), keeping releases inside
/// the 120-day window that the library does not own.
fn refresh_new_releases_if_stale(db: &Db, ownership: &Ownership, tracks: &[Track]) {
    let now = chrono::Utc::now().timestamp();
    if let Some(fetched_at) = db.new_releases_fetched_at() {
        if now - fetched_at < RELEASE_TTL_SECONDS {
            return;
        }
    }
    let mut plays: HashMap<String, usize> = HashMap::new();
    for track in tracks {
        *plays.entry(track.artist.clone()).or_insert(0) += 1;
    }
    let mut top_artists: Vec<(String, usize)> = plays.into_iter().collect();
    top_artists.sort_by(|a, b| b.1.cmp(&a.1));
    let wanted_artists: Vec<String> = db
        .fetch_wanted_items()
        .into_iter()
        .map(|item| item.artist)
        .collect();
    let mut seen = HashSet::new();
    let watchlist: Vec<String> = top_artists
        .into_iter()
        .map(|(name, _)| name)
        .chain(wanted_artists)
        .filter(|name| seen.insert(name.to_lowercase()))
        .take(RELEASE_ARTIST_LIMIT)
        .collect();

    let cutoff = now - RELEASE_WINDOW_SECONDS;
    let mut releases = Vec::new();
    let mut failed: HashSet<String> = HashSet::new();
    for (index, artist) in watchlist.iter().enumerate() {
        if index > 0 {
            std::thread::sleep(ITUNES_THROTTLE);
        }
        let Some(found) = fetch_itunes_albums(artist) else {
            failed.insert(artist.to_lowercase());
            continue;
        };
        for release in found {
            if release.release_unix > cutoff
                && !ownership.owns_album(&release.album, &release.artist)
            {
                releases.push(release);
            }
        }
    }
    if !failed.is_empty() {
        crate::logger::warn(
            "wantlist",
            &format!("new-release watch failed for {} artists", failed.len()),
        );
        let retained: Vec<NewReleaseRow> = db
            .fetch_new_releases()
            .into_iter()
            .filter(|r| failed.contains(&r.artist.to_lowercase()))
            .collect();
        releases.extend(retained);
    }
    match db.replace_new_releases(&releases) {
        Ok(()) => crate::logger::info(
            "wantlist",
            &format!(
                "new-release watch: {} releases across {} artists",
                releases.len(),
                watchlist.len()
            ),
        ),
        Err(err) => crate::logger::error("wantlist", &format!("release cache write failed: {err}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::TrackRow;

    fn track(title: &str, artist: &str, album: &str, number: i32, codec: &str) -> TrackRow {
        TrackRow {
            id: 0,
            rel_path: format!("{artist}/{album}/{title}.flac"),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            track_number: number,
            duration: 200.0,
            codec: Some(codec.to_string()),
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
        }
    }

    fn album(title: &str, artist: &str, tracks: Vec<TrackRow>) -> Album {
        Album {
            title: title.to_string(),
            artist: artist.to_string(),
            year: None,
            genre: None,
            tracks,
        }
    }

    #[test]
    fn normalize_strips_diacritics_and_punctuation() {
        assert_eq!(normalize("Sigur Rós"), "sigurros");
        assert_eq!(normalize("Beyoncé!"), "beyonce");
        assert_eq!(normalize("AC/DC"), "acdc");
        assert_eq!(normalize("Björk"), "bjork");
    }

    #[test]
    fn base_title_strips_edition_brackets() {
        assert_eq!(base_title("OK Computer (Deluxe Edition)"), "okcomputer");
        assert_eq!(base_title("Abbey Road [2019 Remaster]"), "abbeyroad");
        assert_eq!(base_title("Lonerism (feat. Someone)"), "lonerism");
        assert_eq!(base_title("Blue (Live at Somewhere)"), "blueliveatsomewhere");
    }

    #[test]
    fn base_title_keeps_non_edition_brackets() {
        assert_eq!(base_title("(What's the Story) Morning Glory?"), "whatsthestorymorningglory");
    }

    #[test]
    fn base_title_strips_edition_dash_suffixes() {
        assert_eq!(base_title("Nevermind - 2011 Remaster"), "nevermind");
        assert_eq!(base_title("In Rainbows: Deluxe"), "inrainbows");
        assert_eq!(base_title("Kid A – Special Edition"), "kida");
        assert_eq!(base_title("Song - Part Two"), "songparttwo");
        assert_eq!(
            base_title("Nevermind - Remastered"),
            "nevermindremastered",
            "exact-word keyword match, iOS parity: 'remastered' is not 'remaster'"
        );
    }

    #[test]
    fn match_key_composes_artist_and_base_title() {
        assert_eq!(
            match_key("OK Computer (Deluxe)", "Radiohead"),
            "radiohead\u{0}okcomputer"
        );
        assert_eq!(
            norm_key("album", "OK Computer", "Radiohead"),
            "album\u{0}radiohead\u{0}okcomputer"
        );
    }

    #[test]
    fn ownership_matches_editions_and_prefixes() {
        let albums = vec![album(
            "OK Computer (Deluxe Edition)",
            "Radiohead",
            vec![track("Airbag", "Radiohead", "OK Computer (Deluxe Edition)", 1, "FLAC")],
        )];
        let tracks = albums[0].tracks.clone();
        let ownership = Ownership::new(&albums, &tracks);
        assert!(ownership.owns_album("OK Computer", "Radiohead"));
        assert!(ownership.owns_album("ok computer (2017 remaster)", "radiohead"));
        assert!(ownership.owns_album("OK Computer OKNOTOK", "Radiohead"));
        assert!(!ownership.owns_album("Kid A", "Radiohead"));
        assert!(ownership.owns_track("Airbag (Remaster)", "Radiohead"));
        assert!(!ownership.owns_track("Creep", "Radiohead"));
        assert!(ownership.has_artist("radiohead"));
        assert_eq!(ownership.owned_track_count("OK Computer", "Radiohead"), 1);
    }

    #[test]
    fn ownership_prefix_requires_four_chars() {
        let albums = vec![album(
            "Up",
            "Peter Gabriel",
            vec![track("Sky Blue", "Peter Gabriel", "Up", 1, "FLAC")],
        )];
        let ownership = Ownership::new(&albums, &albums[0].tracks.clone());
        assert!(!ownership.owns_album("Upside Down World", "Peter Gabriel"));
        assert!(ownership.owns_album("Up", "Peter Gabriel"));
    }

    #[test]
    fn local_suggestions_gap_and_upgrade() {
        let gap_album = album(
            "Incomplete",
            "Artist",
            vec![
                track("One", "Artist", "Incomplete", 1, "FLAC"),
                track("Nine", "Artist", "Incomplete", 9, "FLAC"),
            ],
        );
        let lossy_album = album(
            "Lossy",
            "Artist",
            vec![
                track("A", "Artist", "Lossy", 1, "MP3"),
                track("B", "Artist", "Lossy", 2, "MP3"),
            ],
        );
        let complete = album(
            "Fine",
            "Artist",
            vec![track("A", "Artist", "Fine", 1, "FLAC")],
        );
        let suggestions = local_suggestions(&[gap_album, lossy_album, complete]);
        assert_eq!(suggestions.len(), 2);
        let gap = suggestions.iter().find(|s| s.source == "gap").expect("gap");
        assert_eq!(gap.title, "Incomplete");
        assert!(gap.reason.contains("2 of 9"));
        let upgrade = suggestions.iter().find(|s| s.source == "upgrade").expect("upgrade");
        assert_eq!(upgrade.title, "Lossy");
        assert!(upgrade.reason.contains("MP3"));
    }

    #[test]
    fn merge_does_not_resurrect_dismissed() {
        let temp = std::env::temp_dir().join(format!("flaccy-wl-test-{}.sqlite", std::process::id()));
        let _ = std::fs::remove_file(&temp);
        let db = Db::open(&temp).expect("db");
        let item = WantlistItemRow {
            norm_key: "album\u{0}a\u{0}b".to_string(),
            kind: "album".to_string(),
            title: "B".to_string(),
            artist: "A".to_string(),
            image_url: None,
            source: "history".to_string(),
            score: 10.0,
            reason: "r".to_string(),
            play_count: 10,
        };
        db.merge_wantlist_suggestions(&[item.clone()]).expect("merge");
        assert_eq!(db.fetch_wanted_items().len(), 1);
        db.set_wantlist_state(&item.norm_key, "dismissed").expect("dismiss");
        db.merge_wantlist_suggestions(&[item]).expect("re-merge");
        assert_eq!(db.fetch_wanted_items().len(), 0, "dismissed row must not resurrect");
        let _ = std::fs::remove_file(&temp);
    }
}
