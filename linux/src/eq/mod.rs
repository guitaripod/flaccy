//! The equalizer on Linux: a GStreamer element that runs the shared float
//! kernel, an engine that owns the saved state and publishes what the element
//! should be doing, the output watcher that lets profiles follow the default
//! sink, and the JSON file the state lives in.
//!
//! The Apple clients put the same kernel behind an `MTAudioProcessingTap`;
//! here it sits in playbin3's `audio-filter` slot. With the equalizer off the
//! element is in true passthrough and buffers cross it untouched.
//!
//! The engine's surface is the one the equalizer screens are built on; until
//! they land, part of it has no caller, hence the `dead_code` allowance.

#![allow(dead_code)]

pub mod element;
pub mod engine;
pub mod exercise;
pub mod output;
pub mod store;

pub use engine::EqEngine;

use flaccy_library::server_sync::song_key_of;
use flaccy_shared::equalizer::profile::EqualizerBand;
use flaccy_shared::equalizer::spectrum::SpectrumAnalyzer;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::time::Instant;

/// The curve the streaming thread should be running, published by the engine.
/// Immutable once built; a new profile is a new value with a higher `version`.
pub struct EqConfig {
    pub version: u64,
    pub is_engaged: bool,
    pub bands: Vec<EqualizerBand>,
    pub preamp_db: f64,
    pub peak_guard: bool,
}

impl EqConfig {
    fn off() -> Self {
        Self {
            version: 0,
            is_engaged: false,
            bands: Vec::new(),
            preamp_db: 0.0,
            peak_guard: true,
        }
    }
}

/// The person's own song volumes, and which song each level belongs to: the
/// one being heard, and the one handed to playbin that is heard from its
/// stream start on.
#[derive(Default)]
struct SongLevels {
    levels: HashMap<String, i32>,
    heard: Option<String>,
    handed_over: Option<String>,
}

struct AnalysisSlot {
    rate: f64,
    samples: Vec<f32>,
    written: bool,
}

/// Everything the engine and the element share. The streaming thread only ever
/// tries the config lock and the analysis lock, so the main thread can never
/// make it wait.
pub struct EqShared {
    config: Mutex<Arc<EqConfig>>,
    analysis_requested: AtomicBool,
    block_peak_bits: AtomicU32,
    guard_reduced: AtomicBool,
    sample_rate: AtomicU32,
    channels: AtomicU32,
    frames_processed: AtomicU64,
    last_buffer_ns: AtomicU64,
    largest_gap_ns: AtomicU64,
    least_lead_ns: AtomicI64,
    analysis: Mutex<AnalysisSlot>,
    song_levels: Mutex<SongLevels>,
    level_heard: AtomicI32,
    epoch: Instant,
}

impl EqShared {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            config: Mutex::new(Arc::new(EqConfig::off())),
            analysis_requested: AtomicBool::new(false),
            block_peak_bits: AtomicU32::new(0),
            guard_reduced: AtomicBool::new(false),
            sample_rate: AtomicU32::new(0),
            channels: AtomicU32::new(0),
            frames_processed: AtomicU64::new(0),
            last_buffer_ns: AtomicU64::new(0),
            largest_gap_ns: AtomicU64::new(0),
            least_lead_ns: AtomicI64::new(i64::MAX),
            analysis: Mutex::new(AnalysisSlot {
                rate: 0.0,
                samples: vec![0.0; SpectrumAnalyzer::WINDOW_SIZE],
                written: false,
            }),
            song_levels: Mutex::new(SongLevels::default()),
            level_heard: AtomicI32::new(0),
            epoch: Instant::now(),
        })
    }

    pub fn publish(&self, config: EqConfig) {
        if let Ok(mut slot) = self.config.lock() {
            *slot = Arc::new(config);
        }
    }

    pub fn current(&self) -> Arc<EqConfig> {
        self.config
            .lock()
            .map(|slot| Arc::clone(&slot))
            .unwrap_or_else(|_| Arc::new(EqConfig::off()))
    }

    fn try_current(&self) -> Option<Arc<EqConfig>> {
        self.config.try_lock().ok().map(|slot| Arc::clone(&slot))
    }

    /// Replaces every song volume, as the library database holds them.
    pub fn set_song_levels(&self, levels: HashMap<String, i32>) {
        if let Ok(mut slot) = self.song_levels.lock() {
            slot.levels = levels;
            let heard = slot.level_of(slot.heard.as_deref());
            self.level_heard.store(heard, Ordering::Relaxed);
        }
    }

    /// One song's volume changed. The song being heard glides to it at once; the
    /// song already handed to playbin picks it up at its stream start.
    pub fn set_song_level(&self, title: &str, artist: &str, tenths: i32) {
        let key = song_key_of(title, artist);
        if let Ok(mut slot) = self.song_levels.lock() {
            if tenths == 0 {
                slot.levels.remove(&key);
            } else {
                slot.levels.insert(key.clone(), tenths);
            }
            if slot.heard.as_deref() == Some(key.as_str()) {
                self.level_heard.store(tenths, Ordering::Relaxed);
            }
        }
    }

    /// Called whenever playbin is given a song's URI, before it is: from that
    /// song's stream start on, its own volume is the one in force.
    pub fn hand_over(&self, title: &str, artist: &str) {
        let key = song_key_of(title, artist);
        if let Ok(mut slot) = self.song_levels.lock() {
            slot.handed_over = Some(key);
        }
    }

    /// The volume of the song being heard, in tenths of a decibel.
    pub fn level_heard(&self) -> i32 {
        self.level_heard.load(Ordering::Relaxed)
    }

    /// A stream started: the song handed over last is now the one heard. Answers
    /// its level, or `None` when no song was handed over since the last start.
    fn begin_song(&self) -> Option<i32> {
        let mut slot = self.song_levels.lock().ok()?;
        let key = slot.handed_over.take()?;
        let level = slot.level_of(Some(&key));
        slot.heard = Some(key);
        self.level_heard.store(level, Ordering::Relaxed);
        Some(level)
    }

    pub fn set_analysis_requested(&self, requested: bool) {
        self.analysis_requested.store(requested, Ordering::Relaxed);
    }

    fn analysis_requested(&self) -> bool {
        self.analysis_requested.load(Ordering::Relaxed)
    }

    fn now_ns(&self) -> u64 {
        self.epoch.elapsed().as_nanos() as u64 + 1
    }

    fn note_stream(&self, rate: u32, channels: u32) {
        self.sample_rate.store(rate, Ordering::Relaxed);
        self.channels.store(channels, Ordering::Relaxed);
    }

    fn note_buffer(&self, frames: usize, peak: f32, guard_reduced: bool) {
        let now = self.now_ns();
        let last = self.last_buffer_ns.swap(now, Ordering::Relaxed);
        if last != 0 {
            self.largest_gap_ns
                .fetch_max(now.saturating_sub(last), Ordering::Relaxed);
        }
        self.frames_processed
            .fetch_add(frames as u64, Ordering::Relaxed);
        self.block_peak_bits.store(peak.to_bits(), Ordering::Relaxed);
        self.guard_reduced.store(guard_reduced, Ordering::Relaxed);
    }

    fn forget_last_buffer(&self) {
        self.last_buffer_ns.store(0, Ordering::Relaxed);
    }

    fn record_analysis(&self, rate: f64, samples: &[f32]) {
        if let Ok(mut slot) = self.analysis.try_lock() {
            slot.rate = rate;
            slot.samples.copy_from_slice(samples);
            slot.written = true;
        }
    }

    pub fn frames_processed(&self) -> u64 {
        self.frames_processed.load(Ordering::Relaxed)
    }

    pub fn stream_format(&self) -> Option<(u32, u32)> {
        let rate = self.sample_rate.load(Ordering::Relaxed);
        (rate != 0).then(|| (rate, self.channels.load(Ordering::Relaxed)))
    }

    pub fn milliseconds_since_last_buffer(&self) -> Option<f64> {
        let last = self.last_buffer_ns.load(Ordering::Relaxed);
        (last != 0).then(|| self.now_ns().saturating_sub(last) as f64 / 1_000_000.0)
    }

    /// The longest pause between two processed buffers since the last call, in
    /// milliseconds, and the counter starts over.
    pub fn take_largest_gap_milliseconds(&self) -> f64 {
        self.largest_gap_ns.swap(0, Ordering::Relaxed) as f64 / 1_000_000.0
    }

    pub fn restart_gap_measure(&self) {
        self.largest_gap_ns.store(0, Ordering::Relaxed);
        self.least_lead_ns.store(i64::MAX, Ordering::Relaxed);
    }

    fn note_lead(&self, nanoseconds: i64) {
        self.least_lead_ns.fetch_min(nanoseconds, Ordering::Relaxed);
    }

    /// The smallest distance, in milliseconds, between the end of a processed
    /// buffer and the moment the pipeline clock plays it, since the last
    /// restart. It reaches zero or below only when audio arrives too late to be
    /// heard on time, which is what an audible gap is.
    pub fn least_lead_milliseconds(&self) -> Option<f64> {
        match self.least_lead_ns.load(Ordering::Relaxed) {
            i64::MAX => None,
            nanoseconds => Some(nanoseconds as f64 / 1_000_000.0),
        }
    }

    fn peak_and_guard(&self) -> (f32, bool) {
        (
            f32::from_bits(self.block_peak_bits.load(Ordering::Relaxed)),
            self.guard_reduced.load(Ordering::Relaxed),
        )
    }

    fn copy_analysis_into(&self, output: &mut [f32]) -> Option<f64> {
        let slot = self.analysis.lock().ok()?;
        if !slot.written {
            return None;
        }
        output.copy_from_slice(&slot.samples);
        Some(slot.rate)
    }
}

impl SongLevels {
    fn level_of(&self, key: Option<&str>) -> i32 {
        key.and_then(|key| self.levels.get(key)).copied().unwrap_or(0)
    }
}

/// Registers the `flaccyeq` element with GStreamer. Safe to call repeatedly.
pub fn register() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        if let Err(err) = element::register() {
            crate::logger::error("playback", &format!("equalizer element registration failed: {err}"));
        }
    });
}
