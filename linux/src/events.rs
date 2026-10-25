use crate::library::Track;
use crate::load_progress::LoadProgress;
use crate::player::RepeatMode;
use flaccy_shared::enrichment_job::JobProgress;
use std::cell::RefCell;
use std::rc::Rc;

#[allow(dead_code)]
pub enum AppEvent {
    LibraryReloaded,
    ScanStarted,
    ScanProgress(LoadProgress),
    ScanFinished {
        added: usize,
        removed: usize,
    },
    TrackChanged(Option<Track>),
    NaturalEnd(Track),
    PlayingChanged(bool),
    Tick {
        position: f64,
        duration: f64,
    },
    Seeked(f64),
    ShuffleChanged(bool),
    RepeatChanged(RepeatMode),
    VolumeChanged(f64),
    LovedChanged {
        rel_path: String,
        loved: bool,
    },
    LastFmChanged,
    /// The scan recognised a new version of the song that is playing: the file
    /// the player has open is the old one, so the person is offered the new mix
    /// from the start.
    NewMixPlaying {
        rel_path: String,
        title: String,
    },
    SearchChanged(String),
    /// Ctrl+J: bring the playing song into view in the Songs table.
    LocateCurrent,
    /// The Songs table changed what its columns count (the Plays column moved
    /// to or from a time range); every visible cell re-reads its text.
    SongCellsChanged,
    /// The compositor suspended the window (minimized, on another workspace) or
    /// brought it back. Anything that wakes on a timer to keep a picture moving
    /// stops while it is suspended and picks up again on resume.
    WindowSuspended(bool),
    LyricsToggled(bool),
    QueueChanged,
    Toast(String),
    QueueToggled(bool),
    SleepTimerChanged {
        remaining_seconds: Option<i64>,
        end_of_track: bool,
    },
    AlbumEnriched {
        title: String,
        artist: String,
    },
    /// The person chose a cover for this (title, artist) or went back to the
    /// original. Sent once per key the cover is stored under, after the
    /// artwork cache has dropped everything it held for that key, so every
    /// surface that asks again gets the new picture.
    AlbumArtworkChanged {
        title: String,
        artist: String,
    },
    /// Albums whose embedded cover the tag pass just committed, batched per
    /// insert chunk. This is what fuels the Debut's mosaic while the scan is
    /// still reading, rather than all at once when the first build lands.
    AlbumCoversHoisted(Vec<(String, String)>),
    /// The durable enrichment job, reported as a countdown read from the
    /// database — never as a fraction, because the work is unbounded.
    EnrichmentProgress(JobProgress),
    HistoryImport {
        imported: usize,
        page: u32,
        total_pages: u32,
        done: bool,
    },
    SampleDownload {
        text: String,
        done: bool,
        failed: bool,
    },
    WantlistChanged,
    WantlistSeen,
    DownloadsChanged,
    DownloadProgress {
        id: i64,
        fraction: f64,
    },
    MusicVideoChanged,
    MusicVideoCandidates,
    /// The equalizer's saved state, the profile in force or whether it is
    /// running changed.
    EqualizerChanged,
    /// The default audio output changed. `profile_name` is set only when the
    /// new output keeps a profile of its own.
    EqualizerOutputChanged {
        output_name: String,
        profile_name: Option<String>,
    },
}

type Subscriber = Rc<dyn Fn(&AppEvent) -> bool>;

#[derive(Default)]
pub struct EventHub {
    subscribers: RefCell<Vec<Subscriber>>,
}

impl EventHub {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn subscribe(&self, callback: impl Fn(&AppEvent) -> bool + 'static) {
        self.subscribers.borrow_mut().push(Rc::new(callback));
    }

    /// Subscribes a widget-bound handler; the subscription self-prunes once the
    /// widget is dropped, so pushed pages never leak through the hub.
    pub fn subscribe_widget<W: gtk::glib::object::ObjectType>(
        &self,
        widget: &W,
        callback: impl Fn(&W, &AppEvent) + 'static,
    ) {
        let weak = gtk::glib::object::ObjectExt::downgrade(widget);
        self.subscribe(move |event| match weak.upgrade() {
            Some(widget) => {
                callback(&widget, event);
                true
            }
            None => false,
        });
    }

    pub fn emit(&self, event: &AppEvent) {
        let snapshot: Vec<Subscriber> = self.subscribers.borrow().clone();
        let mut dead: Vec<*const ()> = Vec::new();
        for subscriber in &snapshot {
            if !subscriber(event) {
                dead.push(Rc::as_ptr(subscriber) as *const ());
            }
        }
        if !dead.is_empty() {
            self.subscribers
                .borrow_mut()
                .retain(|s| !dead.contains(&(Rc::as_ptr(s) as *const ())));
        }
    }
}
