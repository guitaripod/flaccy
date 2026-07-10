use crate::app::AppCore;
use crate::db::Db;
use gtk::gdk;
use gtk::glib;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::rc::Rc;

const LRU_CAPACITY: usize = 300;

struct DecodeRequest {
    key: String,
    title: String,
    artist: String,
    size: u32,
}

struct DecodeResult {
    key: String,
    width: u32,
    height: u32,
    rgba: Option<Vec<u8>>,
    dominant: Option<(u8, u8, u8)>,
}

type Callback = Box<dyn Fn(Option<&gdk::MemoryTexture>, Option<(u8, u8, u8)>)>;

pub struct ArtworkCache {
    db_path: PathBuf,
    textures: RefCell<HashMap<String, (gdk::MemoryTexture, Option<(u8, u8, u8)>)>>,
    lru: RefCell<VecDeque<String>>,
    misses: RefCell<HashSet<String>>,
    pending: RefCell<HashMap<String, Vec<Callback>>>,
    placeholders: RefCell<HashMap<u64, gdk::MemoryTexture>>,
    tx: RefCell<Option<async_channel::Sender<DecodeRequest>>>,
}

impl ArtworkCache {
    pub fn new(db_path: PathBuf) -> Self {
        Self {
            db_path,
            textures: RefCell::new(HashMap::new()),
            lru: RefCell::new(VecDeque::new()),
            misses: RefCell::new(HashSet::new()),
            pending: RefCell::new(HashMap::new()),
            placeholders: RefCell::new(HashMap::new()),
            tx: RefCell::new(None),
        }
    }

    pub fn start(&self, core: &Rc<AppCore>) {
        let (req_tx, req_rx) = async_channel::unbounded::<DecodeRequest>();
        let (res_tx, res_rx) = async_channel::unbounded::<DecodeResult>();
        let db_path = self.db_path.clone();
        std::thread::Builder::new()
            .name("flaccy-artwork".into())
            .spawn(move || decode_worker(db_path, req_rx, res_tx))
            .ok();
        *self.tx.borrow_mut() = Some(req_tx);

        let core = Rc::downgrade(core);
        glib::spawn_future_local(async move {
            while let Ok(result) = res_rx.recv().await {
                let Some(core) = core.upgrade() else { break };
                core.artwork.finish(result);
            }
        });
    }

    pub fn placeholder(&self, seed: &str) -> gdk::MemoryTexture {
        let hash = crate::palette::fnv1a_64(seed);
        if let Some(texture) = self.placeholders.borrow().get(&hash) {
            return texture.clone();
        }
        let size = 160u32;
        let data = crate::palette::placeholder_rgba(seed, size);
        let texture = gdk::MemoryTexture::new(
            size as i32,
            size as i32,
            gdk::MemoryFormat::R8g8b8a8,
            &glib::Bytes::from_owned(data),
            (size * 4) as usize,
        );
        self.placeholders.borrow_mut().insert(hash, texture.clone());
        texture
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
        let key = format!("{title}|{artist}|{size}");
        if let Some((texture, dominant)) = self.textures.borrow().get(&key) {
            self.touch(&key);
            callback(Some(texture), *dominant);
            return;
        }
        if self.misses.borrow().contains(&key) {
            callback(None, None);
            return;
        }
        let mut pending = self.pending.borrow_mut();
        let entry = pending.entry(key.clone()).or_default();
        let first = entry.is_empty();
        entry.push(Box::new(callback));
        drop(pending);
        if first {
            if let Some(tx) = self.tx.borrow().as_ref() {
                let _ = tx.send_blocking(DecodeRequest {
                    key,
                    title: title.to_string(),
                    artist: artist.to_string(),
                    size,
                });
            }
        }
    }

    fn finish(&self, result: DecodeResult) {
        let callbacks = self.pending.borrow_mut().remove(&result.key);
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
        if let Some(callbacks) = callbacks {
            for callback in callbacks {
                callback(texture.as_ref(), result.dominant);
            }
        }
    }

    fn touch(&self, key: &str) {
        let mut lru = self.lru.borrow_mut();
        lru.retain(|k| k != key);
        lru.push_back(key.to_string());
    }

    fn evict_if_needed(&self) {
        let mut lru = self.lru.borrow_mut();
        while lru.len() > LRU_CAPACITY {
            if let Some(oldest) = lru.pop_front() {
                self.textures.borrow_mut().remove(&oldest);
            }
        }
    }
}

fn decode_worker(
    db_path: PathBuf,
    rx: async_channel::Receiver<DecodeRequest>,
    tx: async_channel::Sender<DecodeResult>,
) {
    let db = match Db::open(&db_path) {
        Ok(db) => db,
        Err(err) => {
            crate::logger::error("ui", &format!("artwork worker db open failed: {err}"));
            return;
        }
    };
    while let Ok(request) = rx.recv_blocking() {
        let result = decode_one(&db, &request);
        if tx.send_blocking(result).is_err() {
            break;
        }
    }
}

fn decode_one(db: &Db, request: &DecodeRequest) -> DecodeResult {
    let empty = DecodeResult {
        key: request.key.clone(),
        width: 0,
        height: 0,
        rgba: None,
        dominant: None,
    };
    let Some(data) = db.fetch_album_artwork(&request.title, &request.artist) else {
        return empty;
    };
    let Ok(decoded) = image::load_from_memory(&data) else {
        return empty;
    };
    let thumbnail = decoded.thumbnail(request.size, request.size).to_rgba8();
    let (width, height) = thumbnail.dimensions();
    let rgba = thumbnail.into_raw();
    let dominant = Some(crate::palette::dominant_color(&rgba, width, height));
    DecodeResult {
        key: request.key.clone(),
        width,
        height,
        rgba: Some(rgba),
        dominant,
    }
}
