use crate::library::Track;
use crate::player::RepeatMode;
use std::cell::RefCell;
use std::rc::Rc;

#[allow(dead_code)]
pub enum AppEvent {
    LibraryReloaded,
    ScanStarted,
    ScanProgress(usize, usize),
    ScanFinished { added: usize, removed: usize },
    TrackChanged(Option<Track>),
    NaturalEnd(Track),
    PlayingChanged(bool),
    Tick { position: f64, duration: f64 },
    Seeked(f64),
    ShuffleChanged(bool),
    RepeatChanged(RepeatMode),
    VolumeChanged(f64),
    LovedChanged { rel_path: String, loved: bool },
    LastFmChanged,
    SearchChanged(String),
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
    EnrichmentProgress {
        done: usize,
        total: usize,
    },
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
    DownloadProgress { id: i64, fraction: f64 },
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
