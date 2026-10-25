use crate::app::AppCore;
use crate::db::Db;
use crate::events::AppEvent;
use gtk::gdk;
use gtk::glib;
use gtk::prelude::*;
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const LRU_CAPACITY: usize = 300;

/// How many threads decode covers at once. Each has its own database
/// connection, so a Now Playing cover never waits behind one busy decode.
const WORKERS: usize = 3;
/// The longest side of the downscaled copy of a cover kept for the sizes asked
/// for next: it is at least as large as every size the app requests on a 3x
/// display (Now Playing is 340 points).
const BASE_SIDE: u32 = 1024;
/// How many downscaled covers are kept, newest request last.
const BASE_CAPACITY: usize = 8;
/// A cover asked for at this many points or more is the page the person is
/// looking at, not a tile in a list, and is decoded before any tile.
const URGENT_LOGICAL_SIZE: u32 = 300;
/// The shortest gap between two looks through the waiting requests for ones
/// whose widget has gone.
const SWEEP_INTERVAL: Duration = Duration::from_millis(100);
/// Fewer queued decodes than this are not worth a look through the waiting
/// requests: they will be done before the next frame matters.
const SWEEP_MIN_QUEUED: usize = 16;
/// The side of the placeholder texture. The gradient is a straight diagonal
/// ramp, so GTK's linear scaling of a small texture reproduces it.
const PLACEHOLDER_SIDE: u32 = 64;
/// The side the placeholder gradient used to be rendered at; its ramp is
/// defined in these pixels.
const PLACEHOLDER_REFERENCE_SIDE: u32 = 160;
/// The placeholder hue is the seed hash modulo this, so there are only this
/// many distinct placeholders.
const PLACEHOLDER_HUES: u64 = 360;

/// The longest side of a backdrop texture. The picture showing it is scaled
/// up to a whole window, and the blur is already in the pixels, so a few
/// dozen texels per axis is all the detail there is to keep.
const BACKDROP_SIDE: u32 = 96;
/// How much of the cover's centre a backdrop keeps, as a fraction of each
/// side: the page used to scale its blurred cover up by a quarter so the soft
/// edges fell outside the window, and this is that framing.
const BACKDROP_CROP: f64 = 0.8;
/// The Gaussian spread, in texels of the backdrop, matching the 64 px blur the
/// stylesheet used to ask the GPU for on a window-sized copy of the cover.
const BACKDROP_SIGMA: f32 = 3.2;

/// What a decode produces: the cover itself, or the soft wash that sits
/// behind the Now Playing page.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Look {
    Cover,
    Backdrop,
}

/// Which queued decode a free worker takes first. Within one priority the
/// newest request goes first, because the tile just bound is the one on screen.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Priority {
    Tile,
    Urgent,
}

/// One texture asked of one album: a size of its cover or its backdrop.
#[derive(Clone, Debug)]
struct Want {
    key: String,
    size: u32,
    look: Look,
    priority: Priority,
}

/// Every texture currently wanted from one album, decoded from a single read
/// of its cover.
#[derive(Clone, Debug)]
struct Job {
    album: String,
    title: String,
    artist: String,
    generation: u64,
    priority: Priority,
    sequence: u64,
    wants: Vec<Want>,
}

impl Job {
    /// The biggest cover size among the wants, which is how large a downscaled
    /// copy has to be to serve them all. A backdrop needs next to nothing.
    fn largest_cover(&self) -> u32 {
        self.wants
            .iter()
            .filter(|want| want.look == Look::Cover)
            .map(|want| want.size)
            .max()
            .unwrap_or(0)
    }
}

struct DecodeResult {
    key: String,
    title: String,
    artist: String,
    size: u32,
    look: Look,
    priority: Priority,
    generation: u64,
    width: u32,
    height: u32,
    rgba: Option<Vec<u8>>,
    dominant: Option<(u8, u8, u8)>,
}

impl DecodeResult {
    fn without_art(job: &Job, want: &Want) -> Self {
        Self {
            key: want.key.clone(),
            title: job.title.clone(),
            artist: job.artist.clone(),
            size: want.size,
            look: want.look,
            priority: want.priority,
            generation: job.generation,
            width: 0,
            height: 0,
            rgba: None,
            dominant: None,
        }
    }

    fn want(&self) -> Want {
        Want {
            key: self.key.clone(),
            size: self.size,
            look: self.look,
            priority: self.priority,
        }
    }
}

type Callback = Box<dyn Fn(Option<&gdk::MemoryTexture>, Option<(u8, u8, u8)>)>;
type Alive = Box<dyn Fn() -> bool>;

/// A caller waiting for a texture, and, when the caller said which widget the
/// texture is for, a way to tell that the widget is gone and the decode can be
/// skipped.
struct Waiter {
    callback: Callback,
    alive: Option<Alive>,
}

impl Waiter {
    fn abandoned(&self) -> bool {
        self.alive.as_ref().is_some_and(|alive| !alive())
    }
}

/// The decodes waiting for a worker, shared by the main thread, which adds,
/// merges and cancels, and the workers, which take the best one.
struct Queue {
    state: Mutex<QueueState>,
    ready: Condvar,
}

#[derive(Default)]
struct QueueState {
    jobs: Vec<Job>,
    in_flight: HashSet<String>,
    closed: bool,
    next_sequence: u64,
}

impl QueueState {
    /// The most urgent, then newest, job whose album no worker is reading.
    fn take_best(&mut self) -> Option<Job> {
        let index = self
            .jobs
            .iter()
            .enumerate()
            .filter(|(_, job)| !self.in_flight.contains(&job.album))
            .max_by_key(|(_, job)| (job.priority, job.sequence))
            .map(|(index, _)| index)?;
        let job = self.jobs.swap_remove(index);
        self.in_flight.insert(job.album.clone());
        Some(job)
    }
}

impl Queue {
    fn new() -> Self {
        Self {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, QueueState> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Adds a texture to the album's waiting job, or starts one. A job that no
    /// worker has begun reads the cover when it does, so it takes the current
    /// generation and moves ahead of older requests.
    fn push(&self, title: &str, artist: &str, generation: u64, want: Want) {
        let album = album_id(title, artist);
        let mut state = self.lock();
        let sequence = state.next_sequence;
        state.next_sequence += 1;
        match state.jobs.iter_mut().find(|job| job.album == album) {
            Some(job) => {
                job.generation = generation;
                job.sequence = sequence;
                job.priority = job.priority.max(want.priority);
                if !job.wants.iter().any(|queued| queued.key == want.key) {
                    job.wants.push(want);
                }
            }
            None => state.jobs.push(Job {
                album,
                title: title.to_string(),
                artist: artist.to_string(),
                generation,
                priority: want.priority,
                sequence,
                wants: vec![want],
            }),
        }
        drop(state);
        self.ready.notify_one();
    }

    fn refresh_generation(&self, album: &str, generation: u64) {
        for job in self.lock().jobs.iter_mut().filter(|job| job.album == album) {
            job.generation = generation;
        }
    }

    /// Removes the wanted textures that no worker has begun and returns their
    /// keys; a decode already running finishes and is cached.
    fn cancel(&self, keys: &HashSet<String>) -> Vec<String> {
        let mut removed = Vec::new();
        let mut state = self.lock();
        for job in state.jobs.iter_mut() {
            job.wants.retain(|want| {
                let cancel = keys.contains(&want.key);
                if cancel {
                    removed.push(want.key.clone());
                }
                !cancel
            });
        }
        state.jobs.retain(|job| !job.wants.is_empty());
        removed
    }

    fn len(&self) -> usize {
        self.lock().jobs.len()
    }

    fn pop(&self) -> Option<Job> {
        let mut state = self.lock();
        loop {
            if state.closed {
                return None;
            }
            if let Some(job) = state.take_best() {
                return Some(job);
            }
            state = self
                .ready
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }

    fn finish(&self, album: &str) {
        self.lock().in_flight.remove(album);
        self.ready.notify_all();
    }

    fn close(&self) {
        self.lock().closed = true;
        self.ready.notify_all();
    }
}

/// A few covers kept at a size the app can serve every texture from, so the
/// sizes asked for one after another for the same album are decoded once.
struct BaseCache {
    entries: Mutex<VecDeque<BaseEntry>>,
}

struct BaseEntry {
    album: String,
    generation: u64,
    longest: u32,
    original: bool,
    image: Arc<image::DynamicImage>,
}

impl BaseCache {
    fn new() -> Self {
        Self {
            entries: Mutex::new(VecDeque::new()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, VecDeque<BaseEntry>> {
        self.entries.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The kept copy of the album's cover, if it was read at this generation
    /// and is at least `needed` pixels on its longest side or is the whole
    /// cover already.
    fn get(&self, album: &str, generation: u64, needed: u32) -> Option<Arc<image::DynamicImage>> {
        let mut entries = self.lock();
        let index = entries.iter().position(|entry| {
            entry.album == album
                && entry.generation == generation
                && (entry.original || entry.longest >= needed)
        })?;
        let entry = entries.remove(index)?;
        let image = Arc::clone(&entry.image);
        entries.push_back(entry);
        Some(image)
    }

    fn put(&self, entry: BaseEntry) {
        let mut entries = self.lock();
        if entries
            .iter()
            .any(|kept| kept.album == entry.album && kept.generation > entry.generation)
        {
            return;
        }
        entries.retain(|kept| kept.album != entry.album);
        entries.push_back(entry);
        while entries.len() > BASE_CAPACITY {
            entries.pop_front();
        }
    }

    fn forget(&self, album: &str) {
        self.lock().retain(|entry| entry.album != album);
    }
}

/// Which texture was used when, in constant time per use: a stamp per key and
/// the keys in stamp order.
#[derive(Default)]
struct Recency {
    stamps: HashMap<String, u64>,
    order: BTreeMap<u64, String>,
    next_stamp: u64,
}

impl Recency {
    fn touch(&mut self, key: &str) {
        let stamp = self.next_stamp;
        self.next_stamp += 1;
        if let Some(old) = self.stamps.insert(key.to_string(), stamp) {
            self.order.remove(&old);
        }
        self.order.insert(stamp, key.to_string());
    }

    fn pop_oldest(&mut self) -> Option<String> {
        let (_, key) = self.order.pop_first()?;
        self.stamps.remove(&key);
        Some(key)
    }

    fn forget_prefix(&mut self, prefix: &str) {
        self.stamps.retain(|key, _| !key.starts_with(prefix));
        self.order.retain(|_, key| !key.starts_with(prefix));
    }

    fn len(&self) -> usize {
        self.stamps.len()
    }
}

pub struct ArtworkCache {
    db_path: PathBuf,
    textures: RefCell<HashMap<String, (gdk::MemoryTexture, Option<(u8, u8, u8)>)>>,
    lru: RefCell<Recency>,
    misses: RefCell<HashSet<String>>,
    pending: RefCell<HashMap<String, Vec<Waiter>>>,
    generations: RefCell<HashMap<String, u64>>,
    placeholders: RefCell<HashMap<u64, gdk::MemoryTexture>>,
    queue: Arc<Queue>,
    bases: Arc<BaseCache>,
    last_sweep: Cell<Option<Instant>>,
}

impl Drop for ArtworkCache {
    fn drop(&mut self) {
        self.queue.close();
    }
}

impl ArtworkCache {
    pub fn new(db_path: PathBuf) -> Self {
        Self {
            db_path,
            textures: RefCell::new(HashMap::new()),
            lru: RefCell::new(Recency::default()),
            misses: RefCell::new(HashSet::new()),
            pending: RefCell::new(HashMap::new()),
            generations: RefCell::new(HashMap::new()),
            placeholders: RefCell::new(HashMap::new()),
            queue: Arc::new(Queue::new()),
            bases: Arc::new(BaseCache::new()),
            last_sweep: Cell::new(None),
        }
    }

    pub fn start(&self, core: &Rc<AppCore>) {
        let (res_tx, res_rx) = async_channel::unbounded::<DecodeResult>();
        for index in 0..WORKERS {
            let db_path = self.db_path.clone();
            let queue = Arc::clone(&self.queue);
            let bases = Arc::clone(&self.bases);
            let res_tx = res_tx.clone();
            std::thread::Builder::new()
                .name(format!("flaccy-artwork-{index}"))
                .spawn(move || decode_worker(db_path, queue, bases, res_tx))
                .ok();
        }
        drop(res_tx);

        let core = Rc::downgrade(core);
        glib::spawn_future_local(async move {
            while let Ok(result) = res_rx.recv().await {
                let Some(core) = core.upgrade() else { break };
                core.artwork.finish(result);
            }
        });
    }

    pub fn placeholder(&self, seed: &str) -> gdk::MemoryTexture {
        let hue = crate::palette::fnv1a_64(seed) % PLACEHOLDER_HUES;
        if let Some(texture) = self.placeholders.borrow().get(&hue) {
            return texture.clone();
        }
        let data = placeholder_texels(seed);
        let texture = gdk::MemoryTexture::new(
            PLACEHOLDER_SIDE as i32,
            PLACEHOLDER_SIDE as i32,
            gdk::MemoryFormat::R8g8b8a8,
            &glib::Bytes::from_owned(data),
            (PLACEHOLDER_SIDE * 4) as usize,
        );
        self.placeholders.borrow_mut().insert(hue, texture.clone());
        texture
    }

    /// Drops cached textures and negative-cache entries for one album so a
    /// freshly enriched or chosen cover is re-decoded on the next request, and
    /// bumps the album's generation so a decode already in flight — which may
    /// have read the old cover — is thrown away and redone when it lands.
    pub fn invalidate(&self, title: &str, artist: &str) {
        let album = album_id(title, artist);
        let generation = {
            let mut generations = self.generations.borrow_mut();
            let generation = generations.entry(album.clone()).or_insert(0);
            *generation += 1;
            *generation
        };
        self.bases.forget(&album);
        self.queue.refresh_generation(&album, generation);
        let prefix = format!("{title}|{artist}|");
        self.textures
            .borrow_mut()
            .retain(|key, _| !key.starts_with(&prefix));
        self.misses
            .borrow_mut()
            .retain(|key| !key.starts_with(&prefix));
        self.lru.borrow_mut().forget_prefix(&prefix);
    }

    fn generation(&self, title: &str, artist: &str) -> u64 {
        self.generations
            .borrow()
            .get(&album_id(title, artist))
            .copied()
            .unwrap_or(0)
    }

    /// Requests decoded album art; the callback fires immediately on cache hit,
    /// or later on the main loop after a worker decode. `None` means the album
    /// has no embedded art and the caller should keep its placeholder.
    pub fn request(
        &self,
        title: &str,
        artist: &str,
        size: u32,
        callback: impl Fn(Option<&gdk::MemoryTexture>, Option<(u8, u8, u8)>) + 'static,
    ) {
        self.request_cover(title, artist, size, Waiter {
            callback: Box::new(callback),
            alive: None,
        });
    }

    /// Like `request`, for art that only a given widget will show: if the
    /// widget is destroyed before a worker reaches the request, the decode is
    /// dropped instead of run for nobody.
    pub fn request_for(
        &self,
        widget: &impl IsA<gtk::Widget>,
        title: &str,
        artist: &str,
        size: u32,
        callback: impl Fn(Option<&gdk::MemoryTexture>, Option<(u8, u8, u8)>) + 'static,
    ) {
        let weak = widget.upcast_ref::<gtk::Widget>().downgrade();
        self.request_while(move || weak.upgrade().is_some(), title, artist, size, callback);
    }

    /// Like `request`, for art that is only wanted while `wanted` holds, such
    /// as a recycled grid tile that is still bound to this album: once it
    /// answers false, a decode no worker has reached yet is dropped.
    pub fn request_while(
        &self,
        wanted: impl Fn() -> bool + 'static,
        title: &str,
        artist: &str,
        size: u32,
        callback: impl Fn(Option<&gdk::MemoryTexture>, Option<(u8, u8, u8)>) + 'static,
    ) {
        self.request_cover(title, artist, size, Waiter {
            callback: Box::new(callback),
            alive: Some(Box::new(wanted)),
        });
    }

    fn request_cover(&self, title: &str, artist: &str, logical_size: u32, waiter: Waiter) {
        let size = logical_size * display_scale();
        let key = format!("{title}|{artist}|{size}");
        let priority = if logical_size >= URGENT_LOGICAL_SIZE {
            Priority::Urgent
        } else {
            Priority::Tile
        };
        let want = Want {
            key,
            size,
            look: Look::Cover,
            priority,
        };
        self.fetch(title, artist, want, waiter);
    }

    /// Requests the blurred wash behind an album's Now Playing page. It is
    /// blurred once, off the main thread, into a small texture, so the page
    /// paints it as one plain textured rectangle per frame instead of asking
    /// the GPU to blur a window-sized picture every time anything on the page
    /// moves. The key still starts with `title|artist|`, so invalidating the
    /// album drops it with the covers.
    pub fn request_backdrop(
        &self,
        title: &str,
        artist: &str,
        callback: impl Fn(Option<&gdk::MemoryTexture>) + 'static,
    ) {
        let want = Want {
            key: format!("{title}|{artist}|backdrop"),
            size: BACKDROP_SIDE,
            look: Look::Backdrop,
            priority: Priority::Urgent,
        };
        let waiter = Waiter {
            callback: Box::new(move |texture, _| callback(texture)),
            alive: None,
        };
        self.fetch(title, artist, want, waiter);
    }

    fn fetch(&self, title: &str, artist: &str, want: Want, waiter: Waiter) {
        let key = want.key.clone();
        if let Some((texture, dominant)) = self.textures.borrow().get(&key) {
            self.touch(&key);
            (waiter.callback)(Some(texture), *dominant);
            return;
        }
        if self.misses.borrow().contains(&key) {
            (waiter.callback)(None, None);
            return;
        }
        let mut pending = self.pending.borrow_mut();
        let entry = pending.entry(key).or_default();
        let first = entry.is_empty();
        entry.push(waiter);
        drop(pending);
        if first {
            self.drop_abandoned_if_due();
            self.queue
                .push(title, artist, self.generation(title, artist), want);
        }
    }

    /// Cancels the queued decodes that every waiter has given up on, at most
    /// once per `SWEEP_INTERVAL` and only when the backlog is long enough for
    /// it to matter. Waiters that never said which widget they serve are
    /// always presumed alive.
    fn drop_abandoned_if_due(&self) {
        let now = Instant::now();
        if let Some(last) = self.last_sweep.get() {
            if now.duration_since(last) < SWEEP_INTERVAL {
                return;
            }
        }
        self.last_sweep.set(Some(now));
        if self.queue.len() < SWEEP_MIN_QUEUED {
            return;
        }
        let abandoned: HashSet<String> = self
            .pending
            .borrow()
            .iter()
            .filter(|(_, waiters)| waiters.iter().all(Waiter::abandoned))
            .map(|(key, _)| key.clone())
            .collect();
        if abandoned.is_empty() {
            return;
        }
        let cancelled = self.queue.cancel(&abandoned);
        let dropped: Vec<Vec<Waiter>> = {
            let mut pending = self.pending.borrow_mut();
            cancelled.iter().filter_map(|key| pending.remove(key)).collect()
        };
        drop(dropped);
    }

    /// A decode that began before the album was invalidated may carry the old
    /// cover: it is not cached and nothing is told, the request is sent again
    /// and the waiting callbacks stay queued for the fresh answer.
    fn resend_if_stale(&self, result: &DecodeResult) -> bool {
        let current = self.generation(&result.title, &result.artist);
        if result.generation == current {
            return false;
        }
        self.queue
            .push(&result.title, &result.artist, current, result.want());
        true
    }

    fn finish(&self, result: DecodeResult) {
        if self.resend_if_stale(&result) {
            return;
        }
        let waiters = self.pending.borrow_mut().remove(&result.key);
        let texture = result.rgba.map(|rgba| {
            gdk::MemoryTexture::new(
                result.width as i32,
                result.height as i32,
                gdk::MemoryFormat::R8g8b8a8,
                &glib::Bytes::from_owned(rgba),
                (result.width * 4) as usize,
            )
        });
        match &texture {
            Some(texture) => {
                self.textures
                    .borrow_mut()
                    .insert(result.key.clone(), (texture.clone(), result.dominant));
                self.touch(&result.key);
                self.evict_if_needed();
            }
            None => {
                self.misses.borrow_mut().insert(result.key.clone());
            }
        }
        if let Some(waiters) = waiters {
            for waiter in waiters {
                (waiter.callback)(texture.as_ref(), result.dominant);
            }
        }
    }

    fn touch(&self, key: &str) {
        self.lru.borrow_mut().touch(key);
    }

    fn evict_if_needed(&self) {
        let mut lru = self.lru.borrow_mut();
        while lru.len() > LRU_CAPACITY {
            if let Some(oldest) = lru.pop_oldest() {
                self.textures.borrow_mut().remove(&oldest);
            }
        }
    }
}

/// The placeholder's ramp sampled at `PLACEHOLDER_SIDE` texel centres, each
/// placed where it falls on the `PLACEHOLDER_REFERENCE_SIDE` grid the gradient
/// is defined on, so scaling the texture up lands within a level of the old
/// full-size render.
fn placeholder_texels(seed: &str) -> Vec<u8> {
    let ((r1, g1, b1), (r2, g2, b2)) = crate::palette::placeholder_colors(seed);
    let scale = PLACEHOLDER_REFERENCE_SIDE as f64 / PLACEHOLDER_SIDE as f64;
    let span = (2 * (PLACEHOLDER_REFERENCE_SIDE - 1)) as f64;
    let reference_position = |index: u32| (index as f64 + 0.5) * scale - 0.5;
    let lerp = |a: u8, b: u8, t: f64| (a as f64 + (b as f64 - a as f64) * t).round() as u8;
    let mut data = Vec::with_capacity((PLACEHOLDER_SIDE * PLACEHOLDER_SIDE * 4) as usize);
    for y in 0..PLACEHOLDER_SIDE {
        for x in 0..PLACEHOLDER_SIDE {
            let t = ((reference_position(x) + reference_position(y)) / span).clamp(0.0, 1.0);
            data.extend_from_slice(&[lerp(r1, r2, t), lerp(g1, g2, t), lerp(b1, b2, t), 255]);
        }
    }
    data
}

/// Shows an album's cover in a picture and keeps it right: a cover chosen or
/// reset later repaints it, falling back to the album's placeholder when the
/// release has no art left at all.
pub fn follow_picture(
    core: &Rc<AppCore>,
    picture: &gtk::Picture,
    title: &str,
    artist: &str,
    size: u32,
) {
    {
        let weak = picture.downgrade();
        core.artwork
            .request_for(picture, title, artist, size, move |texture, _| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
            });
    }
    let (title, artist) = (title.to_string(), artist.to_string());
    let weak_core = Rc::downgrade(core);
    core.hub.subscribe_widget(picture, move |picture, event| {
        let AppEvent::AlbumArtworkChanged {
            title: changed_title,
            artist: changed_artist,
        } = event
        else {
            return;
        };
        if changed_title != &title || changed_artist != &artist {
            return;
        }
        let Some(core) = weak_core.upgrade() else {
            return;
        };
        let weak = picture.downgrade();
        let placeholder = core.artwork.placeholder(&format!("{title}|{artist}"));
        core.artwork
            .request_for(picture, &title, &artist, size, move |texture, _| {
                if let Some(picture) = weak.upgrade() {
                    match texture {
                        Some(texture) => picture.set_paintable(Some(texture)),
                        None => picture.set_paintable(Some(&placeholder)),
                    }
                }
            });
    });
}

fn album_id(title: &str, artist: &str) -> String {
    format!("{title}|{artist}")
}

/// Highest scale factor across connected monitors, so decoded textures stay
/// crisp on HiDPI displays (GTK downscales the paintable to logical size).
fn display_scale() -> u32 {
    use gtk::prelude::*;
    let Some(display) = gdk::Display::default() else {
        return 1;
    };
    let monitors = display.monitors();
    let mut scale = 1;
    for index in 0..monitors.n_items() {
        if let Some(monitor) = monitors
            .item(index)
            .and_then(|obj| obj.downcast::<gdk::Monitor>().ok())
        {
            scale = scale.max(monitor.scale_factor() as u32);
        }
    }
    scale.max(1)
}

fn decode_worker(
    db_path: PathBuf,
    queue: Arc<Queue>,
    bases: Arc<BaseCache>,
    tx: async_channel::Sender<DecodeResult>,
) {
    let db = match Db::open(&db_path) {
        Ok(db) => db,
        Err(err) => {
            crate::logger::error("ui", &format!("artwork worker db open failed: {err}"));
            return;
        }
    };
    while let Some(job) = queue.pop() {
        let results = decode_job(&db, &bases, &job);
        queue.finish(&job.album);
        for result in results {
            if tx.send_blocking(result).is_err() {
                return;
            }
        }
    }
}

/// Every texture wanted from one album, rendered from a single read of its
/// cover.
fn decode_job(db: &Db, bases: &BaseCache, job: &Job) -> Vec<DecodeResult> {
    let source = bases
        .get(&job.album, job.generation, job.largest_cover())
        .or_else(|| load_source(db, bases, job));
    job.wants
        .iter()
        .map(|want| match &source {
            Some(source) => render(source, job, want),
            None => DecodeResult::without_art(job, want),
        })
        .collect()
}

/// Reads and decodes the album's cover. An urgent job's cover is the one the
/// next sizes will ask for, so it is shrunk to `BASE_SIDE` (or the largest
/// size wanted, if bigger) and kept; a tile's is used as read, as it always
/// was, and not kept.
fn load_source(db: &Db, bases: &BaseCache, job: &Job) -> Option<Arc<image::DynamicImage>> {
    let data = db.fetch_album_artwork(&job.title, &job.artist)?;
    let decoded = image::load_from_memory(&data).ok()?;
    if job.priority != Priority::Urgent {
        return Some(Arc::new(decoded));
    }
    let longest = decoded.width().max(decoded.height());
    let base_side = BASE_SIDE.max(job.largest_cover());
    let (image, original) = if longest > base_side {
        (decoded.thumbnail(base_side, base_side), false)
    } else {
        (decoded, true)
    };
    let image = Arc::new(image);
    bases.put(BaseEntry {
        album: job.album.clone(),
        generation: job.generation,
        longest: image.width().max(image.height()),
        original,
        image: Arc::clone(&image),
    });
    Some(image)
}

fn render(source: &image::DynamicImage, job: &Job, want: &Want) -> DecodeResult {
    let (picture, dominant) = match want.look {
        Look::Cover => {
            let thumbnail = source.thumbnail(want.size, want.size).to_rgba8();
            let (width, height) = thumbnail.dimensions();
            let dominant = crate::palette::dominant_color(thumbnail.as_raw(), width, height);
            (thumbnail, Some(dominant))
        }
        Look::Backdrop => (backdrop_pixels(source), None),
    };
    let (width, height) = picture.dimensions();
    DecodeResult {
        width,
        height,
        rgba: Some(picture.into_raw()),
        dominant,
        ..DecodeResult::without_art(job, want)
    }
}

/// The centre of a cover, shrunk and Gaussian-blurred: everything the Now
/// Playing page's wash needs, in a texture small enough to cost nothing to
/// upload or to draw.
fn backdrop_pixels(cover: &image::DynamicImage) -> image::RgbaImage {
    use image::GenericImageView;
    let (width, height) = cover.dimensions();
    let keep = |side: u32| ((side as f64 * BACKDROP_CROP).round() as u32).clamp(1, side);
    let (crop_width, crop_height) = (keep(width), keep(height));
    let centre = cover.crop_imm(
        (width - crop_width) / 2,
        (height - crop_height) / 2,
        crop_width,
        crop_height,
    );
    let small = centre.thumbnail(BACKDROP_SIDE, BACKDROP_SIDE).to_rgba8();
    image::imageops::blur(&small, BACKDROP_SIGMA)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cache() -> ArtworkCache {
        ArtworkCache::new(PathBuf::from("unused.sqlite"))
    }

    fn want(key: &str, size: u32, priority: Priority) -> Want {
        Want {
            key: key.into(),
            size,
            look: Look::Cover,
            priority,
        }
    }

    fn result(generation: u64) -> DecodeResult {
        DecodeResult {
            key: "Record|Band|168".into(),
            title: "Record".into(),
            artist: "Band".into(),
            size: 168,
            look: Look::Cover,
            priority: Priority::Tile,
            generation,
            width: 0,
            height: 0,
            rgba: None,
            dominant: None,
        }
    }

    fn drain(queue: &Queue) -> Vec<Job> {
        let mut jobs = Vec::new();
        loop {
            let taken = queue.lock().take_best();
            let Some(job) = taken else { break };
            queue.finish(&job.album);
            jobs.push(job);
        }
        jobs
    }

    #[test]
    fn a_decode_that_started_before_an_invalidation_is_redone_not_trusted() {
        let cache = cache();
        assert!(!cache.resend_if_stale(&result(0)), "nothing changed, the answer stands");
        assert_eq!(cache.queue.len(), 0);

        cache.invalidate("Record", "Band");
        assert_eq!(cache.generation("Record", "Band"), 1);
        assert!(cache.resend_if_stale(&result(0)), "the old read is stale");
        let again = drain(&cache.queue).pop().expect("the request is sent again");
        assert_eq!(again.generation, 1, "carrying the new generation");
        assert_eq!((again.title.as_str(), again.wants[0].size), ("Record", 168));
        assert!(!cache.resend_if_stale(&result(1)), "the redo is current");
    }

    #[test]
    fn invalidating_one_album_leaves_another_alone() {
        let cache = cache();
        cache.invalidate("Record", "Band");
        assert_eq!(cache.generation("Other", "Band"), 0);
        cache.invalidate("Record", "Band");
        assert_eq!(cache.generation("Record", "Band"), 2);
    }

    #[test]
    fn invalidating_clears_the_negative_cache_for_every_size() {
        let cache = cache();
        cache.misses.borrow_mut().insert("Record|Band|168".into());
        cache.misses.borrow_mut().insert("Record|Band|464".into());
        cache.misses.borrow_mut().insert("Other|Band|168".into());
        cache.invalidate("Record", "Band");
        let remaining: Vec<String> = cache.misses.borrow().iter().cloned().collect();
        assert_eq!(remaining, vec!["Other|Band|168".to_string()]);
    }

    #[test]
    fn invalidating_a_queued_album_hands_its_job_the_new_generation() {
        let cache = cache();
        cache
            .queue
            .push("Record", "Band", 0, want("Record|Band|168", 168, Priority::Tile));
        cache.invalidate("Record", "Band");
        let job = drain(&cache.queue).pop().expect("still queued");
        assert_eq!(job.generation, 1, "it reads the cover after the change");
    }

    #[test]
    fn the_page_being_shown_is_decoded_before_the_tiles_queued_ahead_of_it() {
        let queue = Queue::new();
        for index in 0..5 {
            let title = format!("Tile {index}");
            queue.push(&title, "Band", 0, want(&format!("{title}|Band|168"), 168, Priority::Tile));
        }
        queue.push("Playing", "Band", 0, want("Playing|Band|340", 340, Priority::Urgent));
        queue.push("Late tile", "Band", 0, want("Late tile|Band|168", 168, Priority::Tile));
        let order: Vec<String> = drain(&queue).into_iter().map(|job| job.title).collect();
        assert_eq!(
            order,
            ["Playing", "Late tile", "Tile 4", "Tile 3", "Tile 2", "Tile 1", "Tile 0"]
        );
    }

    #[test]
    fn sizes_asked_for_one_album_share_a_job_and_move_it_forward() {
        let queue = Queue::new();
        queue.push("Record", "Band", 0, want("Record|Band|36", 36, Priority::Tile));
        queue.push("Other", "Band", 0, want("Other|Band|168", 168, Priority::Tile));
        queue.push("Record", "Band", 0, want("Record|Band|340", 340, Priority::Urgent));
        queue.push("Record", "Band", 0, want("Record|Band|340", 340, Priority::Urgent));
        let jobs = drain(&queue);
        assert_eq!(jobs.len(), 2);
        assert_eq!(jobs[0].title, "Record");
        assert_eq!(jobs[0].priority, Priority::Urgent);
        assert_eq!(jobs[0].wants.len(), 2, "the repeated key is not queued twice");
        assert_eq!(jobs[0].largest_cover(), 340);
    }

    #[test]
    fn an_album_being_read_is_not_handed_to_a_second_worker() {
        let queue = Queue::new();
        queue.push("Record", "Band", 0, want("Record|Band|36", 36, Priority::Tile));
        let first = queue.lock().take_best().expect("taken");
        queue.push("Record", "Band", 0, want("Record|Band|340", 340, Priority::Urgent));
        let waiting = queue.lock().take_best();
        assert!(waiting.is_none(), "waits for the read in progress");
        queue.finish(&first.album);
        let following = queue.lock().take_best();
        assert!(following.is_some(), "then it follows");
    }

    #[test]
    fn cancelling_removes_only_the_queued_keys_asked_for() {
        let queue = Queue::new();
        queue.push("Record", "Band", 0, want("Record|Band|36", 36, Priority::Tile));
        queue.push("Record", "Band", 0, want("Record|Band|52", 52, Priority::Tile));
        queue.push("Other", "Band", 0, want("Other|Band|168", 168, Priority::Tile));
        let keys: HashSet<String> = ["Record|Band|36", "Other|Band|168", "Gone|Band|1"]
            .into_iter()
            .map(String::from)
            .collect();
        let mut removed = queue.cancel(&keys);
        removed.sort();
        assert_eq!(removed, ["Other|Band|168", "Record|Band|36"]);
        let left = drain(&queue);
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].wants[0].key, "Record|Band|52");
    }

    #[test]
    fn a_decode_already_running_is_not_cancelled() {
        let queue = Queue::new();
        queue.push("Record", "Band", 0, want("Record|Band|36", 36, Priority::Tile));
        let _running = queue.lock().take_best().expect("taken");
        let keys: HashSet<String> = ["Record|Band|36".to_string()].into();
        assert!(queue.cancel(&keys).is_empty());
    }

    #[test]
    fn waiters_with_no_widget_are_never_abandoned() {
        let unknown = Waiter {
            callback: Box::new(|_, _| {}),
            alive: None,
        };
        let gone = Waiter {
            callback: Box::new(|_, _| {}),
            alive: Some(Box::new(|| false)),
        };
        let here = Waiter {
            callback: Box::new(|_, _| {}),
            alive: Some(Box::new(|| true)),
        };
        assert!(!unknown.abandoned());
        assert!(gone.abandoned());
        assert!(!here.abandoned());
    }

    #[test]
    fn a_long_backlog_of_abandoned_tiles_is_cancelled_and_live_ones_kept() {
        let cache = cache();
        for index in 0..40 {
            let title = format!("Album {index}");
            let key = format!("{title}|Band|168");
            let alive = index % 10 == 0;
            cache.pending.borrow_mut().insert(
                key.clone(),
                vec![Waiter {
                    callback: Box::new(|_, _| {}),
                    alive: Some(Box::new(move || alive)),
                }],
            );
            cache
                .queue
                .push(&title, "Band", 0, want(&key, 168, Priority::Tile));
        }
        cache.drop_abandoned_if_due();
        assert_eq!(cache.queue.len(), 4);
        assert_eq!(cache.pending.borrow().len(), 4);
    }

    #[test]
    fn the_sweep_waits_for_its_interval() {
        let cache = cache();
        cache.last_sweep.set(Some(Instant::now()));
        for index in 0..40 {
            let title = format!("Album {index}");
            let key = format!("{title}|Band|168");
            cache.pending.borrow_mut().insert(
                key.clone(),
                vec![Waiter {
                    callback: Box::new(|_, _| {}),
                    alive: Some(Box::new(|| false)),
                }],
            );
            cache
                .queue
                .push(&title, "Band", 0, want(&key, 168, Priority::Tile));
        }
        cache.drop_abandoned_if_due();
        assert_eq!(cache.queue.len(), 40);
    }

    #[test]
    fn recency_evicts_the_least_recently_touched_key() {
        let mut recency = Recency::default();
        for key in ["a", "b", "c"] {
            recency.touch(key);
        }
        recency.touch("a");
        assert_eq!(recency.len(), 3);
        assert_eq!(recency.pop_oldest().as_deref(), Some("b"));
        assert_eq!(recency.pop_oldest().as_deref(), Some("c"));
        assert_eq!(recency.pop_oldest().as_deref(), Some("a"));
        assert_eq!(recency.pop_oldest(), None);
    }

    #[test]
    fn recency_forgets_a_whole_album_by_prefix() {
        let mut recency = Recency::default();
        for key in ["Record|Band|36", "Record|Band|backdrop", "Other|Band|36"] {
            recency.touch(key);
        }
        recency.forget_prefix("Record|Band|");
        assert_eq!(recency.len(), 1);
        assert_eq!(recency.pop_oldest().as_deref(), Some("Other|Band|36"));
    }

    fn base_entry(album: &str, generation: u64, side: u32, original: bool) -> BaseEntry {
        BaseEntry {
            album: album.into(),
            generation,
            longest: side,
            original,
            image: Arc::new(image::DynamicImage::new_rgb8(2, 2)),
        }
    }

    #[test]
    fn a_kept_cover_serves_only_sizes_it_is_large_enough_for_at_its_generation() {
        let bases = BaseCache::new();
        bases.put(base_entry("Record|Band", 0, 1024, false));
        assert!(bases.get("Record|Band", 0, 680).is_some());
        assert!(bases.get("Record|Band", 0, 1200).is_none(), "would be an upscale");
        assert!(bases.get("Record|Band", 1, 36).is_none(), "the cover changed");
        bases.put(base_entry("Small|Band", 0, 300, true));
        assert!(bases.get("Small|Band", 0, 1200).is_some(), "it is the whole cover");
        bases.forget("Record|Band");
        assert!(bases.get("Record|Band", 0, 36).is_none());
    }

    #[test]
    fn a_late_decode_of_an_old_cover_does_not_replace_a_newer_one() {
        let bases = BaseCache::new();
        bases.put(base_entry("Record|Band", 2, 1024, false));
        bases.put(base_entry("Record|Band", 1, 1024, false));
        assert!(bases.get("Record|Band", 2, 36).is_some());
        assert!(bases.get("Record|Band", 1, 36).is_none());
    }

    #[test]
    fn the_kept_covers_are_bounded_and_the_least_recently_used_goes_first() {
        let bases = BaseCache::new();
        for index in 0..BASE_CAPACITY {
            bases.put(base_entry(&format!("Album {index}"), 0, 1024, false));
        }
        assert!(bases.get("Album 0", 0, 36).is_some());
        bases.put(base_entry("Extra", 0, 1024, false));
        assert_eq!(bases.lock().len(), BASE_CAPACITY);
        assert!(bases.get("Album 1", 0, 36).is_none());
        assert!(bases.get("Album 0", 0, 36).is_some());
    }

    #[test]
    fn a_placeholder_has_one_texture_per_hue_not_per_album() {
        let hue = |seed: &str| crate::palette::fnv1a_64(seed) % PLACEHOLDER_HUES;
        let seeds: Vec<String> = (0..2000).map(|index| format!("Album {index}|Band")).collect();
        let hues: HashSet<u64> = seeds.iter().map(|seed| hue(seed)).collect();
        assert!(hues.len() <= PLACEHOLDER_HUES as usize);
        let first = seeds.iter().find(|seed| hue(seed) == hue(&seeds[0]) && **seed != seeds[0]);
        let second = first.expect("two seeds share a hue");
        assert_eq!(placeholder_texels(&seeds[0]), placeholder_texels(second));
    }

    fn bilinear_texel(texels: &[u8], px: u32, py: u32, channel: usize) -> f64 {
        let ratio = PLACEHOLDER_SIDE as f64 / PLACEHOLDER_REFERENCE_SIDE as f64;
        let last = (PLACEHOLDER_SIDE - 1) as f64;
        let source = |index: u32| ((index as f64 + 0.5) * ratio - 0.5).clamp(0.0, last);
        let (u, v) = (source(px), source(py));
        let (u0, v0) = (u.floor() as u32, v.floor() as u32);
        let (u1, v1) = ((u0 + 1).min(PLACEHOLDER_SIDE - 1), (v0 + 1).min(PLACEHOLDER_SIDE - 1));
        let at = |x: u32, y: u32| texels[((y * PLACEHOLDER_SIDE + x) * 4) as usize + channel] as f64;
        let (fu, fv) = (u - u0 as f64, v - v0 as f64);
        let top = at(u0, v0) * (1.0 - fu) + at(u1, v0) * fu;
        let bottom = at(u0, v1) * (1.0 - fu) + at(u1, v1) * fu;
        top * (1.0 - fv) + bottom * fv
    }

    #[test]
    fn the_small_placeholder_matches_the_old_full_size_render_within_a_level() {
        for seed in ["Abbey Road|The Beatles", "Kind of Blue|Miles Davis", "x|y"] {
            let reference =
                crate::palette::placeholder_rgba(seed, PLACEHOLDER_REFERENCE_SIDE);
            let texels = placeholder_texels(seed);
            let mut worst = 0i32;
            for py in 0..PLACEHOLDER_REFERENCE_SIDE {
                for px in 0..PLACEHOLDER_REFERENCE_SIDE {
                    for channel in 0..3 {
                        let scaled = bilinear_texel(&texels, px, py, channel);
                        let full = reference
                            [((py * PLACEHOLDER_REFERENCE_SIDE + px) * 4) as usize + channel]
                            as f64;
                        worst = worst.max((scaled - full).abs().round() as i32);
                    }
                }
            }
            assert!(worst <= 2, "{seed}: differs by {worst}");
        }
    }

    fn sample_covers(path: &std::path::Path, count: usize) -> Vec<(String, String, Vec<u8>)> {
        let conn = rusqlite::Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .expect("open the copied library");
        let mut statement = conn
            .prepare(
                "SELECT title, artist, COALESCE(customCoverData, coverArtData) AS cover
                 FROM albumInfo WHERE cover IS NOT NULL ORDER BY length(cover) DESC",
            )
            .expect("prepare");
        let all: Vec<(String, String, Vec<u8>)> = statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .expect("query")
            .filter_map(Result::ok)
            .collect();
        let largest = 3.min(count);
        let step = (all.len() / (count - largest).max(1)).max(1);
        let (big, rest) = all.split_at(largest.min(all.len()));
        big.iter()
            .cloned()
            .chain(rest.iter().step_by(step).take(count - largest).cloned())
            .collect()
    }

    fn old_decode(data: &[u8], size: u32, look: Look) -> usize {
        let decoded = image::load_from_memory(data).expect("decode");
        match look {
            Look::Cover => {
                let thumbnail = decoded.thumbnail(size, size).to_rgba8();
                let (width, height) = thumbnail.dimensions();
                let _ = crate::palette::dominant_color(thumbnail.as_raw(), width, height);
                thumbnail.len()
            }
            Look::Backdrop => backdrop_pixels(&decoded).len(),
        }
    }

    fn millis(start: Instant) -> f64 {
        start.elapsed().as_secs_f64() * 1000.0
    }

    #[test]
    #[ignore = "reads the copy of the real library in target/perfdb; run with --nocapture"]
    fn measure_decode_time_per_cover_size() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("target/perfdb/library.sqlite");
        let covers = sample_covers(&path, 8);
        let sizes = [36u32, 52, 168, 340, 680];
        println!("cover | source | bytes | old: per size ms {sizes:?} + backdrop | old sum | new one job ms");
        let (mut old_total, mut new_total) = (0.0, 0.0);
        for (title, artist, data) in &covers {
            let source = image::load_from_memory(data).expect("decode");
            let dimensions = format!("{}x{}", source.width(), source.height());
            let mut per_size = Vec::new();
            for size in sizes {
                let start = Instant::now();
                old_decode(data, size, Look::Cover);
                per_size.push(millis(start));
            }
            let start = Instant::now();
            old_decode(data, BACKDROP_SIDE, Look::Backdrop);
            per_size.push(millis(start));
            let old_sum: f64 = per_size.iter().sum();

            let job = Job {
                album: album_id(title, artist),
                title: title.clone(),
                artist: artist.clone(),
                generation: 0,
                priority: Priority::Urgent,
                sequence: 0,
                wants: sizes
                    .iter()
                    .map(|size| want(&format!("k{size}"), *size, Priority::Urgent))
                    .chain([Want {
                        key: "backdrop".into(),
                        size: BACKDROP_SIDE,
                        look: Look::Backdrop,
                        priority: Priority::Urgent,
                    }])
                    .collect(),
            };
            let db = Db::open(&path).expect("open");
            let bases = BaseCache::new();
            let start = Instant::now();
            let results = decode_job(&db, &bases, &job);
            let new_ms = millis(start);
            assert!(results.iter().all(|result| result.rgba.is_some()));
            old_total += old_sum;
            new_total += new_ms;
            let formatted: Vec<String> = per_size.iter().map(|ms| format!("{ms:.1}")).collect();
            println!(
                "{title:.24} | {dimensions} | {} | {} | {old_sum:.1} | {new_ms:.1}",
                data.len(),
                formatted.join(" ")
            );
        }
        println!("TOTAL old {old_total:.1} ms, new {new_total:.1} ms");
    }

    #[test]
    #[ignore = "reads the copy of the real library in target/perfdb; run with --nocapture"]
    fn measure_time_until_the_playing_cover_with_a_backlog() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("target/perfdb/library.sqlite");
        let covers = sample_covers(&path, 120);
        let backlog = &covers[..covers.len() - 1];
        let playing = &covers[covers.len() - 1];

        let start = Instant::now();
        for (_, _, data) in backlog {
            old_decode(data, 168, Look::Cover);
        }
        old_decode(&playing.2, 340, Look::Cover);
        println!(
            "old: one worker, first in first out, {} tiles then the playing cover: {:.0} ms",
            backlog.len(),
            millis(start)
        );

        let queue = Arc::new(Queue::new());
        let bases = Arc::new(BaseCache::new());
        let (tx, rx) = async_channel::unbounded();
        for _ in 0..WORKERS {
            let (queue, bases, tx, path) =
                (Arc::clone(&queue), Arc::clone(&bases), tx.clone(), path.clone());
            std::thread::spawn(move || decode_worker(path, queue, bases, tx));
        }
        let start = Instant::now();
        for (title, artist, _) in backlog {
            queue.push(title, artist, 0, want(&format!("{title}|{artist}|168"), 168, Priority::Tile));
        }
        queue.push(
            &playing.0,
            &playing.1,
            0,
            want(&format!("{}|{}|340", playing.0, playing.1), 340, Priority::Urgent),
        );
        let mut tiles = 0;
        loop {
            let result = rx.recv_blocking().expect("result");
            if result.size == 340 {
                println!(
                    "new: {WORKERS} workers, newest urgent first: playing cover after {:.0} ms, {tiles} tiles done before it",
                    millis(start)
                );
                break;
            }
            tiles += 1;
        }
        while tiles < backlog.len() {
            rx.recv_blocking().expect("result");
            tiles += 1;
        }
        println!("new: whole backlog drained in {:.0} ms", millis(start));
        queue.close();
    }
}
