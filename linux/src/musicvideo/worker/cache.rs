//! The prepared music video files: an in-memory index the live path reads, and
//! the lane that fills the folder behind it. The lane matches, fetches and
//! aligns the videos of the songs the planner wants, keeps the folder inside
//! its budget, and reconciles folder and database at start so a crash leaves
//! either nothing or a partial file it can resume.

use super::download::{self, Stop, CHUNK_BYTES, RATE_CAP};
use super::{
    align_now, note_failed, note_nothing, note_pick, pick, recheck, remembered, Pick, Remembered,
    Response, Shared, ALIGN_VERSION, MATCH_VERSION,
};
use crate::db::{Db, STATE_FAILED, STATE_PART, STATE_READY};
use crate::library::Track;
use crate::musicvideo::stream::{Codec, Stream};
use crate::musicvideo::{Settings, VideoMatch};
use crate::precache::candidates::{self, Ranked};
use crate::precache::governor::{Breaker, YOUTUBE};
use crate::precache::status::{self, LaneState};
use flaccy_shared::precache::{
    chance_of_play, effective_budget, make_room, retry_delay_seconds, wanted_videos, Candidate,
    Failure, Held, Tier,
};
use gtk::gio::prelude::FileExt;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How long the lane naps between looks at a rest, the network or a newer
/// plan.
const NAP: Duration = Duration::from_millis(250);

/// An extra pause of up to this long after the gap between YouTube requests,
/// so the rhythm is not a metronome.
const PACE_JITTER_MS: u64 = 3000;

pub struct Warm {
    pub queue: Vec<Track>,
    pub settings: Settings,
    pub cap_bytes: u64,
    pub enabled: bool,
    pub blocker: crate::precache::Blocker,
}

pub enum Msg {
    Warm(Warm),
    Played { video_id: String, ceiling: i32 },
    Lost { video_id: String, ceiling: i32 },
    Clear,
}

#[derive(Clone)]
pub struct Cached {
    pub path: PathBuf,
    pub height: i32,
    pub codec: Option<Codec>,
    pub bytes: u64,
}

#[derive(Default)]
pub struct Index {
    files: Mutex<HashMap<(String, i32), Cached>>,
}

impl Index {
    fn get(&self, video_id: &str, ceiling: i32) -> Option<Cached> {
        self.files
            .lock()
            .ok()?
            .get(&(video_id.to_string(), ceiling))
            .cloned()
    }

    fn put(&self, video_id: &str, ceiling: i32, cached: Cached) {
        if let Ok(mut files) = self.files.lock() {
            files.insert((video_id.to_string(), ceiling), cached);
        }
    }

    fn remove(&self, video_id: &str, ceiling: i32) {
        if let Ok(mut files) = self.files.lock() {
            files.remove(&(video_id.to_string(), ceiling));
        }
    }
}

pub fn cache_dir() -> PathBuf {
    super::scratch_dir()
}

impl Shared {
    /// The prepared file for a video at this quality ceiling, as a stream the
    /// player can open. A file that is gone or the wrong size is dropped and
    /// reported, so the next look streams instead.
    pub(super) fn cached_stream(&self, video_id: &str, ceiling: i32) -> Option<Stream> {
        let cached = self.cache.get(video_id, ceiling)?;
        let size = std::fs::metadata(&cached.path).map(|meta| meta.len());
        if size.ok() != Some(cached.bytes) {
            self.cache.remove(video_id, ceiling);
            self.tell_lane(Msg::Lost {
                video_id: video_id.to_string(),
                ceiling,
            });
            return None;
        }
        Some(Stream {
            url: gtk::gio::File::for_path(&cached.path).uri().to_string(),
            expires_at: i64::MAX,
            height: cached.height,
            codec: cached.codec,
        })
    }

    pub(super) fn note_played(&self, video_id: &str, ceiling: i32) {
        self.tell_lane(Msg::Played {
            video_id: video_id.to_string(),
            ceiling,
        });
    }

    /// The player could not use the prepared file, so it is not trusted again.
    pub(super) fn drop_cached(&self, video_id: &str, ceiling: i32) {
        if self.cache.get(video_id, ceiling).is_some() {
            self.cache.remove(video_id, ceiling);
            self.tell_lane(Msg::Lost {
                video_id: video_id.to_string(),
                ceiling,
            });
        }
    }

    pub(super) fn tell_lane(&self, msg: Msg) {
        if matches!(msg, Msg::Warm(_) | Msg::Clear) {
            self.preempt.store(true, Ordering::Release);
        }
        let _ = self.lane.send_blocking(msg);
    }
}

/// `<video id>.<ceiling>.<container>`, with `.part` while it downloads. The
/// lane touches no other file in the folder.
pub fn parse_cache_name(name: &str) -> Option<(String, i32, bool)> {
    let (stem, part) = match name.strip_suffix(".part") {
        Some(stem) => (stem, true),
        None => (name, false),
    };
    let mut pieces = stem.split('.');
    let (id, ceiling, container) = (pieces.next()?, pieces.next()?, pieces.next()?);
    let id_ok = id.len() == 11
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    let container_ok = matches!(container, "mp4" | "webm" | "mkv");
    (id_ok && container_ok && pieces.next().is_none())
        .then(|| ceiling.parse().ok())
        .flatten()
        .map(|ceiling| (id.to_string(), ceiling, part))
}

/// What a message from yt-dlp or the stream resolver says about whether to
/// carry on.
pub fn classify_text(message: &str) -> Failure {
    let lower = message.to_lowercase();
    if lower.contains("429") || lower.contains("too many") || lower.contains("slow down") {
        Failure::Throttled
    } else if lower.contains("blocked") || lower.contains("refused") || lower.contains("sign in") {
        Failure::Blocked
    } else if lower.contains("isn't installed") {
        Failure::Blocked
    } else if lower.contains("unavailable") || lower.contains("private") || lower.contains("removed") {
        Failure::NotFound
    } else {
        Failure::Transient
    }
}

fn codec_from_label(label: &str) -> Option<Codec> {
    [Codec::Av1, Codec::Vp9, Codec::H264]
        .into_iter()
        .find(|codec| codec.label() == label)
}

fn space_of(dir: &Path) -> (u64, u64) {
    let info = gtk::gio::File::for_path(dir).query_filesystem_info(
        "filesystem::free,filesystem::size",
        gtk::gio::Cancellable::NONE,
    );
    match info {
        Ok(info) => (
            info.attribute_uint64("filesystem::free"),
            info.attribute_uint64("filesystem::size"),
        ),
        Err(_) => (u64::MAX / 4, 0),
    }
}

fn now_unix() -> i64 {
    chrono::Utc::now().timestamp()
}

struct Context {
    chances: HashMap<String, f64>,
}

pub fn spawn(shared: Arc<Shared>, rx: async_channel::Receiver<Msg>) {
    std::thread::Builder::new()
        .name("flaccy-mv-cache".into())
        .spawn(move || {
            let Ok(db) = Db::open(&shared.db_path) else {
                return;
            };
            let mut lane = Lane {
                shared,
                db,
                dir: cache_dir(),
                breaker: Breaker::default(),
                rx,
                inbox: VecDeque::new(),
                cap_bytes: 0,
                space: space_of,
            };
            lane.reconcile();
            lane.run();
        })
        .ok();
}

struct Lane {
    shared: Arc<Shared>,
    db: Db,
    dir: PathBuf,
    breaker: Breaker,
    rx: async_channel::Receiver<Msg>,
    inbox: VecDeque<Msg>,
    cap_bytes: u64,
    space: fn(&Path) -> (u64, u64),
}

impl Lane {
    fn run(&mut self) {
        loop {
            let msg = match self.inbox.pop_front() {
                Some(msg) => msg,
                None => match self.rx.recv_blocking() {
                    Ok(msg) => msg,
                    Err(_) => return,
                },
            };
            match msg {
                Msg::Played { video_id, ceiling } => {
                    self.db.video_cache_played(&video_id, ceiling, now_unix());
                }
                Msg::Lost { video_id, ceiling } => self.forget(&video_id, ceiling),
                Msg::Clear => self.clear(),
                Msg::Warm(warm) => {
                    let mut latest = warm;
                    while let Ok(next) = self.rx.try_recv() {
                        match next {
                            Msg::Warm(newer) => latest = newer,
                            other => self.inbox.push_back(other),
                        }
                    }
                    self.shared.preempt.store(false, Ordering::Release);
                    self.prepare(latest);
                }
            }
        }
    }

    fn preempted(&self) -> bool {
        self.shared.preempt.load(Ordering::Acquire)
    }

    /// Sleeps `total` in short naps, giving up early when a newer plan
    /// arrives. False means it did.
    fn nap(&self, total: Duration) -> bool {
        let mut left = total;
        while !left.is_zero() {
            if self.preempted() {
                return false;
            }
            let slice = left.min(NAP);
            std::thread::sleep(slice);
            left -= slice;
        }
        !self.preempted()
    }

    /// Holds back until YouTube may be asked again: its gap since the last
    /// request, with jitter. False when a newer plan arrived meanwhile.
    fn pace(&self) -> bool {
        let wait = YOUTUBE
            .claim_at(std::time::Instant::now(), Duration::from_secs(3600))
            .unwrap_or_default();
        let jitter = Duration::from_millis((rand::random::<f64>() * PACE_JITTER_MS as f64) as u64);
        self.nap(wait + jitter)
    }

    /// Waits out a rest or an offline stretch. False when a newer plan
    /// arrived meanwhile.
    fn wait_until_ready(&self, blocker: &dyn Fn() -> Option<&'static str>) -> bool {
        loop {
            if self.preempted() {
                return false;
            }
            let rest = self.breaker.rest_left();
            if !rest.is_zero() {
                let until = now_unix() + rest.as_secs() as i64;
                let reason = match self.breaker.last() {
                    Some(Failure::Throttled) => "YouTube asked for fewer requests",
                    Some(Failure::Blocked) => "YouTube turned the requests away",
                    _ => "YouTube could not be reached",
                }
                .to_string();
                status::update(|status| status.video = LaneState::Resting { until_unix: until, reason });
                std::thread::sleep(rest.min(NAP));
                continue;
            }
            if let Some(reason) = blocker() {
                status::update(|status| {
                    status.video = LaneState::Resting {
                        until_unix: now_unix() + 5,
                        reason: reason.to_string(),
                    }
                });
                std::thread::sleep(NAP);
                continue;
            }
            return true;
        }
    }

    fn prepare(&mut self, warm: Warm) {
        self.cap_bytes = warm.cap_bytes;
        if !warm.enabled {
            status::update(|status| {
                status.video = LaneState::Off;
                status.video_current.clear();
            });
            self.refresh_status();
            return;
        }
        let ranked = candidates::build(&self.db, &warm.queue, now_unix());
        let all: Vec<Candidate> = ranked.iter().map(|entry| entry.candidate.clone()).collect();
        let wanted = wanted_videos(&all);
        let context = Context {
            chances: self.chances_by_video(&ranked),
        };
        let by_key: HashMap<&str, &Ranked> = ranked
            .iter()
            .map(|entry| (entry.candidate.key.as_str(), entry))
            .collect();
        status::update(|status| status.video = LaneState::Idle);
        self.refresh_status();
        for item in &wanted {
            if self.preempted() {
                return;
            }
            let Some(entry) = by_key.get(item.key.as_str()) else {
                continue;
            };
            if !self.wait_until_ready(&*warm.blocker) {
                return;
            }
            let title = entry.track.title.clone();
            status::update(|status| {
                status.video = LaneState::Working;
                status.video_current = title;
            });
            self.prepare_one(&entry.track, item.tier, item.chance, &warm, &context);
        }
        status::update(|status| {
            if status.video == LaneState::Working {
                status.video = LaneState::Idle;
            }
            status.video_current.clear();
        });
        self.refresh_status();
    }

    fn prepare_one(&mut self, track: &Track, tier: Tier, chance: f64, warm: &Warm, context: &Context) {
        let settings = &warm.settings;
        let found = match remembered(&self.db, track) {
            Remembered::Match(found) => found,
            Remembered::Recheck(old) => {
                if !self.pace() {
                    return;
                }
                match recheck(&self.shared, &self.db, track, settings, None, old) {
                    Some(found) => found,
                    None => return,
                }
            }
            Remembered::Miss => return,
            Remembered::Unknown => {
                if !self.pace() {
                    return;
                }
                match pick(&self.shared, track, settings, None) {
                    Pick::Chosen(found) => {
                        note_pick(track, &found, "the songs coming up");
                        self.db
                            .save_music_video(&track.title, &track.artist, Some(&found), 1.0, MATCH_VERSION);
                        self.breaker.succeeded();
                        found
                    }
                    Pick::Nothing(reason) => {
                        note_nothing(track, &reason);
                        self.db
                            .save_music_video(&track.title, &track.artist, None, 0.0, MATCH_VERSION);
                        self.breaker.succeeded();
                        return;
                    }
                    Pick::Failed(err) => {
                        note_failed(track, &err);
                        self.breaker.failed(classify_text(&err));
                        return;
                    }
                    Pick::Stale => return,
                }
            }
        };
        if tier == Tier::File {
            self.ensure_file(&found, track, chance, warm, context);
        }
        if settings.align && found.align_version < ALIGN_VERSION && !self.preempted() {
            if !self.pace() {
                return;
            }
            if let Some(aligned) = align_now(&self.shared, &self.db, track, &found) {
                self.shared.send(Response::Aligned { found: aligned });
            }
        }
    }

    fn ensure_file(&mut self, found: &VideoMatch, track: &Track, chance: f64, warm: &Warm, context: &Context) {
        let ceiling = warm.settings.max_height;
        let id = &found.video_id;
        if self.shared.cache.get(id, ceiling).is_some() {
            return;
        }
        let prior = self.db.video_cache_entry(id, ceiling);
        if let Some(row) = &prior {
            if row.next_attempt_at.is_some_and(|next| next > now_unix()) {
                return;
            }
        }
        if !self.pace() {
            return;
        }
        let (mut stream, _) = match self.shared.stream_for(id, &warm.settings, false, false) {
            Ok(resolved) => resolved,
            Err(err) => {
                self.record_failure(id, ceiling, classify_text(&err), &err);
                return;
            }
        };
        let mut renewed = false;
        loop {
            match self.download_once(found, &stream, ceiling, chance, track, context) {
                Ok(()) => return,
                Err(Stop::Preempted) => return,
                Err(Stop::NoRoom { need }) => {
                    crate::logger::info(
                        "precache",
                        &format!(
                            "no room for {id} ({} MB): the cache holds likelier videos",
                            need / 1_000_000
                        ),
                    );
                    return;
                }
                Err(Stop::Refused) if !renewed => {
                    renewed = true;
                    if !self.pace() {
                        return;
                    }
                    match self.shared.stream_for(id, &warm.settings, false, true) {
                        Ok((fresh, _)) => stream = fresh,
                        Err(err) => {
                            self.record_failure(id, ceiling, classify_text(&err), &err);
                            return;
                        }
                    }
                }
                Err(Stop::Refused) => {
                    self.record_failure(id, ceiling, Failure::Blocked, "YouTube refused the video's stream twice");
                    return;
                }
                Err(Stop::Failed(class, message)) => {
                    self.record_failure(id, ceiling, class, &message);
                    return;
                }
            }
        }
    }

    fn download_once(
        &mut self,
        found: &VideoMatch,
        stream: &Stream,
        ceiling: i32,
        chance: f64,
        track: &Track,
        context: &Context,
    ) -> Result<(), Stop> {
        let id = &found.video_id;
        let name = format!("{id}.{ceiling}.{}", download::extension_of(&stream.url));
        let part = self.dir.join(format!("{name}.part"));
        std::fs::create_dir_all(&self.dir).map_err(|err| {
            Stop::Failed(Failure::Transient, format!("could not make the video folder: {err}"))
        })?;
        self.clear_other_parts(id, ceiling, &name);
        let have = std::fs::metadata(&part).map(|meta| meta.len()).unwrap_or(0);
        let held = self.held(id, ceiling, context);
        let cap = self.cap_bytes;
        let dir = self.dir.clone();
        let space = self.space;
        let victims = std::cell::RefCell::new(Vec::<String>::new());
        let (height, codec) = (stream.height, stream.codec.map(|codec| codec.label()).unwrap_or_default());
        let db = &self.db;
        let shared = &self.shared;
        let total_seen = std::cell::Cell::new(0u64);
        let outcome = download::download(
            &stream.url,
            &part,
            CHUNK_BYTES,
            RATE_CAP,
            &mut |total| {
                total_seen.set(total);
                let used: u64 = held.iter().map(|file| file.bytes).sum();
                let (free, size) = space(&dir);
                let budget = effective_budget(cap, used, free.saturating_add(have), size);
                match make_room(&held, total, budget, chance) {
                    Some(ids) => {
                        *victims.borrow_mut() = ids;
                        true
                    }
                    None => false,
                }
            },
            &mut |bytes, total| {
                db.video_cache_progress(id, ceiling, height, codec, &name, bytes, total, now_unix());
            },
            &|| shared.preempt.load(Ordering::Acquire),
        );
        for victim in victims.borrow().iter() {
            if let Some((video_id, victim_ceiling)) = victim.rsplit_once('|') {
                if let Ok(victim_ceiling) = victim_ceiling.parse() {
                    crate::logger::info("precache", &format!("making room: dropping {video_id}"));
                    self.forget(video_id, victim_ceiling);
                }
            }
        }
        let total = outcome?;
        self.commit(found, stream, ceiling, &name, total, track)
    }

    /// Checks a finished download the way a player will read it, then makes
    /// it the cache's by renaming it.
    fn commit(
        &mut self,
        found: &VideoMatch,
        stream: &Stream,
        ceiling: i32,
        name: &str,
        total: u64,
        track: &Track,
    ) -> Result<(), Stop> {
        let id = &found.video_id;
        let part = self.dir.join(format!("{name}.part"));
        let target = self.dir.join(name);
        let mut height = stream.height;
        match download::probe(&part) {
            Some(Ok(probed)) if download::matches_length(&probed, found.duration) => {
                if probed.height > 0 {
                    height = probed.height;
                }
            }
            Some(Ok(probed)) => {
                let _ = std::fs::remove_file(&part);
                return Err(Stop::Failed(
                    Failure::Permanent,
                    format!(
                        "the file runs {:.0} s where the upload said {:.0} s",
                        probed.duration, found.duration
                    ),
                ));
            }
            Some(Err(reason)) => {
                let _ = std::fs::remove_file(&part);
                return Err(Stop::Failed(Failure::Transient, reason));
            }
            None => {}
        }
        std::fs::rename(&part, &target).map_err(|err| {
            Stop::Failed(Failure::Transient, format!("could not finish the video file: {err}"))
        })?;
        self.db.video_cache_ready(id, ceiling, total);
        self.shared.cache.put(
            id,
            ceiling,
            Cached {
                path: target,
                height,
                codec: stream.codec,
                bytes: total,
            },
        );
        self.breaker.succeeded();
        crate::logger::info(
            "precache",
            &format!(
                "prepared {id} for \u{201c}{}\u{201d}: {height}p {}, {:.1} MB",
                track.title,
                stream.codec.map(|codec| codec.label()).unwrap_or("video"),
                total as f64 / 1_000_000.0
            ),
        );
        self.refresh_status();
        Ok(())
    }

    fn record_failure(&mut self, video_id: &str, ceiling: i32, class: Failure, message: &str) {
        let attempts = self
            .db
            .video_cache_entry(video_id, ceiling)
            .map_or(0, |row| row.attempts)
            + 1;
        let delay = retry_delay_seconds(class, attempts, rand::random::<f64>());
        self.db.video_cache_failed(
            video_id,
            ceiling,
            class.id(),
            message,
            now_unix() + delay,
            now_unix(),
        );
        if matches!(class, Failure::NotFound | Failure::Permanent) {
            self.remove_files(video_id, ceiling);
        }
        self.breaker.failed(class);
        crate::logger::warn(
            "precache",
            &format!("{video_id} not prepared ({}): {message}; trying again in {delay} s", class.id()),
        );
    }

    /// Other containers' partial files for the same video would never resume.
    fn clear_other_parts(&self, video_id: &str, ceiling: i32, keep: &str) {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if let Some((id, entry_ceiling, _)) = parse_cache_name(&name) {
                if id == video_id
                    && entry_ceiling == ceiling
                    && name != keep
                    && name != format!("{keep}.part")
                {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
    }

    fn remove_files(&self, video_id: &str, ceiling: i32) {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if parse_cache_name(&name).is_some_and(|(id, c, _)| id == video_id && c == ceiling) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }

    fn forget(&mut self, video_id: &str, ceiling: i32) {
        self.shared.cache.remove(video_id, ceiling);
        self.remove_files(video_id, ceiling);
        self.db.video_cache_delete(video_id, ceiling);
        self.refresh_status();
    }

    fn clear(&mut self) {
        for row in self.db.video_cache_all() {
            if !row.pinned {
                self.forget(&row.video_id, row.ceiling);
            }
        }
    }

    /// The files the cache holds, as the planner weighs them: how likely a
    /// song that uses each is to play soon, and how long since it was made or
    /// played. The file being fetched is left out.
    fn held(&self, own_id: &str, own_ceiling: i32, context: &Context) -> Vec<Held> {
        let now = now_unix();
        self.db
            .video_cache_all()
            .into_iter()
            .filter(|row| row.bytes > 0 && !(row.video_id == own_id && row.ceiling == own_ceiling))
            .map(|row| Held {
                id: format!("{}|{}", row.video_id, row.ceiling),
                bytes: row.bytes,
                pinned: row.pinned,
                chance: if row.ceiling == own_ceiling {
                    context.chances.get(&row.video_id).copied().unwrap_or(0.0)
                } else {
                    0.0
                },
                age_seconds: now - row.created_at.max(row.last_played_at.unwrap_or(0)),
            })
            .collect()
    }

    /// For each matched video, the best chance any song using it has.
    fn chances_by_video(&self, ranked: &[Ranked]) -> HashMap<String, f64> {
        let mut by_song: HashMap<(&str, &str), f64> = HashMap::new();
        for entry in ranked {
            let chance = chance_of_play(&entry.candidate);
            if chance > 0.0 {
                let slot = by_song
                    .entry((entry.track.title.as_str(), entry.track.artist.as_str()))
                    .or_insert(0.0);
                *slot = slot.max(chance);
            }
        }
        let mut chances: HashMap<String, f64> = HashMap::new();
        for (title, artist, video_id) in self.db.music_video_matches() {
            if let Some(chance) = by_song.get(&(title.as_str(), artist.as_str())) {
                let slot = chances.entry(video_id).or_insert(0.0);
                *slot = slot.max(*chance);
            }
        }
        chances
    }

    fn refresh_status(&self) {
        let (files, bytes) = self.db.video_cache_totals();
        let cap = self.cap_bytes;
        status::update(|status| {
            status.video_files = files;
            status.video_bytes = bytes;
            status.video_cap_bytes = cap;
        });
    }

    /// Brings the index and the database back in line with the folder after
    /// whatever the last session left: finished files are trusted only at
    /// their recorded size, partial ones are kept to resume, and files no
    /// row speaks for are removed.
    fn reconcile(&mut self) {
        let _ = std::fs::create_dir_all(&self.dir);
        let mut known: HashSet<String> = HashSet::new();
        for row in self.db.video_cache_all() {
            if row.file_name.is_empty() {
                continue;
            }
            let target = self.dir.join(&row.file_name);
            let part = self.dir.join(format!("{}.part", row.file_name));
            let target_size = std::fs::metadata(&target).map(|meta| meta.len()).ok();
            let part_exists = part.is_file();
            match row.state.as_str() {
                STATE_READY if target_size == Some(row.bytes) => {
                    self.shared.cache.put(
                        &row.video_id,
                        row.ceiling,
                        Cached {
                            path: target,
                            height: row.height,
                            codec: codec_from_label(&row.codec),
                            bytes: row.bytes,
                        },
                    );
                    known.insert(row.file_name.clone());
                }
                STATE_PART if part_exists => {
                    known.insert(format!("{}.part", row.file_name));
                }
                STATE_PART if row.expected_bytes > 0 && target_size == Some(row.expected_bytes) => {
                    self.db.video_cache_ready(&row.video_id, row.ceiling, row.expected_bytes);
                    self.shared.cache.put(
                        &row.video_id,
                        row.ceiling,
                        Cached {
                            path: target,
                            height: row.height,
                            codec: codec_from_label(&row.codec),
                            bytes: row.expected_bytes,
                        },
                    );
                    known.insert(row.file_name.clone());
                }
                STATE_FAILED => {}
                _ => self.db.video_cache_delete(&row.video_id, row.ceiling),
            }
        }
        if let Ok(entries) = std::fs::read_dir(&self.dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if parse_cache_name(&name).is_some() && !known.contains(&name) {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
        self.refresh_status();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_lanes_own_names_are_recognised() {
        assert_eq!(
            parse_cache_name("dQw4w9WgXcQ.720.webm"),
            Some(("dQw4w9WgXcQ".to_string(), 720, false))
        );
        assert_eq!(
            parse_cache_name("dQw4w9WgXcQ.1080.mp4.part"),
            Some(("dQw4w9WgXcQ".to_string(), 1080, true))
        );
        assert_eq!(parse_cache_name("dQw4w9WgXcQ.m4a"), None);
        assert_eq!(parse_cache_name("dQw4w9WgXcQ.720.txt"), None);
        assert_eq!(parse_cache_name("short.720.webm"), None);
        assert_eq!(parse_cache_name("dQw4w9WgXcQ.high.webm"), None);
        assert_eq!(parse_cache_name("flaccy-MLNVX3"), None);
        assert_eq!(parse_cache_name("dQw4w9WgXcQ.720.webm.bak"), None);
    }

    #[test]
    fn messages_are_sorted_by_whether_to_keep_asking() {
        assert_eq!(classify_text("HTTP Error 429: Too Many Requests"), Failure::Throttled);
        assert_eq!(
            classify_text("YouTube blocked the request — updating yt-dlp usually fixes this"),
            Failure::Blocked
        );
        assert_eq!(classify_text("yt-dlp isn't installed — install it"), Failure::Blocked);
        assert_eq!(classify_text("Video unavailable"), Failure::NotFound);
        assert_eq!(classify_text("timed out"), Failure::Transient);
    }

    #[test]
    fn a_codec_label_finds_its_codec() {
        assert_eq!(codec_from_label("AV1"), Some(Codec::Av1));
        assert_eq!(codec_from_label("H.264"), Some(Codec::H264));
        assert_eq!(codec_from_label(""), None);
    }

    use super::super::test_server::{payload, scratch, serve, Mode};
    use crate::db::Db;

    const TB: u64 = 1_000_000_000_000;

    fn roomy(_: &Path) -> (u64, u64) {
        (TB, 2 * TB)
    }

    struct Rig {
        lane: Lane,
        shared: Arc<Shared>,
        dir: PathBuf,
    }

    fn rig(name: &str) -> Rig {
        let dir = scratch(name);
        let db_path = dir.join("library.sqlite");
        let (lane_tx, lane_rx) = async_channel::unbounded::<Msg>();
        let (response_tx, _responses) = async_channel::unbounded::<Response>();
        let shared = Arc::new(Shared {
            db_path: db_path.clone(),
            root: dir.clone(),
            latest: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            codecs: Vec::new(),
            streams: Mutex::new(HashMap::new()),
            searches: Mutex::new(HashMap::new()),
            prefetching: Mutex::new(None),
            prefetched: std::sync::Condvar::new(),
            aligning: Mutex::new(HashSet::new()),
            responses: response_tx,
            cache: Index::default(),
            lane: lane_tx,
            preempt: std::sync::atomic::AtomicBool::new(false),
        });
        let videos = dir.join("videos");
        std::fs::create_dir_all(&videos).unwrap();
        let lane = Lane {
            shared: Arc::clone(&shared),
            db: Db::open(&db_path).expect("temp db opens"),
            dir: videos.clone(),
            breaker: Breaker::default(),
            rx: lane_rx,
            inbox: VecDeque::new(),
            cap_bytes: 10 * TB,
            space: roomy,
        };
        Rig { lane, shared, dir: videos }
    }

    fn video_bytes(dir: &Path) -> Option<Vec<u8>> {
        let ffmpeg = crate::downloads::resolve_tool("ffmpeg")?;
        crate::downloads::resolve_tool("ffprobe")?;
        let file = dir.join("source.mp4");
        let made = std::process::Command::new(ffmpeg)
            .args(["-v", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=64x48:rate=10"])
            .args(["-c:v", "mpeg4", "-y"])
            .arg(&file)
            .status()
            .ok()?;
        made.success().then(|| std::fs::read(&file).ok()).flatten()
    }

    fn matched(id: &str, duration: f64) -> VideoMatch {
        super::super::build_match(
            &crate::musicvideo::Candidate {
                id: id.to_string(),
                title: "A Song".into(),
                channel: "An Artist".into(),
                duration,
                view_count: None,
                live_now: false,
            },
            "test",
        )
    }

    fn stream_at(url: &str) -> Stream {
        Stream {
            url: format!("{url}?mime=video%2Fmp4"),
            expires_at: i64::MAX,
            height: 48,
            codec: None,
        }
    }

    fn track() -> Track {
        Track {
            id: 1,
            rel_path: "a/song.flac".to_string(),
            title: "A Song".to_string(),
            artist: "An Artist".to_string(),
            album: "An Album".to_string(),
            album_artist: None,
            track_number: 1,
            duration: 2.0,
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

    fn hold(rig: &Rig, id: &str, bytes: u64, age_days: i64) {
        let name = format!("{id}.720.mp4");
        std::fs::write(rig.dir.join(&name), payload(bytes as usize)).unwrap();
        let created = now_unix() - age_days * 86_400;
        rig.lane.db.video_cache_progress(id, 720, 720, "AV1", &name, bytes, bytes, created);
        rig.lane.db.video_cache_ready(id, 720, bytes);
    }

    #[test]
    fn a_video_is_fetched_checked_and_then_served_from_the_disk() {
        let mut rig = rig("fetch");
        let Some(body) = video_bytes(&rig.dir) else { return };
        let stub = serve(Mode::Serve, body.clone());
        let found = matched("abcdefghijk", 2.0);
        let context = Context { chances: HashMap::new() };
        let outcome = rig.lane.download_once(&found, &stream_at(&stub.url), 720, 0.9, &track(), &context);
        assert!(outcome.is_ok(), "{outcome:?}");
        let stream = rig.shared.cached_stream("abcdefghijk", 720).expect("the file is indexed");
        assert!(stream.url.starts_with("file://"), "{}", stream.url);
        assert_eq!(stream.expires_at, i64::MAX);
        let on_disk = std::fs::read(rig.dir.join("abcdefghijk.720.mp4")).unwrap();
        assert_eq!(on_disk, body);
        assert!(!rig.dir.join("abcdefghijk.720.mp4.part").exists());
        let row = rig.lane.db.video_cache_entry("abcdefghijk", 720).unwrap();
        assert_eq!((row.state.as_str(), row.bytes), (STATE_READY, body.len() as u64));
        assert!(rig.shared.cached_stream("abcdefghijk", 1080).is_none());
    }

    #[test]
    fn bytes_that_are_not_a_video_never_become_a_cached_file() {
        let mut rig = rig("garbage");
        if download::probe(&rig.dir.join("none")).is_none() {
            return;
        }
        let stub = serve(Mode::Serve, payload(4000));
        let found = matched("abcdefghijk", 2.0);
        let context = Context { chances: HashMap::new() };
        let outcome = rig.lane.download_once(&found, &stream_at(&stub.url), 720, 0.9, &track(), &context);
        assert!(matches!(outcome, Err(Stop::Failed(Failure::Transient, _))), "{outcome:?}");
        assert!(rig.shared.cached_stream("abcdefghijk", 720).is_none());
        assert!(!rig.dir.join("abcdefghijk.720.mp4").exists());
        assert!(!rig.dir.join("abcdefghijk.720.mp4.part").exists());
    }

    #[test]
    fn a_file_that_has_gone_missing_stops_being_served_and_is_forgotten() {
        let mut rig = rig("vanish");
        let Some(body) = video_bytes(&rig.dir) else { return };
        let stub = serve(Mode::Serve, body);
        let found = matched("abcdefghijk", 2.0);
        let context = Context { chances: HashMap::new() };
        rig.lane
            .download_once(&found, &stream_at(&stub.url), 720, 0.9, &track(), &context)
            .expect("fetched");
        std::fs::remove_file(rig.dir.join("abcdefghijk.720.mp4")).unwrap();
        assert!(rig.shared.cached_stream("abcdefghijk", 720).is_none());
        let Ok(Msg::Lost { video_id, ceiling }) = rig.lane.rx.try_recv() else {
            panic!("the lane was not told");
        };
        rig.lane.forget(&video_id, ceiling);
        assert!(rig.lane.db.video_cache_entry("abcdefghijk", 720).is_none());
    }

    #[test]
    fn a_full_cache_drops_the_oldest_unwanted_file_to_fit_a_likelier_one() {
        let mut rig = rig("evict");
        let Some(body) = video_bytes(&rig.dir) else { return };
        let size = body.len() as u64;
        hold(&rig, "oldoldold01", 1000, 9);
        hold(&rig, "newernewer2", 1000, 3);
        rig.lane.cap_bytes = size + 1500;
        let stub = serve(Mode::Serve, body);
        let found = matched("abcdefghijk", 2.0);
        let context = Context { chances: HashMap::new() };
        rig.lane
            .download_once(&found, &stream_at(&stub.url), 720, 0.9, &track(), &context)
            .expect("fetched");
        assert!(!rig.dir.join("oldoldold01.720.mp4").exists());
        assert!(rig.lane.db.video_cache_entry("oldoldold01", 720).is_none());
        assert!(rig.dir.join("newernewer2.720.mp4").exists());
        assert!(rig.shared.cached_stream("abcdefghijk", 720).is_some());
    }

    #[test]
    fn a_cache_of_likely_or_fresh_files_leaves_a_newcomer_without_room() {
        let mut rig = rig("noroom");
        let Some(body) = video_bytes(&rig.dir) else { return };
        let size = body.len() as u64;
        hold(&rig, "likelylikel", 1000, 9);
        hold(&rig, "freshfresh01", 1000, 0);
        rig.lane.cap_bytes = size + 1500;
        let stub = serve(Mode::Serve, body);
        let found = matched("abcdefghijk", 2.0);
        let context = Context {
            chances: HashMap::from([("likelylikel".to_string(), 0.8)]),
        };
        let outcome = rig.lane.download_once(&found, &stream_at(&stub.url), 720, 0.9, &track(), &context);
        assert!(matches!(outcome, Err(Stop::NoRoom { .. })), "{outcome:?}");
        assert!(rig.dir.join("likelylikel.720.mp4").exists());
        assert!(rig.dir.join("freshfresh01.720.mp4").exists());
        assert!(!rig.dir.join("abcdefghijk.720.mp4.part").exists());
    }

    #[test]
    fn a_disk_nearly_full_shrinks_the_budget_below_the_cap() {
        fn cramped(_: &Path) -> (u64, u64) {
            (6_000_000_000, 100_000_000_000)
        }
        let mut rig = rig("floor");
        let Some(body) = video_bytes(&rig.dir) else { return };
        rig.lane.space = cramped;
        let stub = serve(Mode::Serve, body);
        let found = matched("abcdefghijk", 2.0);
        let context = Context { chances: HashMap::new() };
        let outcome = rig.lane.download_once(&found, &stream_at(&stub.url), 720, 0.9, &track(), &context);
        assert!(outcome.is_ok(), "{outcome:?}");
        fn full(_: &Path) -> (u64, u64) {
            (4_000_000_000, 100_000_000_000)
        }
        rig.lane.space = full;
        let found = matched("lmnopqrstuv", 2.0);
        let outcome = rig.lane.download_once(&found, &stream_at(&stub.url), 720, 0.9, &track(), &context);
        assert!(matches!(outcome, Err(Stop::NoRoom { .. })), "{outcome:?}");
    }

    #[test]
    fn a_restart_trusts_whole_files_resumes_partial_ones_and_sweeps_the_rest() {
        let mut rig = rig("reconcile");
        let dir = rig.dir.clone();
        hold(&rig, "goodgoodgo1", 500, 5);
        hold(&rig, "missingmis2", 500, 5);
        std::fs::remove_file(dir.join("missingmis2.720.mp4")).unwrap();
        hold(&rig, "wrongsize03", 500, 5);
        std::fs::write(dir.join("wrongsize03.720.mp4"), payload(10)).unwrap();
        rig.lane.db.video_cache_progress("partpartpa4", 720, 720, "AV1", "partpartpa4.720.mp4", 300, 900, now_unix());
        std::fs::write(dir.join("partpartpa4.720.mp4.part"), payload(300)).unwrap();
        rig.lane.db.video_cache_progress("crashcrash5", 720, 720, "AV1", "crashcrash5.720.mp4", 900, 900, now_unix());
        std::fs::write(dir.join("crashcrash5.720.mp4"), payload(900)).unwrap();
        rig.lane.db.video_cache_failed("failedfail6", 720, "blocked", "refused", now_unix() + 600, now_unix());
        std::fs::write(dir.join("orphanorph7.720.webm"), payload(50)).unwrap();
        std::fs::write(dir.join("orphanorph7.720.webm.part"), payload(50)).unwrap();
        std::fs::write(dir.join("goodgoodgo1.m4a"), payload(50)).unwrap();
        std::fs::write(dir.join("notes.txt"), "keep").unwrap();

        rig.lane.reconcile();

        assert!(rig.shared.cache.get("goodgoodgo1", 720).is_some());
        assert!(rig.shared.cache.get("missingmis2", 720).is_none());
        assert!(rig.lane.db.video_cache_entry("missingmis2", 720).is_none());
        assert!(rig.shared.cache.get("wrongsize03", 720).is_none());
        assert!(rig.lane.db.video_cache_entry("wrongsize03", 720).is_none());
        assert!(!dir.join("wrongsize03.720.mp4").exists());
        assert!(dir.join("partpartpa4.720.mp4.part").exists());
        assert_eq!(rig.lane.db.video_cache_entry("partpartpa4", 720).unwrap().state, STATE_PART);
        assert!(rig.shared.cache.get("crashcrash5", 720).is_some());
        assert_eq!(rig.lane.db.video_cache_entry("crashcrash5", 720).unwrap().state, STATE_READY);
        assert_eq!(rig.lane.db.video_cache_entry("failedfail6", 720).unwrap().state, STATE_FAILED);
        assert!(!dir.join("orphanorph7.720.webm").exists());
        assert!(!dir.join("orphanorph7.720.webm.part").exists());
        assert!(dir.join("goodgoodgo1.m4a").exists());
        assert!(dir.join("notes.txt").exists());
    }

    #[test]
    fn clearing_removes_every_prepared_file_except_pinned_ones() {
        let mut rig = rig("clear");
        hold(&rig, "clearclear1", 100, 5);
        hold(&rig, "pinnedpinn2", 100, 5);
        rig.lane.db.video_cache_set_pinned("pinnedpinn2", 720, true);
        rig.lane.reconcile();
        rig.lane.clear();
        assert!(rig.shared.cache.get("clearclear1", 720).is_none());
        assert!(!rig.dir.join("clearclear1.720.mp4").exists());
        assert!(rig.shared.cache.get("pinnedpinn2", 720).is_some());
        assert!(rig.dir.join("pinnedpinn2.720.mp4").exists());
    }
}
