use crate::app::AppCore;
use crate::db::Db;
use crate::events::AppEvent;
use crate::lastfm::LastFmClient;
use gtk::glib;
use std::cell::Cell;
use std::collections::HashSet;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, Instant};

const USER_AGENT: &str = "flaccy/1.0 (https://github.com/guitaripod/flaccy)";
const RETRY_WINDOW_SECONDS: i64 = 30 * 86_400;
const SIMILAR_FRESH_SECONDS: i64 = 30 * 86_400;

pub struct EnrichRequest {
    pub title: String,
    pub artist: String,
}

struct Throttle {
    last: Option<Instant>,
    interval: Duration,
}

impl Throttle {
    fn new(interval: Duration) -> Self {
        Self {
            last: None,
            interval,
        }
    }

    fn wait(&mut self) {
        if let Some(last) = self.last {
            let elapsed = last.elapsed();
            if elapsed < self.interval {
                std::thread::sleep(self.interval - elapsed);
            }
        }
        self.last = Some(Instant::now());
    }
}

pub fn start(core: &Rc<AppCore>) {
    let (req_tx, req_rx) = async_channel::unbounded::<EnrichRequest>();
    let (done_tx, done_rx) = async_channel::unbounded::<(String, String, bool)>();
    let db_path = core.db_path.clone();
    let session_key = core.session.borrow().as_ref().map(|s| s.key.clone());
    std::thread::Builder::new()
        .name("flaccy-enrich".into())
        .spawn(move || enrich_worker(db_path, session_key, req_rx, done_tx))
        .ok();
    *core.enrich_tx.borrow_mut() = Some(req_tx);

    let weak = Rc::downgrade(core);
    let reload_scheduled = Rc::new(Cell::new(false));
    glib::spawn_future_local(async move {
        while let Ok((title, artist, changed)) = done_rx.recv().await {
            let Some(core) = weak.upgrade() else { break };
            core.note_enrichment_done();
            if !changed {
                continue;
            }
            core.artwork.invalidate(&title, &artist);
            core.hub.emit(&AppEvent::AlbumEnriched {
                title: title.clone(),
                artist: artist.clone(),
            });
            if !reload_scheduled.replace(true) {
                let weak_inner = Rc::downgrade(&core);
                let flag = Rc::clone(&reload_scheduled);
                glib::timeout_add_local_once(Duration::from_secs(15), move || {
                    flag.set(false);
                    if let Some(core) = weak_inner.upgrade() {
                        core.reload_library();
                    }
                });
            }
        }
    });
}

pub fn request_album(core: &Rc<AppCore>, title: &str, artist: &str) {
    if let Some(tx) = core.enrich_tx.borrow().as_ref() {
        if tx
            .send_blocking(EnrichRequest {
                title: title.to_string(),
                artist: artist.to_string(),
            })
            .is_ok()
        {
            core.add_enrichment_pending();
        }
    }
}

/// Enqueues every album still missing year, genre or cover art (and not
/// attempted within the retry window) for background enrichment.
pub fn schedule_background_pass(core: &Rc<AppCore>) {
    let library = core.library.borrow().clone();
    let now = chrono::Utc::now().timestamp();
    let mut queued = 0;
    for album in &library.albums {
        let status = core.db.album_info_status(&album.title, &album.artist);
        if !needs_enrichment(status.as_ref(), now) {
            continue;
        }
        request_album(core, &album.title, &album.artist);
        queued += 1;
    }
    if queued > 0 {
        crate::logger::info(
            "enrichment",
            &format!("background enrichment pass queued {queued} albums"),
        );
    }
}

fn needs_enrichment(status: Option<&crate::db::AlbumInfoStatus>, now: i64) -> bool {
    match status {
        None => true,
        Some(status) => {
            let complete = status.year.is_some() && status.genre.is_some() && status.has_cover;
            if complete {
                return false;
            }
            match status.last_fetched_unix {
                Some(fetched) => now - fetched > RETRY_WINDOW_SECONDS,
                None => true,
            }
        }
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .user_agent(USER_AGENT)
        .build()
}

fn enrich_worker(
    db_path: PathBuf,
    session_key: Option<String>,
    rx: async_channel::Receiver<EnrichRequest>,
    tx: async_channel::Sender<(String, String, bool)>,
) {
    let Ok(db) = Db::open(&db_path) else {
        crate::logger::error("enrichment", "worker db open failed");
        return;
    };
    let client = LastFmClient::new(session_key);
    let mut general = Throttle::new(Duration::from_millis(200));
    let mut musicbrainz = Throttle::new(Duration::from_secs(1));
    let mut enriched_artists: HashSet<String> = HashSet::new();
    let mut seen: HashSet<String> = HashSet::new();

    while let Ok(request) = rx.recv_blocking() {
        let dedupe = format!("{}|{}", request.title, request.artist);
        if !seen.insert(dedupe) {
            continue;
        }
        let now = chrono::Utc::now().timestamp();
        let status = db.album_info_status(&request.title, &request.artist);
        if !needs_enrichment(status.as_ref(), now) {
            continue;
        }
        let changed = enrich_one(
            &db,
            client.as_ref(),
            &mut general,
            &mut musicbrainz,
            &mut enriched_artists,
            &request,
            status.as_ref(),
        );
        if tx
            .send_blocking((request.title, request.artist, changed))
            .is_err()
        {
            break;
        }
    }
}

fn enrich_one(
    db: &Db,
    client: Option<&LastFmClient>,
    general: &mut Throttle,
    musicbrainz: &mut Throttle,
    enriched_artists: &mut HashSet<String>,
    request: &EnrichRequest,
    status: Option<&crate::db::AlbumInfoStatus>,
) -> bool {
    let has_cover = status.map(|s| s.has_cover).unwrap_or(false);
    let mut cover_url: Option<String> = None;
    let mut mbid: Option<String> = None;
    let mut cover_data: Option<Vec<u8>> = None;

    if let Some(client) = client {
        general.wait();
        match client.fetch_album_info(&request.artist, &request.title) {
            Ok((url, id)) => {
                cover_url = url;
                mbid = id;
            }
            Err(err) => {
                crate::logger::warn(
                    "enrichment",
                    &format!("album.getInfo failed for {}: {err}", request.title),
                );
            }
        }
    }

    if !has_cover {
        if let Some(url) = &cover_url {
            cover_data = download_bytes(url);
        }
    }

    let mut year: Option<String> = None;
    let mut genre: Option<String> = None;
    musicbrainz.wait();
    if let Some(release) = fetch_musicbrainz_release(&request.artist, &request.title) {
        if !has_cover && cover_data.is_none() {
            if let Some(rgid) = &release.release_group_id {
                cover_data = fetch_cover_art_archive("release-group", rgid);
            }
            if cover_data.is_none() {
                cover_data = fetch_cover_art_archive("release", &release.id);
            }
        }
        year = release.year;
        genre = release.genre;
        if mbid.is_none() {
            mbid = Some(release.id);
        }
    }

    if !has_cover && cover_data.is_none() {
        cover_data = fetch_deezer_album_cover(&request.artist, &request.title);
    }

    let result = db.apply_album_enrichment(
        &request.title,
        &request.artist,
        year.as_deref(),
        genre.as_deref(),
        cover_url.as_deref(),
        cover_data.as_deref(),
        mbid.as_deref(),
    );
    if let Err(err) = result {
        crate::logger::error(
            "enrichment",
            &format!("albumInfo write failed for {}: {err}", request.title),
        );
        return false;
    }

    if let Some(client) = client {
        if enriched_artists.insert(request.artist.to_lowercase()) {
            general.wait();
            match client.fetch_artist_info(&request.artist) {
                Ok((bio, lastfm_image, artist_mbid)) => {
                    let image_url =
                        fetch_deezer_artist_image(&request.artist).or(lastfm_image);
                    if let Err(err) = db.upsert_artist_info(
                        &request.artist,
                        bio.as_deref(),
                        image_url.as_deref(),
                        artist_mbid.as_deref(),
                    ) {
                        crate::logger::error(
                            "enrichment",
                            &format!("artist write failed for {}: {err}", request.artist),
                        );
                    }
                }
                Err(err) => {
                    crate::logger::warn(
                        "enrichment",
                        &format!("artist.getInfo failed for {}: {err}", request.artist),
                    );
                }
            }
        }
    }

    let changed = year.is_some() || genre.is_some() || cover_data.is_some();
    crate::logger::info(
        "enrichment",
        &format!(
            "enriched {} — {} (year {:?}, genre {:?}, cover {})",
            request.title,
            request.artist,
            year,
            genre,
            cover_data.as_ref().map(|d| d.len()).unwrap_or(0)
        ),
    );
    changed
}

fn download_bytes(url: &str) -> Option<Vec<u8>> {
    let response = agent().get(url).call().ok()?;
    let mut data = Vec::new();
    use std::io::Read;
    response
        .into_reader()
        .take(20 * 1024 * 1024)
        .read_to_end(&mut data)
        .ok()?;
    if data.is_empty() {
        None
    } else {
        Some(data)
    }
}

struct MusicBrainzRelease {
    id: String,
    release_group_id: Option<String>,
    year: Option<String>,
    genre: Option<String>,
}

fn fetch_musicbrainz_release(artist: &str, album: &str) -> Option<MusicBrainzRelease> {
    let query = format!("release:{album} AND artist:{artist}");
    let url = format!(
        "https://musicbrainz.org/ws/2/release/?query={}&limit=1&fmt=json",
        url_encode(&query)
    );
    let response = agent().get(&url).call();
    let text = match response {
        Ok(resp) => resp.into_string().ok()?,
        Err(err) => {
            crate::logger::warn("enrichment", &format!("musicbrainz failed: {err}"));
            return None;
        }
    };
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    let release = json["releases"].as_array()?.first()?.clone();
    let id = release["id"].as_str()?.to_string();
    let release_group_id = release["release-group"]["id"].as_str().map(String::from);
    let year = release["date"]
        .as_str()
        .filter(|d| d.len() >= 4)
        .map(|d| d[..4].to_string());
    let genre = release["tags"].as_array().and_then(|tags| {
        tags.iter()
            .max_by_key(|t| t["count"].as_i64().unwrap_or(0))
            .and_then(|t| t["name"].as_str())
            .map(String::from)
    });
    Some(MusicBrainzRelease {
        id,
        release_group_id,
        year,
        genre,
    })
}

/// Cover Art Archive front cover for a MusicBrainz release or release-group,
/// downsized to 500px. This is the Linux stand-in for the iOS Apple Music
/// artwork fallback: it covers albums whose files have no embedded art and
/// which Last.fm has no image for.
fn fetch_cover_art_archive(entity: &str, mbid: &str) -> Option<Vec<u8>> {
    download_bytes(&format!(
        "https://coverartarchive.org/{entity}/{mbid}/front-500"
    ))
}

/// Deezer album cover (no API key) — a broad streaming-catalog fallback that
/// covers many releases MusicBrainz/Cover Art Archive don't, matching how
/// Strawberry pulls art from multiple providers.
fn fetch_deezer_album_cover(artist: &str, album: &str) -> Option<Vec<u8>> {
    let query = format!("artist:\"{artist}\" album:\"{album}\"");
    let url = format!(
        "https://api.deezer.com/search/album?q={}&limit=1",
        url_encode(&query)
    );
    let text = agent().get(&url).call().ok()?.into_string().ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    let cover = json["data"][0]["cover_xl"]
        .as_str()
        .or_else(|| json["data"][0]["cover_big"].as_str())
        .filter(|url| !url.is_empty())?;
    download_bytes(cover)
}

/// Deezer artist photo URL (no API key) — a real portrait source, unlike
/// Last.fm which now serves a placeholder for every artist.
fn fetch_deezer_artist_image(artist: &str) -> Option<String> {
    let url = format!(
        "https://api.deezer.com/search/artist?q={}&limit=1",
        url_encode(artist)
    );
    let text = agent().get(&url).call().ok()?.into_string().ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    json["data"][0]["picture_xl"]
        .as_str()
        .or_else(|| json["data"][0]["picture_big"].as_str())
        .filter(|url| !url.is_empty())
        .map(String::from)
}

/// Blocking similar-artists lookup with the 30-day similarArtistCache window,
/// intersected case-insensitively with the library's artists. Runs on worker
/// threads only.
pub fn similar_in_library_blocking(
    db: &Db,
    client: Option<&LastFmClient>,
    seed_artist: &str,
    library_artists: &[String],
) -> Vec<(String, f64)> {
    let now = chrono::Utc::now().timestamp();
    let cached = db.similar_artists(seed_artist);
    let fresh = cached
        .first()
        .map(|(_, _, fetched)| now - fetched < SIMILAR_FRESH_SECONDS)
        .unwrap_or(false);
    let similar: Vec<(String, f64)> = if fresh {
        cached
            .into_iter()
            .map(|(name, matched, _)| (name, matched))
            .collect()
    } else if let Some(client) = client {
        match client.fetch_similar_artists(seed_artist) {
            Ok(entries) => {
                if let Err(err) = db.replace_similar_artists(seed_artist, &entries) {
                    crate::logger::warn(
                        "enrichment",
                        &format!("similarArtistCache write failed: {err}"),
                    );
                }
                entries
            }
            Err(err) => {
                crate::logger::warn(
                    "enrichment",
                    &format!("artist.getSimilar failed for {seed_artist}: {err}"),
                );
                cached
                    .into_iter()
                    .map(|(name, matched, _)| (name, matched))
                    .collect()
            }
        }
    } else {
        cached
            .into_iter()
            .map(|(name, matched, _)| (name, matched))
            .collect()
    };

    let owned: std::collections::HashMap<String, String> = library_artists
        .iter()
        .map(|name| (name.to_lowercase(), name.clone()))
        .collect();
    let mut result: Vec<(String, f64)> = similar
        .into_iter()
        .filter_map(|(name, matched)| {
            owned
                .get(&name.to_lowercase())
                .map(|canonical| (canonical.clone(), matched))
        })
        .collect();
    result.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    result
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
